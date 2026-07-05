//
//  SceneDelegate.swift
//  AltStore
//
//  Created by Riley Testut on 7/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import UIKit
import AltStoreCore
import OSLog


@available(iOS 13, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
    var window: UIWindow?

    // Holds an imported .ipa URL when the scene isn't active yet (cold launch),
    // so the import notification can be posted once the scene becomes active.
    private var pendingImportIPAURL: URL?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions)
    {
        let log = OSLog(subsystem: "com.aero.aerostore", category: "startup")
        os_log(.default, log: log, "scene:willConnectTo - ENTRY")
        
        guard let windowScene = (scene as? UIWindowScene) else {
            os_log(.error, log: log, "SceneDelegate: Failed to get UIWindowScene")
            return
        }

        os_log(.default, log: log, "SceneDelegate: UIWindowScene obtained — windows count: %d", windowScene.windows.count)

        self.window = windowScene.windows.first { $0.isKeyWindow } ?? windowScene.windows.first
        windowScene.windows.forEach {
            $0.backgroundColor = .systemBackground
            $0.tintColor = .altPrimary
        }

        DispatchQueue.main.async {
            FluxAppearancePreference.applyToAllWindows()
        }

        scheduleLaunchSafetyNet()
        os_log(.default, log: log, "scene:willConnectTo - EXIT")
        
        if let context = connectionOptions.urlContexts.first
        {
            self.open(context)
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        let log = OSLog(subsystem: "com.aero.aerostore", category: "startup")
        os_log(.default, log: log, "sceneDidDisconnect")
    }

    func sceneDidBecomeActive(_ scene: UIScene)
    {
        scheduleLaunchSafetyNet()

        // Flush any .ipa import that arrived before the scene was active (cold launch).
        guard let url = self.pendingImportIPAURL else { return }
        self.pendingImportIPAURL = nil
        NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: url])
    }

    private static var didScheduleSafetyNet = false

    private func scheduleLaunchSafetyNet()
    {
        // Only schedule ONE safety net per process lifetime to avoid races
        // with the LaunchViewController's own launch sequence.
        guard !Self.didScheduleSafetyNet else { return }
        Self.didScheduleSafetyNet = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                // If the LaunchViewController already installed the main
                // interface, there is nothing to do.
                guard !AppLaunchCoordinator.isMainInterfaceInstalled else { return }

                // If DB is not started yet, wait for it.
                guard DatabaseManager.shared.isStarted else {
                    print("⚠️ SafetyNet: DB not started yet, waiting 3 more seconds...")
                    // Wait a bit more — LaunchViewController is probably still
                    // in its own start sequence.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        Task { @MainActor in
                            guard !AppLaunchCoordinator.isMainInterfaceInstalled else { return }
                            DatabaseManager.shared.start { error in
                                Task { @MainActor in
                                    guard error == nil else {
                                        print("⚠️ SafetyNet: DB start failed, not installing main interface: \(String(describing: error))")
                                        return
                                    }
                                    AppLaunchCoordinator.installMainInterfaceIfNeeded(reason: "scene safety net (extended)")
                                }
                            }
                        }
                    }
                    return
                }
                AppLaunchCoordinator.installMainInterfaceIfNeeded(reason: "scene safety net")
            }
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene)
    {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
        
        // applicationWillEnterForeground is _not_ called when launching app,
        // whereas sceneWillEnterForeground _is_ called when launching.
        // As a result, DatabaseManager might not be started yet, so just return if it isn't
        // (since all these methods are called separately during app startup).
        guard DatabaseManager.shared.isStarted else { return }
        
        AppManager.shared.update()
        if UserDefaults.standard.enableEMPforWireguard {
            startEMProxy(bind_addr: AppConstants.Proxy.serverURL)
        }
    }

    func sceneDidEnterBackground(_ scene: UIScene)
    {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
        
        guard UIApplication.shared.applicationState == .background else { return }
        
        // Make sure to update AppDelegate.applicationDidEnterBackground() as well.

        // TODO: @mahee96: find if we need to stop em_proxy as in altstore?
        if UserDefaults.standard.enableEMPforWireguard {
            stopEMProxy()
        }

        guard let oneMonthAgo = Calendar.current.date(byAdding: .month, value: -1, to: Date()) else { return }
        
        let midnightOneMonthAgo = Calendar.current.startOfDay(for: oneMonthAgo)
        DatabaseManager.shared.purgeLoggedErrors(before: midnightOneMonthAgo) { result in
            switch result
            {
            case .success: break
            case .failure(let error): print("[ALTLog] Failed to purge logged errors before \(midnightOneMonthAgo).", error)
            }
        }
        
    }
    
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>)
    {
        guard let context = URLContexts.first else { return }
        self.open(context)
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
        if shortcutItem.type == "com.aero.aerostore.shortcut.refreshAll" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AppDelegate.refreshAllAppsDeepLinkNotification, object: nil, userInfo: nil)
            }
            completionHandler(true)
        } else if shortcutItem.type == "com.aero.aerostore.shortcut.enableJIT" {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: AppDelegate.enableJITDeepLinkNotification, object: nil, userInfo: nil)
            }
            completionHandler(true)
        } else {
            completionHandler(false)
        }
    }
}

