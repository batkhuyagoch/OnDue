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
            RootView()
                .environmentObject(environmentStore)
                .onOpenURL { url in
                    // Handle Google Sign-In callback
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    // Try to restore previous sign-in
                    _ = try? await GmailAuthService.shared.restorePreviousSignIn()
                    BackgroundSyncManager.scheduleIfEnabled(environment: environmentStore.value)
                    
                    // Setup daily digest notifications
                    await setupNotifications()
                }
        }
    }
    
    private func setupNotifications() async {
        // Setup notification categories and actions
        DailyDigestScheduler.shared.setupNotificationCategories()
        
        // Request permission (will show system alert if not already granted)
        do {
            try await DailyDigestScheduler.shared.requestAuthorization()
            
            // Schedule daily digest at 9 AM by default
            try await DailyDigestScheduler.shared.scheduleDailyDigest(
                at: DateComponents(hour: 9, minute: 0)
            )
        } catch {
            // Permission denied or other error - fail silently
            // User can enable later in Settings
            print("Notification setup skipped: \(error)")
        }
    }
}
