import SwiftUI
import GoogleSignIn
import BackgroundTasks

@main
struct OnDueApp: App {
    @StateObject private var environmentStore = AppEnvironmentStore(.live())

    init() {
        BackgroundSyncManager.register {
            AppEnvironment.live()
        }
        YearScanBackgroundManager.register(environmentProvider: {
            AppEnvironment.live()
        })
    }

    var body: some Scene {
        WindowGroup {
            RootView_Clean()
                .environmentObject(environmentStore)
                .onOpenURL { url in
                    // Handle Google Sign-In callback
                    // Only handle if it's a Google Sign-In URL
                    if url.scheme == GmailConfiguration.reversedClientID {
                        _ = GIDSignIn.sharedInstance.handle(url)
                    }
                }
                .task {
                    // Note: Session restore now happens in AuthenticationState.checkSignInStatus()
                    BackgroundSyncManager.scheduleIfEnabled(environment: environmentStore.value)
                    
                    // Setup daily digest notifications
                    await setupNotifications()
                }
        }
    }
    
    private func setupNotifications() async {
        // Setup notification categories and actions (always do this)
        DailyDigestScheduler.shared.setupNotificationCategories()
        
        // Check if user has previously enabled daily digest
        let dailyDigestEnabled = UserDefaults.standard.bool(forKey: "notifications.dailyDigest.enabled")
        
        if dailyDigestEnabled {
            // User has opted in - restore their schedule
            let hour = UserDefaults.standard.integer(forKey: "notifications.dailyDigest.hour")
            let minute = UserDefaults.standard.integer(forKey: "notifications.dailyDigest.minute")
            
            // Use default 9 AM if not set
            let finalHour = hour == 0 && minute == 0 ? 9 : hour
            
            do {
                try await DailyDigestScheduler.shared.scheduleDailyDigest(
                    at: DateComponents(hour: finalHour, minute: minute)
                )
            } catch {
                print("Failed to restore notification schedule: \(error)")
            }
        }
        // If not enabled, do nothing - let user enable in Settings
    }
}
