//
//  DatabaseManager.swift
//  AltStore
//
//  Created by Riley Testut on 5/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import CoreData
import OSLog

import AltSign
import Roxas

extension CFNotificationName
{
    fileprivate static let willMigrateDatabase = CFNotificationName("com.rileytestut.AltStore.WillMigrateDatabase" as CFString)
}

private let ReceivedWillMigrateDatabaseNotification: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void = { (center, observer, name, object, userInfo) in
    DatabaseManager.shared.receivedWillMigrateDatabaseNotification()
}

fileprivate class PersistentContainer: RSTPersistentContainer
{
    override class func defaultDirectoryURL() -> URL
    {
        guard let sharedDirectoryURL = FileManager.default.altstoreSharedDirectory else { return super.defaultDirectoryURL() }
        
        let databaseDirectoryURL = sharedDirectoryURL.appendingPathComponent("Database")
        try? FileManager.default.createDirectory(at: databaseDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        return databaseDirectoryURL
    }
    
    class func legacyDirectoryURL() -> URL
    {
        return super.defaultDirectoryURL()
    }
}

public class DatabaseManager
{
    public static private(set) var shared = DatabaseManager()
    
    public let persistentContainer: RSTPersistentContainer
    
    public private(set) var isStarted = false
    
    private var startCompletionHandlers = [(Error?) -> Void]()
    private let dispatchQueue = DispatchQueue(label: "io.sidestore.DatabaseManager")
    
    private let coordinator = NSFileCoordinator()
    private let coordinatorQueue = OperationQueue()
    
    private var ignoreWillMigrateDatabaseNotification = false

    private var _observer: UnsafeMutableRawPointer?

    private init()
    {
        let bundle = Bundle(for: DatabaseManager.self)
        guard let modelURL = bundle.url(forResource: "AltStore", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: modelURL)
        else {
            fatalError("Core Data model 'AltStore.momd' not found in bundle \(bundle)")
        }
        self.persistentContainer = PersistentContainer(name: "AltStore", managedObjectModel: model)
        self.persistentContainer.viewContext.mergePolicy = MergePolicy()

        let storeURL = PersistentContainer.defaultDirectoryURL().appendingPathComponent("AltStore.sqlite")
        let storeDescription = NSPersistentStoreDescription(url: storeURL)
        storeDescription.shouldMigrateStoreAutomatically = true
        storeDescription.shouldInferMappingModelAutomatically = true
        self.persistentContainer.persistentStoreDescriptions = [storeDescription]
        
        let observer = Unmanaged.passUnretained(self).toOpaque()
        self._observer = observer
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, ReceivedWillMigrateDatabaseNotification, CFNotificationName.willMigrateDatabase.rawValue, nil, .deliverImmediately)
    }

    deinit
    {
        if let observer = self._observer
        {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, CFNotificationName.willMigrateDatabase, nil)
        }
    }
}


public extension DatabaseManager
{
    private class func loadPersistentStoresSync() {
        let container = Self.shared.persistentContainer
        let semaphore = DispatchSemaphore(value: 0)  // Semaphore to wait for async completion
        
        container.loadPersistentStores { description, error in
            if let error = error {
                print("Failed to load store: \(error)")
            } else {
                print("Store URL: \(description.url ?? URL(string: "unknown")!)")
            }
            
            semaphore.signal()  // Signal the semaphore to unblock the thread
        }
        
        semaphore.wait()  // Wait for the semaphore signal to unblock the thread
        print("Persistent store loading complete.")
    }
    
    class func deleteDatabase() -> Bool
    {
        // delete existing database and start fresh if required
        do {
            let container = Self.shared.persistentContainer
            
            // Reset the managed object context
            container.viewContext.reset()

            // Remove all existing persistent stores
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }

            var candidateURLs = [URL]()
            if let storeURL = container.persistentStoreCoordinator.persistentStores.first?.url {
                candidateURLs.append(storeURL)
            }
            candidateURLs.append(PersistentContainer.defaultDirectoryURL().appendingPathComponent("AltStore.sqlite"))
            candidateURLs.append(PersistentContainer.legacyDirectoryURL().appendingPathComponent("AltStore.sqlite"))

            for url in Set(candidateURLs) {
                try? container.persistentStoreCoordinator.destroyPersistentStore(
                    at: url,
                    ofType: NSSQLiteStoreType,
                    options: nil
                )
                
                let shmURL = URL(fileURLWithPath: url.path + "-shm")
                let walURL = URL(fileURLWithPath: url.path + "-wal")
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: shmURL)
                try? FileManager.default.removeItem(at: walURL)
            }
                
