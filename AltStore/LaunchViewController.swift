//
//  LaunchViewController.swift
//  AltStore
//

import UIKit
import SwiftUI
import UserNotifications
import Roxas
import WidgetKit
import AltSign
import AltStoreCore
import UniformTypeIdentifiers
import OSLog

let pairingFileName = "ALTPairingFile.mobiledevicepairing"

private let aeroPreviewWithoutPairingKey = "AeroStore.previewWithoutDevicePairing"

final class LaunchViewController: UIViewController {
    private var didFinishLaunching = false
    private var retries = 0
    private let maxRetries = 3
    private var splashView: SplashView!
    private var startTime: Date!

    override func viewDidLoad() {
        super.viewDidLoad()
        let log = OSLog(subsystem: "com.aero.aerostore", category: "launch-ui")
        os_log(.default, log: log, "LaunchViewController: viewDidLoad")
        view.backgroundColor = .systemBackground
        do {
            splashView = SplashView(frame: view.bounds, appName: Bundle.main.altAppDisplayName)
            splashView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(splashView)
            os_log(.default, log: log, "SplashView created")
        } catch {
            os_log(.error, log: log, "Failed to create SplashView: %{public}@", String(describing: error))
            let label = UILabel()
            label.text = Bundle.main.altAppDisplayName
            label.font = .systemFont(ofSize: 24, weight: .bold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let log = OSLog(subsystem: "com.aero.aerostore", category: "launch-ui")
        os_log(.default, log: log, "LaunchViewController: viewDidAppear")
        guard !didFinishLaunching else {
            os_log(.default, log: log, "viewDidAppear: already finished launching, skipping")
            return
        }
        startTime = Date()

        if let report = CrashReportStore.load() {
            os_log(.default, log: log, "Crash report found — showing diagnostics")
            presentCrashDiagnostics(report: report)
            return
        }

        os_log(.default, log: log, "viewDidAppear: starting launch sequence")
        Task { @MainActor in
            await runLaunchSequence()
        }
    }

    private func presentCrashDiagnostics(report: CrashReport) {
        let diagnosticsView = CrashDiagnosticsView(report: report) { [weak self] in
            guard let self else { return }
            CrashReportStore.clear()
            // Dismiss the diagnostics host and proceed with a SAFE launch
            // that will NOT re-start the minimuxer or JIT tunnel (which
            // is likely what crashed in the first place).  The user must
            // manually re-pair their device or re-enable JIT from Settings.
            self.dismiss(animated: true) {
                Task { @MainActor in
                    await self.runLaunchSequence(skipPostLaunchWork: true)
                }
            }
        }
        let host = UIHostingController(rootView: diagnosticsView)
        host.modalPresentationStyle = .overFullScreen
        host.isModalInPresentation = true
        present(host, animated: false)
    }

    private func runLaunchSequence(skipPostLaunchWork: Bool = false) async {
        let log = OSLog(subsystem: "com.aero.aerostore", category: "launch-ui")
        os_log(.default, log: log, "runLaunchSequence (retry #%d, skipPostLaunch=%@)", retries, String(describing: skipPostLaunchWork))
        if retries >= maxRetries {
            os_log(.default, log: log, "Max retries reached, stopping launch sequence without installing broken interface")
            return
        }
        retries += 1

        if DatabaseManager.shared.isStarted {
            os_log(.default, log: log, "DatabaseManager already started, finishing")
            await finishLaunching(skipPostLaunchWork: skipPostLaunchWork)
            return
        }

        os_log(.default, log: log, "Waiting for DatabaseManager.start...")
        await withCheckedContinuation { continuation in
            DatabaseManager.shared.start { error in
                Task { @MainActor in
                    if let error {
                        let nsError = error as NSError
                        if self.retries < self.maxRetries && (nsError.domain == NSCocoaErrorDomain || nsError.domain == NSSQLiteErrorDomain || nsError.code == 134020) {
                            os_log(.default, log: log, "Database error (%{public}@ code %d) — recreating database and retrying", nsError.domain, nsError.code)
                            DatabaseManager.recreateDatabase()
                            continuation.resume()
                            await self.runLaunchSequence(skipPostLaunchWork: skipPostLaunchWork)
                        } else {
                            os_log(.error, log: log, "DatabaseManager.start error (code %d): %{public}@", nsError.code, String(describing: error))
                            await self.handleLaunchError(error, retryCallback: {
                                self.retries = 0
                                await self.runLaunchSequence(skipPostLaunchWork: skipPostLaunchWork)
                            })
                            continuation.resume()
                        }
                    } else {
                        os_log(.default, log: log, "DatabaseManager.start succeeded")
                        await self.finishLaunching(skipPostLaunchWork: skipPostLaunchWork)
                        continuation.resume()
                    }
                }
            }
        }
    }

    @MainActor
    private func finishLaunching(skipPostLaunchWork: Bool = false) async {
        let log = OSLog(subsystem: "com.aero.aerostore", category: "launch-ui")
        guard !didFinishLaunching else {
            os_log(.default, log: log, "finishLaunching: already done, skipping")
            return
        }
        didFinishLaunching = true
        os_log(.default, log: log, "finishLaunching - installing main interface")

        let elapsed = abs(startTime.timeIntervalSinceNow)
        let remaining = max(0, 0.25 - elapsed)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }

        AppLaunchCoordinator.installMainInterface(animated: true)

        guard let tabBar = AppLaunchCoordinator.resolveKeyWindow()?.rootViewController as? TabBarController else {
            os_log(.error, log: log, "LaunchViewController: main interface not installed (root=%@)", String(describing: AppLaunchCoordinator.resolveKeyWindow()?.rootViewController))
            return
        }
        os_log(.default, log: log, "Main interface installed: TabBarController with %d tabs", tabBar.viewControllers?.count ?? 0)

        splashView?.removeFromSuperview()
        runDeferredLaunchWork(on: tabBar)
        
        if !skipPostLaunchWork {
            schedulePostLaunchWork(on: tabBar)
        } else {
            os_log(.default, log: log, "Skipping post-launch work (crash recovery mode)")
        }
    }

    @MainActor
    private func schedulePostLaunchWork(on tabBar: TabBarController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            SideJITManager.shared.checkAndPromptIfNeeded(presentingVC: tabBar)
            if #available(iOS 17, *), UserDefaults.standard.sidejitenable {
                DispatchQueue.global().async { SideJITManager.shared.askForNetwork() }
            }

            #if !targetEnvironment(simulator)
            self.detectAndImportAccountFile()
            if UserDefaults.standard.enableEMPforWireguard {
                startEMProxy(bind_addr: AppConstants.Proxy.serverURL)
            }
            if let pf = PairingFileManager.shared.fetchPairingFile(presentingVC: tabBar) {
                UserDefaults.standard.set(false, forKey: aeroPreviewWithoutPairingKey)
                PairingFileManager.shared.startMinimuxerIfPossible(pf, presenter: tabBar)
            }
            #endif
        }
    }

    func importAccountAtFile(_ file: URL, remove: Bool = false) {
        _ = file.startAccessingSecurityScopedResource()
        defer { file.stopAccessingSecurityScopedResource() }
        guard let accountD = try? Data(contentsOf: file),
              let account = try? Foundation.JSONDecoder().decode(ImportedAccount.self, from: accountD) else { return }

        if remove { try? FileManager.default.removeItem(at: file) }
        Keychain.shared.appleIDEmailAddress = account.email
        Keychain.shared.appleIDPassword = account.password
        Keychain.shared.adiPb = account.adiPB
        Keychain.shared.identifier = account.local_user
        guard let tabBar = AppLaunchCoordinator.resolveKeyWindow()?.rootViewController as? TabBarController else { return }
        if let altCert = ALTCertificate(p12Data: account.cert, password: account.certpass) {
            Keychain.shared.signingCertificate = altCert.encryptedP12Data(withPassword: "")!
            Keychain.shared.signingCertificatePassword = account.certpass
            ToastView(
                text: NSLocalizedString("Successfully imported '\(account.email)'!", comment: ""),
                detailText: String(format: NSLocalizedString("%@ should be fully operational now.", comment: ""), Bundle.main.altAppDisplayName)
            ).show(in: tabBar)
        }
    }

    func detectAndImportAccountFile() {
        let accountFileURL = FileManager.default.documentsDirectory.appendingPathComponent("Account.sideconf")
        #if !DEBUG
        importAccountAtFile(accountFileURL, remove: true)
        #else
        importAccountAtFile(accountFileURL)
        #endif
    }
}

