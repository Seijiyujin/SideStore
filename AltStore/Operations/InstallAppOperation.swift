//
//  InstallAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//
import Foundation
import Network

import AltStoreCore
import AltSign
import Roxas
import minimuxer

@objc(InstallAppOperation)
final class InstallAppOperation: ResultOperation<InstalledApp>
{
    let context: InstallAppOperationContext
    
    private var didCleanUp = false
    
    init(context: InstallAppOperationContext)
    {
        self.context = context
        
        super.init()
        
        self.progress.totalUnitCount = 100
    }
    
    override func main()
    {
        super.main()
        
        if let error = self.context.error
        {
            self.finish(.failure(error))
            return
        }
        
        guard
            let certificate = self.context.certificate,
            let resignedApp = self.context.resignedApp
        else { return self.finish(.failure(OperationError.invalidParameters)) }
        
        let backgroundContext = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        backgroundContext.perform {
            
            /* App */
            let installedApp: InstalledApp
            
            // Fetch + update rather than insert + resolve merge conflicts to prevent potential context-level conflicts.
            if let app = InstalledApp.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), self.context.bundleIdentifier), in: backgroundContext)
            {
                installedApp = app
            }
            else
            {
                installedApp = InstalledApp(resignedApp: resignedApp, originalBundleIdentifier: self.context.bundleIdentifier, certificateSerialNumber: certificate.serialNumber, context: backgroundContext)
            }
            
            installedApp.update(resignedApp: resignedApp, certificateSerialNumber: certificate.serialNumber)
            installedApp.needsResign = false
            
            if let team = DatabaseManager.shared.activeTeam(in: backgroundContext)
            {
                installedApp.team = team
            }
            
            /* App Extensions */
            var installedExtensions = Set<InstalledExtension>()
            
            if
                let bundle = Bundle(url: resignedApp.fileURL),
                let directory = bundle.builtInPlugInsURL,
                let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants])
            {
                for case let fileURL as URL in enumerator
                {
                    guard let appExtensionBundle = Bundle(url: fileURL) else { continue }
                    guard let appExtension = ALTApplication(fileURL: appExtensionBundle.bundleURL) else { continue }
                    
                    let parentBundleID = self.context.bundleIdentifier
                    let resignedParentBundleID = resignedApp.bundleIdentifier
                    
                    let resignedBundleID = appExtension.bundleIdentifier
                    let originalBundleID = resignedBundleID.replacingOccurrences(of: resignedParentBundleID, with: parentBundleID)
                    
                    print("`parentBundleID`: \(parentBundleID)")
                    print("`resignedParentBundleID`: \(resignedParentBundleID)")
                    print("`resignedBundleID`: \(resignedBundleID)")
                    print("`originalBundleID`: \(originalBundleID)")
                    
                    let installedExtension: InstalledExtension
                    
                    if let appExtension = installedApp.appExtensions.first(where: { $0.bundleIdentifier == originalBundleID })
                    {
                        installedExtension = appExtension
                    }
                    else
                    {
                        installedExtension = InstalledExtension(resignedAppExtension: appExtension, originalBundleIdentifier: originalBundleID, context: backgroundContext)
                    }
                    
                    installedExtension.update(resignedAppExtension: appExtension)
                    
                    installedExtensions.insert(installedExtension)
                }
            }
            
            installedApp.appExtensions = installedExtensions
            
            self.context.beginInstallationHandler?(installedApp)
            
            // Temporary directory and resigned .ipa no longer needed, so delete them now to ensure AltStore doesn't quit before we get the chance to.
            self.cleanUp()
            
            var activeProfiles: Set<String>?
            if let sideloadedAppsLimit = UserDefaults.standard.activeAppsLimit
            {
                // When installing these new profiles, AltServer will remove all non-active profiles to ensure we remain under limit.
                
                let fetchRequest = InstalledApp.activeAppsFetchRequest()
                fetchRequest.includesPendingChanges = false
                
                var activeApps = InstalledApp.fetch(fetchRequest, in: backgroundContext)
                if !activeApps.contains(installedApp)
                {
                    let activeAppsCount = activeApps.map { $0.requiredActiveSlots }.reduce(0, +)
                    
                    let availableActiveApps = max(sideloadedAppsLimit - activeAppsCount, 0)
                    if installedApp.requiredActiveSlots <= availableActiveApps
                    {
                        // This app has not been explicitly activated, but there are enough slots available,
                        // so implicitly activate it.
                        installedApp.isActive = true
                        activeApps.append(installedApp)
                    }
                    else
                    {
                        installedApp.isActive = false
                    }
                }

                activeProfiles = Set(activeApps.flatMap { (installedApp) -> [String] in
                    let appExtensionProfiles = installedApp.appExtensions.map { $0.resignedBundleIdentifier }
                    return [installedApp.resignedBundleIdentifier] + appExtensionProfiles
                })
            }
            
            // Since reinstalling ourself will hang until we leave the app, force quit after 3 seconds if still installing
            var installing = true
            if installedApp.storeApp?.bundleIdentifier == Bundle.Info.appbundleIdentifier {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if installing {
                        print("We are still installing after 3 seconds")
                        
                        let alert = UIAlertController(title: "Finish Refresh", message: "To finish refreshing, SideStore must force close itself. Please reopen SideStore after continuing!", preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: NSLocalizedString("Continue", comment: ""), style: .default, handler: { _ in
                            if installing {
                                print("Closing SideStore since we are still installing")
                                exit(0)
                            } else {
                                print("Not closing SideStore since installing finished")
                            }
                        }))
                        
                        let keyWindow = UIApplication.shared.windows.filter { $0.isKeyWindow }.first
                        if var topController = keyWindow?.rootViewController {
                            while let presentedViewController = topController.presentedViewController {
                                topController = presentedViewController
                            }

                            topController.present(alert, animated: true)
                        } else {
                            print("No key window? Closing SideStore")
                            exit(0)
                        }
                    } else {
                        print("Installing finished")
                    }
                }
            }
            
            do {
                try install_ipa(installedApp.bundleIdentifier)
                installing = false
            } catch {
                installing = false
                return self.finish(.failure(error))
            }
            
            installedApp.refreshedDate = Date()
            self.finish(.success(installedApp))
        }
    }
    
    override func finish(_ result: Result<InstalledApp, Error>)
    {
        self.cleanUp()
        
        // Only remove refreshed IPA when finished.
        if let app = self.context.app
        {
            let fileURL = InstalledApp.refreshedIPAURL(for: app)
            
            do
            {
                try FileManager.default.removeItem(at: fileURL)
                print("Removed refreshed IPA")
            }
            catch
            {
                print("Failed to remove refreshed .ipa: \(error)")
            }
        }
        
        super.finish(result)
    }
}

private extension InstallAppOperation
{
    func cleanUp()
    {
        guard !self.didCleanUp else { return }
        self.didCleanUp = true
        
        do
        {
            try FileManager.default.removeItem(at: self.context.temporaryDirectory)
        }
        catch
        {
            print("Failed to remove temporary directory.", error)
        }
    }
}
