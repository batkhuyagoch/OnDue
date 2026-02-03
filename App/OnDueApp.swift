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
                }
        }
    }
}