extension LaunchViewController {
    @MainActor
    func handleLaunchError(_ error: Error, retryCallback: (() async -> Void)? = nil) {
        do { throw error } catch let error as NSError {
            let title = error.userInfo[NSLocalizedFailureErrorKey] as? String
                ?? String(format: NSLocalizedString("Unable to Launch %@", comment: ""), Bundle.main.altAppDisplayName)
            let desc: String
            if #available(iOS 14.5, *) {
                desc = ([error.debugDescription] + error.underlyingErrors.map { ($0 as NSError).debugDescription }).joined(separator: "\n\n")
            } else {
                desc = error.debugDescription
            }
            let alert = UIAlertController(title: title, message: desc, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { _ in
                Task { await retryCallback?() }
            })
            let host = AppLaunchCoordinator.resolveKeyWindow()?.rootViewController ?? self
            host.present(alert, animated: true)
        }
    }

    func runDeferredLaunchWork(on tabBarController: TabBarController) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Request notification permission now that the UI is fully set up.
            // We deliberately defer this from didFinishLaunchingWithOptions so the
            // system permission dialog does not overlap with (and appear to hide)
            // the SplashView on first launch.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }

            AppManager.shared.update()
            AppManager.shared.updateAllSources { result in
                guard case .failure(let error) = result else { return }
                var mode: ToastView.InfoMode = .fullError
                if String(describing: error).contains("The Internet connection appears to be offline") {
                    mode = .localizedDescription
                }
                let toastView = ToastView(error: error, mode: mode)
                toastView.addTarget(tabBarController, action: #selector(TabBarController.presentSources), for: .touchUpInside)
                toastView.show(in: tabBarController.selectedViewController ?? tabBarController)
            }
            self.updateKnownSources()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func updateKnownSources() {
        AppManager.shared.updateKnownSources { result in
            guard case .success((_, let blockedSources)) = result else { return }
            DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                let blockedSourceIDs = Set(blockedSources.lazy.map { $0.identifier })
                let blockedSourceURLs = Set(blockedSources.lazy.compactMap { $0.sourceURL })
                let predicate = NSPredicate(
                    format: "%K IN %@ OR %K IN %@",
                    #keyPath(Source.identifier), blockedSourceIDs,
                    #keyPath(Source.sourceURL), blockedSourceURLs
                )
                let sourceErrors = Source.all(satisfying: predicate, in: context).map { source in
                    let blocked = blockedSources.first { $0.identifier == source.identifier }
                    return SourceError.blocked(source, bundleIDs: blocked?.bundleIDs, existingSource: source)
                }
                guard !sourceErrors.isEmpty else { return }
                Task { @MainActor in
                    let host = AppLaunchCoordinator.resolveKeyWindow()?.rootViewController
                    for error in sourceErrors {
                        let title = String(format: NSLocalizedString("\"%@\" Blocked", comment: ""), error.$source.name)
                        let message = [error.localizedDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
                        await host?.presentAlert(title: title, message: message)
                    }
                }
            }
        }
    }
}