private extension SceneDelegate
{
    func open(_ context: UIOpenURLContext)
    {
        if context.url.isFileURL
        {
            guard context.url.pathExtension.lowercased() == "ipa" else { return }

            // Copy the shared .ipa out of its security-scoped location into a
            // temporary directory we own, so it stays readable while signing.
            if !context.url.startAccessingSecurityScopedResource() {
                print("[ALTLog] Failed to access security-scoped resource for imported IPA")
                return
            }
            defer { context.url.stopAccessingSecurityScopedResource() }

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            do {
                try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("[ALTLog] Failed to create temp directory for imported IPA: \(error)")
                return
            }

            let ipa = temporaryDirectory.appendingPathComponent(context.url.lastPathComponent)

            do {
                try FileManager.default.copyItem(at: context.url, to: ipa)
            } catch {
                print("[ALTLog] Failed to copy imported IPA: \(error)")
                return
            }

            if UIApplication.shared.applicationState == .active {
                NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: ipa])
            } else {
                // Defer until the scene is active (cold launch) — see sceneDidBecomeActive.
                self.pendingImportIPAURL = ipa
            }
        }
        else
        {
            guard let components = URLComponents(url: context.url, resolvingAgainstBaseURL: false) else { return }
            guard let host = components.host?.lowercased() else { return }
            
            switch host
            {
            case "appbackupresponse":
                let result: Result<Void, Error>
                
                switch context.url.path.lowercased()
                {
                case "/success": result = .success(())
                case "/failure":
                    let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value } ?? [:]
                    guard
                        let errorDomain = queryItems["errorDomain"],
                        let errorCodeString = queryItems["errorCode"], let errorCode = Int(errorCodeString),
                        let errorDescription = queryItems["errorDescription"]
                    else { return }
                    
                    let error = NSError(domain: errorDomain, code: errorCode, userInfo: [NSLocalizedDescriptionKey: errorDescription])
                    result = .failure(error)
                    
                default: return
                }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.appBackupDidFinish, object: nil, userInfo: [AppDelegate.appBackupResultKey: result])
                }
                
            case "install":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let downloadURLString = queryItems["url"], let downloadURL = URL(string: downloadURLString) else { return }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.importAppDeepLinkNotification, object: nil, userInfo: [AppDelegate.importAppDeepLinkURLKey: downloadURL])
                }
            
            case "source":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let sourceURLString = queryItems["url"], let sourceURL = URL(string: sourceURLString) else { return }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.addSourceDeepLinkNotification, object: nil, userInfo: [AppDelegate.addSourceDeepLinkURLKey: sourceURL])
                }
                
            case "pairing":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                Logger.main.info("queryItems \(queryItems)")
                guard let callbackTemplate = queryItems["urlname"]?.removingPercentEncoding else { return }
                
                DispatchQueue.main.async {
                    exportPairingFile(callbackTemplate)
                }
                
            case "certificate":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let callbackTemplate = queryItems["callback_template"]?.removingPercentEncoding else { return }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.exportCertificateNotification, object: nil, userInfo: [AppDelegate.exportCertificateCallbackTemplateKey: callbackTemplate])
                }

            case "sidejit-enable":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                guard let bundleID = queryItems["bid"]?.removingPercentEncoding else { return }

                DispatchQueue.main.async {
                    DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
                        do {
                            let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), bundleID)
                            guard let installedApp = InstalledApp.first(satisfying: predicate, in: context) else { throw URLError(.fileDoesNotExist) }

                            AppManager.shared.enableJIT(for: installedApp) { result in
                                switch result {
                                case .success:
                                    // Relaunch LiveContainer
                                    let relaunchURL = URL(string: "livecontainer://livecontainer-relaunch")!
                                    UIApplication.shared.open(relaunchURL, options: [:], completionHandler: nil)

                                case .failure(let error):
                                    // Log error or show a toast
                                    print("Failed to enable JIT for \(bundleID): \(error.localizedDescription)")
                                    // Relaunch LiveContainer even on error to unblock it
                                    let relaunchURL = URL(string: "livecontainer://livecontainer-relaunch")!
                                    UIApplication.shared.open(relaunchURL, options: [:], completionHandler: nil)
                                }
                            }
                        } catch {
                            print("Error handling sidejit-enable URL: \(error.localizedDescription)")
                            // Relaunch LiveContainer even on error to unblock it
                            let relaunchURL = URL(string: "livecontainer://livecontainer-relaunch")!
                            UIApplication.shared.open(relaunchURL, options: [:], completionHandler: nil)
                        }
                    }
                }

            case "refresh-all":
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.refreshAllAppsDeepLinkNotification, object: nil, userInfo: nil)
                }

            case "enable-jit":
                let queryItems = components.queryItems?.reduce(into: [String: String]()) { $0[$1.name.lowercased()] = $1.value } ?? [:]
                let bundleID = queryItems["bundle-id"] ?? queryItems["bid"]
                var userInfo: [AnyHashable: Any] = [:]
                if let bundleID = bundleID?.removingPercentEncoding {
                    userInfo["bundleID"] = bundleID
                }
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: AppDelegate.enableJITDeepLinkNotification, object: nil, userInfo: userInfo.isEmpty ? nil : userInfo)
                }

            default: break
            }
        }
    }
}


