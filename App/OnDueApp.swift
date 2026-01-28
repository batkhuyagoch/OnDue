import SwiftUI
import GoogleSignIn

@main
struct OnDueApp: App {
    @StateObject private var environmentStore = AppEnvironmentStore(.live())

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
                }
        }
    }
}