// MARK: - SplashView
final class SplashView: UIView {
    let iconView = AeroLogoView()
    let titleLabel = UILabel()

    init(frame: CGRect, appName: String) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        setupIcon()
        setupTitle(appName: appName)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupIcon() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.layer.cornerRadius = 28
        iconView.clipsToBounds = true
        container.addSubview(iconView)
        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            container.widthAnchor.constraint(equalToConstant: 128),
            container.heightAnchor.constraint(equalToConstant: 128),
            iconView.topAnchor.constraint(equalTo: container.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    private func setupTitle(appName: String) {
        titleLabel.text = appName
        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 16),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }
}

// MARK: - PairingFileManager
final class PairingFileManager {
    static let shared = PairingFileManager()

    func fetchPairingFile(presentingVC: UIViewController) -> String? {
        let documentsPath = FileManager.default.documentsDirectory.appendingPathComponent(pairingFileName)
        if let contents = try? String(contentsOf: documentsPath), !contents.isEmpty { return contents }
        if let url = Bundle.main.url(forResource: "ALTPairingFile", withExtension: "mobiledevicepairing"),
           let data = try? Data(contentsOf: url),
           let contents = String(data: data, encoding: .utf8),
           !contents.isEmpty, !UserDefaults.standard.isPairingReset { return contents }
        if let plistString = Bundle.main.object(forInfoDictionaryKey: "ALTPairingFile") as? String,
           !plistString.isEmpty, !plistString.contains("insert pairing file here"), !UserDefaults.standard.isPairingReset { return plistString }

        presentPairingFileAlert(on: presentingVC)
        return nil
    }