func exportPairingFile(_ urlname: String) {
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first, let viewcontroller = window.rootViewController {
        let fm = FileManager.default
        let documentsPath = fm.documentsDirectory.appendingPathComponent("ALTPairingFile.mobiledevicepairing")
        
        
        guard let data = try? Data(contentsOf: documentsPath) else {
            let toastView = ToastView(text: NSLocalizedString("Failed to find Pairing File!", comment: ""), detailText: nil)
            toastView.show(in: viewcontroller)
            return
        }
        
        let base64encodedCert = data.base64EncodedString()
        var allowedQueryParamAndKey = NSCharacterSet.urlQueryAllowed
        allowedQueryParamAndKey.remove(charactersIn: ";/?:@&=+$, ")
        guard let encodedCert = base64encodedCert.addingPercentEncoding(withAllowedCharacters: allowedQueryParamAndKey) else {
            let toastView = ToastView(text: NSLocalizedString("Failed to encode pairingFile!", comment: ""), detailText: nil)
            toastView.show(in: viewcontroller)
            return
        }
        
        var urlStr = "\(urlname)://pairingFile?data=$(BASE64_PAIRING)"
        let finished = urlStr.replacingOccurrences(of: "$(BASE64_PAIRING)", with: encodedCert, options: .literal, range: nil)
        
        print(finished)
        guard let callbackUrl = URL(string: finished) else {
            let toastView = ToastView(text: NSLocalizedString("Failed to initialize callback URL!", comment: ""), detailText: nil)
            toastView.show(in: viewcontroller)
            return
        }
        UIApplication.shared.open(callbackUrl)
    }
}