            print("\nDatabase Delete: SUCCEEDED\n")
            
            return true
        }catch{
            print("\nDatabase Delete request FAILED: \(error)\n")
            return false
        }
    }
    
    class func recreateDatabase() {
        // Try to perform delete if one exists
        _ = Self.deleteDatabase()
        
        // create new instance and load persistence store
        Self.shared = DatabaseManager()
    }

}

public extension DatabaseManager
{
    func start(completionHandler: @escaping (Error?) -> Void)
    {
        let log = OSLog(subsystem: "com.aero.aerostore", category: "database")
        
        func finish(_ error: Error?)
        {
            self.dispatchQueue.async {
                if error == nil
                {
                    self.isStarted = true
                }
                
                self.startCompletionHandlers.forEach { $0(error) }
                self.startCompletionHandlers.removeAll()
            }
        }
        
        self.dispatchQueue.async {
            self.startCompletionHandlers.append(completionHandler)
            guard self.startCompletionHandlers.count == 1 else { return }
            
            guard !self.isStarted else { return finish(nil) }
            
            os_log(.default, log: log, "DatabaseManager.start - beginning startup")
            
            // In simulator, when previews are generated, it initializes the db, in doing so this removal may be required
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.isPreview
            {
                do
                {
                    os_log(.default, log: log, "Purging database for preview...")
                    try FileManager.default.removeItem(at: PersistentContainer.defaultDirectoryURL())
                }
                catch
                {
                    os_log(.error, log: log, "Failed to remove database directory for preview: %{public}@", String(describing: error))
                }
            }
            #endif
            
            if self.persistentContainer.isMigrationRequired
            {
                os_log(.default, log: log, "Migration required — posting Darwin notification")
                self.ignoreWillMigrateDatabaseNotification = true
                CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), .willMigrateDatabase, nil, nil, true)
            }