    private func presentPairingFileAlert(on vc: UIViewController) {
        let alert = UIAlertController(
            title: NSLocalizedString("Pairing File", comment: ""),
            message: String(
                format: NSLocalizedString("Import a pairing file to refresh and install apps in %@. You can skip for now to browse sources only.", comment: ""),
                Bundle.main.altAppDisplayName
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: NSLocalizedString("Help", comment: ""), style: .default) { _ in
            if let url = URL(string: "https://docs.sidestore.io/docs/advanced/pairing-file") { UIApplication.shared.open(url) }
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Browse without pairing", comment: ""), style: .cancel) { _ in
            UserDefaults.standard.set(true, forKey: aeroPreviewWithoutPairingKey)
            ToastView(
                text: NSLocalizedString("Preview mode", comment: ""),
                detailText: NSLocalizedString("Add a pairing file in Settings to install, refresh, or use device features.", comment: "")
            ).show(in: vc)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Choose File…", comment: ""), style: .default) { _ in
            // Build the set of types the picker should accept.
            // 1. Explicitly include the custom mobiledevicepairing UTType (declared in Info.plist).
            // 2. Also include standard property-list types so iOS Files shows .plist files.
            // 3. Use .data as a broad fallback so nothing is accidentally hidden.
            var types: [UTType] = []

            // Custom mobiledevicepairing type (registered in UTImportedTypeDeclarations)
            if let pairingType = UTType("org.sidestore.mobiledevicepairing") {
                types.append(pairingType)
            }
            // mobiledevicepairing by filename extension
            types.append(contentsOf: UTType.types(tag: "mobiledevicepairing", tagClass: .filenameExtension, conformingTo: nil))
            // Standard plist / property-list types
            types.append(.propertyList)
            if let plistExt = UTType(filenameExtension: "plist") {
                types.append(plistExt)
            }
            // XML (many pairing files are XML plists)
            types.append(.xml)

            // Remove duplicates while preserving order
            var seen = Set<String>()
            let uniqueTypes = types.filter { seen.insert($0.identifier).inserted }

            let picker = UIDocumentPickerViewController(forOpeningContentTypes: uniqueTypes)
            picker.delegate = PairingFileImportCoordinator.shared
            PairingFileImportCoordinator.shared.presentingViewController = vc
            picker.shouldShowFileExtensions = true
            picker.allowsMultipleSelection = false
            vc.present(picker, animated: true)
            UserDefaults.standard.isPairingReset = false
        })
        vc.present(alert, animated: true)
    }

    func startMinimuxerIfPossible(_ pairingString: String, presenter: UIViewController?) {
        #if !targetEnvironment(simulator)
        // ── Crash guard ──────────────────────────────────────────────────────────
        // If a crash report is pending, skip the Rust FFI call entirely.
        // The Rust minimuxer library can call abort() on bad input or sandbox
        // violations, which bypasses all Swift error handlers.  We prevent that
        // by refusing to enter Rust while diagnostics are pending.
        if CrashReportStore.load() != nil {
            print("⚠️ Crash report pending — skipping minimuxer start.")
            return
        }

        // Pre-flight: validate the pairing file looks like valid XML/plist.
        // A malformed file passed to the Rust bridge is a common abort() trigger.
        guard !pairingString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = pairingString.data(using: .utf8),
              data.count > 20  // pairing files are at least a few hundred bytes
        else {
            print("⚠️ Pairing file is empty or too short — skipping minimuxer start.")
            try? FileManager.default.removeItem(at: FileManager.default.documentsDirectory.appendingPathComponent(pairingFileName))
            guard let presenter else { return }
            let alert = UIAlertController(
                title: NSLocalizedString("Invalid Pairing File", comment: ""),
                message: NSLocalizedString("The pairing file appears to be empty or corrupted. Please import it again.", comment: ""),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            presenter.present(alert, animated: true)
            return
        }

        // Pre-flight: on iOS 26+, Apple requires the newer RPPairing format (contains
        // a "private_key" field). Old lockdown pairing files (UDID-only, generated by
        // older idevice_pair / AltServer) are silently rejected by the OS and cause
        // the cryptic "AFC was unable to manage files" error. Detect this early and
        // show an actionable message before we even attempt to start minimuxer.
        if #available(iOS 26, *) {
            let isRPPairing = pairingString.contains("<key>private_key</key>")
            if !isRPPairing {
                print("⚠️ Legacy lockdown pairing file detected on iOS 26+ — will fail.")
                guard let presenter else { return }
                let alert = UIAlertController(
                    title: NSLocalizedString("Pairing File Outdated", comment: ""),
                    message: NSLocalizedString(
                        "Your pairing file was generated with an older tool and is not compatible with iOS 26 or later.\n\nPlease regenerate it using the latest version of SideServer or iLoader, then import it again.",
                        comment: ""
                    ),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: NSLocalizedString("Get SideServer", comment: ""), style: .default) { _ in
                    if let url = URL(string: "https://github.com/SideStore/SideServer-macOS/releases/latest") {
                        UIApplication.shared.open(url)
                    }
                })
                alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel))
                presenter.present(alert, animated: true)
                return
            }
        }

        // Write a sentinel before the Rust call.  If minimuxerStartWithLogger
        // triggers abort() inside the Rust bridge, this file persists to the
        // next launch so CrashReportStore can detect it.
        let minimuxerSentinel = CrashReportStore.minimuxerSentinelURL
        try? "1".write(to: minimuxerSentinel, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: minimuxerSentinel) }
        // ──────────────────────────────────────────────────────────────────────────

        let stikJITPairingURL = FileManager.default.documentsDirectory.appendingPathComponent("rp_pairing_file.plist")
        try? pairingString.write(to: stikJITPairingURL, atomically: true, encoding: .utf8)

        do {
            retargetUsbmuxdAddr()
            let documentsDirectory = FileManager.default.documentsDirectory.absoluteString
            try minimuxerStartWithLogger(pairingString, documentsDirectory, UserDefaults.standard.isMinimuxerConsoleLoggingEnabled)
            startAutoMounter(documentsDirectory)
        } catch {
            // NOTE: Do NOT delete the pairing file here. A startup failure is usually
            // transient (VPN not ready, device temporarily unreachable) and silently
            // wiping the pairing file forces the user to re-import it every time.
            print("[AeroStore] minimuxer startup error (pairing file preserved): \(error)")
            guard let presenter else { return }
            let alert = UIAlertController(
                title: String(format: NSLocalizedString("Error launching %@", comment: ""), Bundle.main.altAppDisplayName),
                message: (error as? LocalizedError)?.failureReason ?? error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            presenter.present(alert, animated: true)
        }
        #endif
    }
}

final class PairingFileImportCoordinator: NSObject, UIDocumentPickerDelegate {
    static let shared = PairingFileImportCoordinator()
    weak var presentingViewController: UIViewController?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let pairingString = String(data: data, encoding: .utf8) else { return }
            // Save the pairing file FIRST before attempting to start minimuxer.
            // startMinimuxerIfPossible must NEVER delete this file on failure.
            try pairingString.write(to: FileManager.default.documentsDirectory.appendingPathComponent(pairingFileName), atomically: true, encoding: .utf8)
            UserDefaults.standard.set(false, forKey: aeroPreviewWithoutPairingKey)
            PairingFileManager.shared.startMinimuxerIfPossible(pairingString, presenter: presentingViewController)
        } catch {
            print("[AeroStore] Failed to import pairing file: \(error)")
        }
        controller.dismiss(animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        UserDefaults.standard.set(true, forKey: aeroPreviewWithoutPairingKey)
    }
}

final class SideJITManager {
    static let shared = SideJITManager()
    func checkAndPromptIfNeeded(presentingVC: UIViewController) {
        guard #available(iOS 17, *), !UserDefaults.standard.sidejitenable else { return }
        DispatchQueue.global().async {
            self.isSideJITServerDetected { result in
                DispatchQueue.main.async {
                    guard case .success = result else { return }
                    let alert = UIAlertController(title: "SideJITServer Detected", message: "Would you like to enable SideJITServer", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in UserDefaults.standard.sidejitenable = true })
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    presentingVC.present(alert, animated: true)
                }
            }
        }
    }

    func askForNetwork() {
        let address = UserDefaults.standard.textInputSideJITServerurl ?? ""
        let SJSURL = address.isEmpty ? "http://sidejitserver._http._tcp.local:8080" : address
        URLSession.shared.dataTask(with: URL(string: "\(SJSURL)/re/")!).resume()
    }

    func isSideJITServerDetected(completion: @escaping (Result<Void, Error>) -> Void) {
        let address = UserDefaults.standard.textInputSideJITServerurl ?? ""
        let SJSURL = address.isEmpty ? "http://sidejitserver._http._tcp.local:8080" : address
        guard let url = URL(string: SJSURL) else { return }
        URLSession.shared.dataTask(with: url) { _, _, error in
            if let error { completion(.failure(error)) } else { completion(.success(())) }
        }.resume()
    }
}