            self.migrateDatabaseToAppGroupIfNeeded { (result) in
                switch result
                {
                case .failure(let error):
                    os_log(.error, log: log, "App group migration failed: %{public}@", String(describing: error))
                    finish(error)
                case .success:
                    os_log(.default, log: log, "App group migration done — loading persistent stores...")
                    os_log(.default, log: log, "Store URL: %{public}@", PersistentContainer.defaultDirectoryURL().appendingPathComponent("AltStore.sqlite").path)
                    os_log(.default, log: log, "Migration options: shouldMigrate=%@ shouldInfer=%@",
                           String(describing: self.persistentContainer.persistentStoreDescriptions.first?.shouldMigrateStoreAutomatically),
                           String(describing: self.persistentContainer.persistentStoreDescriptions.first?.shouldInferMappingModelAutomatically))
                    self.persistentContainer.loadPersistentStores { (description, error) in
                        if let error = error {
                            os_log(.error, log: log, "loadPersistentStores FAILED: %{public}@ (code: %d)", String(describing: error), (error as NSError).code)
                        } else {
                            os_log(.default, log: log, "loadPersistentStores succeeded — store URL: %{public}@", description.url?.path ?? "nil")
                        }
                        guard error == nil else { return finish(error!) }
                        
                        self.prepareDatabase() { (result) in
                            switch result
                            {
                            case .failure(let error):
                                os_log(.error, log: log, "prepareDatabase FAILED: %{public}@", String(describing: error))
                                finish(error)
                            case .success:
                                os_log(.default, log: log, "prepareDatabase succeeded")
                                finish(nil)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func signOut(completionHandler: @escaping (Error?) -> Void)
    {
        self.persistentContainer.performBackgroundTask { (context) in
            if let account = self.activeAccount(in: context)
            {
                account.isActiveAccount = false
            }
            
            if let team = self.activeTeam(in: context)
            {
                team.isActiveTeam = false
            }
            
            do
            {
                try context.save()
                
                Keychain.shared.reset()
                
                completionHandler(nil)
            }
            catch
            {
                print("Failed to save when signing out.", error)
                completionHandler(error)
            }
        }
    }
    
    func purgeLoggedErrors(before date: Date? = nil, completion: @escaping (Result<Void, Error>) -> Void)
    {
        self.persistentContainer.performBackgroundTask { context in
            do
            {
                let predicate = date.map { NSPredicate(format: "%K <= %@", #keyPath(LoggedError.date), $0 as NSDate) }
                
                let loggedErrors = LoggedError.all(satisfying: predicate, in: context, requestProperties: [\.returnsObjectsAsFaults: true])
                loggedErrors.forEach { context.delete($0) }
                
                try context.save()
                
                completion(.success(()))
            }
            catch
            {
                completion(.failure(error))
            }
        }
    }
    
    func updateFeaturedSortIDs() async
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy // DON'T use our custom merge policy, because that one ignores changes to featuredSortID.
        await context.performAsync {
            do
            {
                // Randomize source order
                let fetchRequest = Source.fetchRequest()
                let sources = try context.fetch(fetchRequest)
                
                for source in sources
                {
                    source.featuredSortID = UUID().uuidString
                }
                
                try context.save()
            }
            catch
            {
                Logger.main.error("Failed to update source order. \(error.localizedDescription, privacy: .public)")
            }
            
            do
            {
                // Randomize app order
                let fetchRequest = StoreApp.fetchRequest()
                let apps = try context.fetch(fetchRequest)
                
                for app in apps
                {
                    app.featuredSortID = UUID().uuidString
                }
                
                try context.save()
            }
            catch
            {
                Logger.main.error("Failed to update app order. \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

public extension DatabaseManager
{
    func startForPreview()
    {
        let semaphore = DispatchSemaphore(value: 0)
        
        self.dispatchQueue.async {
            self.startCompletionHandlers.append { error in
                semaphore.signal()
            }
        }
        
        _ = semaphore.wait(timeout: .now() + 2.0)
    }
}

public extension DatabaseManager
{
    var viewContext: NSManagedObjectContext {
        return self.persistentContainer.viewContext
    }
    
    func activeAccount(in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> Account?
    {
        let predicate = NSPredicate(format: "%K == YES", #keyPath(Account.isActiveAccount))
        
        let activeAccount = Account.first(satisfying: predicate, in: context)
        return activeAccount
    }
    
    func activeTeam(in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> Team?
    {
        let predicate = NSPredicate(format: "%K == YES", #keyPath(Team.isActiveTeam))
        
        let activeTeam = Team.first(satisfying: predicate, in: context)
        return activeTeam
    }
}

private extension DatabaseManager
{
    func prepareDatabase(completionHandler: @escaping (Result<Void, Error>) -> Void)
    {
        let log = OSLog(subsystem: "com.aero.aerostore", category: "database")
        os_log(.default, log: log, "prepareDatabase - ENTRY")
        guard !Bundle.isAppExtension() else {
            os_log(.default, log: log, "prepareDatabase - app extension, skipping")
            return completionHandler(.success(()))
        }
        
        os_log(.default, log: log, "prepareDatabase - creating ALTApplication...")
        let context = self.persistentContainer.newBackgroundContext()
        context.performAndWait {
            guard let localApp = ALTApplication(fileURL: Bundle.main.bundleURL)
            else {
                os_log(.error, log: log, "prepareDatabase - ALTApplication failed (nil)")
                struct PrepareError: LocalizedError {
                    var errorDescription: String? { NSLocalizedString("Failed to initialize ALTApplication", comment: "") }
                }
                completionHandler(.failure(PrepareError()))
                return
            }
            os_log(.default, log: log, "prepareDatabase - ALTApplication created: %{public}@", localApp.bundleIdentifier)
            
            let altStoreSource: Source
            
            if let source = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), Source.altStoreIdentifier), in: context)
            {
                altStoreSource = source
            }
            else
            {
                altStoreSource = Source.makeAltStoreSource(in: context)
            }
            
            // Make sure to always update source URL to be current.
            do {
                try altStoreSource.setSourceURL(Source.altStoreSourceURL)
            } catch {
                completionHandler(.failure(error))
                return
            }
            
            let storeApp: StoreApp
            
            if let app = StoreApp.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(StoreApp.bundleIdentifier), StoreApp.altstoreAppID), in: context)
            {
                storeApp = app
            }
            else
            {
                storeApp = StoreApp.makeAltStoreApp(version: localApp.version, buildVersion: nil, in: context)
                storeApp.source = altStoreSource
            }
                        
            let serialNumber = Bundle.main.object(forInfoDictionaryKey: Bundle.Info.certificateID) as? String
            let installedApp: InstalledApp
            
            if let app = storeApp.installedApp
            {
                installedApp = app
            }
            else
            {
                //TODO: Support build versions.
                // For backwards compatibility reasons, we cannot use localApp's buildVersion as storeBuildVersion,
                // or else the latest update will _always_ be considered new because we don't use buildVersions in our source (yet).
                installedApp = InstalledApp(resignedApp: localApp, originalBundleIdentifier: StoreApp.altstoreAppID, certificateSerialNumber: serialNumber, storeBuildVersion: nil, context: context)
                
                // figure out if the current AltStoreApp is signed with "Use Main Profie" option
                // by checking if the first extension's entitlement's application-identifier matches current one
                repeat {
                    guard let pluginURL = Bundle.main.builtInPlugInsURL else {
                        installedApp.useMainProfile = true
                        break
                    }
                    guard let pluginFolders = try? FileManager.default.contentsOfDirectory(at: pluginURL, includingPropertiesForKeys: nil) else {
                        installedApp.useMainProfile = true
                        break
                    }
                    
                    guard let pluginFolder = pluginFolders.first, let altPluginApp = ALTApplication(fileURL: pluginFolder) else {
                        installedApp.useMainProfile = true
                        break
                    }
                    
                    let entitlements = altPluginApp.entitlements
                    guard let appId = entitlements[ALTEntitlement.applicationIdentifier] as? String else {
                        installedApp.useMainProfile = false
                        print("no ALTEntitlementApplicationIdentifier???")
                        break
                    }
                    
                    if appId.hasSuffix(Bundle.main.bundleIdentifier!) {
                        installedApp.useMainProfile = true
                    } else {
                        installedApp.useMainProfile = false
                    }
                    
                    
                } while(false)
                
                installedApp.storeApp = storeApp
            }
            
            /* App Extensions */
            var installedExtensions = Set<InstalledExtension>()
            
            for appExtension in localApp.appExtensions
            {
                let resignedBundleID = appExtension.bundleIdentifier
                let originalBundleID = resignedBundleID.replacingOccurrences(of: localApp.bundleIdentifier, with: StoreApp.altstoreAppID)
                
                let installedExtension: InstalledExtension
                
                if let appExtension = installedApp.appExtensions.first(where: { $0.bundleIdentifier == originalBundleID })
                {
                    installedExtension = appExtension
                }
                else
                {
                    installedExtension = InstalledExtension(resignedAppExtension: appExtension, originalBundleIdentifier: originalBundleID, context: context)
                }
                
                installedExtension.update(resignedAppExtension: appExtension)
                
                installedExtensions.insert(installedExtension)
            }
            
            installedApp.appExtensions = installedExtensions
            
            let fileURL = installedApp.fileURL
            
            // @mahee96: it shouldn't matter if it is debug/release, the file is expected to be in its place (except for simulator probably coz it doesn't suppor app installs anyway)
            #if DEBUG && targetEnvironment(simulator)
            let replaceCachedApp = true
            #else
            let replaceCachedApp = !FileManager.default.fileExists(atPath: fileURL.path) || installedApp.version != localApp.version || installedApp.buildVersion != localApp.buildVersion
            #endif
            
            if replaceCachedApp
            {
                func update(_ bundle: Bundle, bundleID: String) throws
                {
                    let infoPlistURL = bundle.bundleURL.appendingPathComponent("Info.plist")
                    
                    guard var infoDictionary = bundle.completeInfoDictionary else { throw ALTError(.missingInfoPlist) }
                    infoDictionary[kCFBundleIdentifierKey as String] = bundleID
                    try (infoDictionary as NSDictionary).write(to: infoPlistURL)
                }
                
                FileManager.default.prepareTemporaryURL() { (temporaryFileURL) in
                    do
                    {
                        try FileManager.default.copyItem(at: Bundle.main.bundleURL, to: temporaryFileURL)
                        
                        guard let appBundle = Bundle(url: temporaryFileURL) else { throw ALTError(.invalidApp) }
                        try update(appBundle, bundleID: StoreApp.altstoreAppID)
                        
                        if let tempApp = ALTApplication(fileURL: temporaryFileURL)
                        {
                            for appExtension in tempApp.appExtensions
                            {
                                guard let extensionBundle = Bundle(url: appExtension.fileURL) else { throw ALTError(.invalidApp) }
                                guard let installedExtension = installedExtensions.first(where: { $0.resignedBundleIdentifier == appExtension.bundleIdentifier }) else { throw ALTError(.invalidApp) }
                                try update(extensionBundle, bundleID: installedExtension.bundleIdentifier)
                            }
                        }
                        
                        try FileManager.default.copyItem(at: temporaryFileURL, to: fileURL, shouldReplace: true)
                    }
                    catch
                    {
                        print("Failed to copy SideStore app bundle to its proper location.", error)
                    }
                }
            }
            
            let cachedRefreshedDate = installedApp.refreshedDate
            let cachedExpirationDate = installedApp.expirationDate
                        
            // Must go after comparing versions to see if we need to update our cached AltStore app bundle.
            installedApp.update(resignedApp: localApp, certificateSerialNumber: serialNumber, storeBuildVersion: nil)
            
            if installedApp.refreshedDate < cachedRefreshedDate
            {
                // Embedded provisioning profile has a creation date older than our refreshed date.
                // This most likely means we've refreshed the app since then, and profile is now outdated,
                // so use cached dates instead (i.e. not the dates updated from provisioning profile).
                
                installedApp.refreshedDate = cachedRefreshedDate
                installedApp.expirationDate = cachedExpirationDate
            }
            
            do
            {
                os_log(.default, log: log, "prepareDatabase - saving context...")
                try context.save()
                os_log(.default, log: log, "prepareDatabase - context saved")
                
                Task(priority: .high) {
                    await self.updateFeaturedSortIDs()
                    completionHandler(.success(()))
                }
            }
            catch
            {
                os_log(.error, log: log, "prepareDatabase - context save FAILED: %{public}@", String(describing: error))
                completionHandler(.failure(error))
            }
            os_log(.default, log: log, "prepareDatabase - EXIT")
        }
    }
    
    func migrateDatabaseToAppGroupIfNeeded(completion: @escaping (Result<Void, Error>) -> Void)
    {
        // Only migrate if we haven't migrated yet and there's a valid AltStore app group.
        guard UserDefaults.shared.requiresAppGroupMigration && Bundle.main.altstoreAppGroup != nil else { return completion(.success(())) }

        func finish(_ result: Result<Void, Error>)
        {
            switch result
            {
            case .failure(let error): completion(.failure(error))
            case .success:
                UserDefaults.shared.requiresAppGroupMigration = false
                completion(.success(()))
            }
        }
        
        let previousDatabaseURL = PersistentContainer.legacyDirectoryURL().appendingPathComponent("AltStore.sqlite")
        let databaseURL = PersistentContainer.defaultDirectoryURL().appendingPathComponent("AltStore.sqlite")
        
        let previousAppsDirectoryURL = InstalledApp.legacyAppsDirectoryURL
        let appsDirectoryURL = InstalledApp.appsDirectoryURL
        
        let databaseIntent = NSFileAccessIntent.writingIntent(with: databaseURL, options: [.forReplacing])
        let appsIntent = NSFileAccessIntent.writingIntent(with: appsDirectoryURL, options: [.forReplacing])
        
        self.coordinator.coordinate(with: [databaseIntent, appsIntent], queue: self.coordinatorQueue) { (error) in
            do
            {
                if let error = error
                {
                    throw error
                }
                
                let description = NSPersistentStoreDescription(url: previousDatabaseURL)
                
                // Disable WAL to remove extra files automatically during migration.
                description.setOption(["journal_mode": "DELETE"] as NSDictionary, forKey: NSSQLitePragmasOption)

                description.shouldMigrateStoreAutomatically = true
                description.shouldInferMappingModelAutomatically = true
                
                let persistentStoreCoordinator = NSPersistentStoreCoordinator(managedObjectModel: self.persistentContainer.managedObjectModel)
                
                // Migrate database
                if FileManager.default.fileExists(atPath: previousDatabaseURL.path)
                {
                    if FileManager.default.fileExists(atPath: databaseURL.path, isDirectory: nil)
                    {
                        try FileManager.default.removeItem(at: databaseURL)
                    }
                    
                    let previousDatabase = try persistentStoreCoordinator.addPersistentStore(ofType: description.type, configurationName: description.configuration, at: description.url, options: description.options)
                    
                    // Pass nil options to prevent later error due to self.persistentContainer using WAL.
                    try persistentStoreCoordinator.migratePersistentStore(previousDatabase, to: databaseURL, options: nil, withType: NSSQLiteStoreType)
                    
                    try FileManager.default.removeItem(at: previousDatabaseURL)
                }
                
                // Migrate apps
                if FileManager.default.fileExists(atPath: previousAppsDirectoryURL.path, isDirectory: nil)
                {
                    if(previousAppsDirectoryURL.path != appsDirectoryURL.path)
                    {
                        _ = try FileManager.default.replaceItemAt(appsDirectoryURL, withItemAt: previousAppsDirectoryURL)
                    }
                }
                
                finish(.success(()))
            }
            catch
            {
                print("Failed to migrate database to app group:", error)
                finish(.failure(error))
            }
        }
    }
    
    func receivedWillMigrateDatabaseNotification()
    {
        defer { self.ignoreWillMigrateDatabaseNotification = false }

        // Ignore notifications sent by the current process.
        guard !self.ignoreWillMigrateDatabaseNotification else { return }

        exit(104)
    }
}
