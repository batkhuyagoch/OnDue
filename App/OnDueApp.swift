import SwiftUI

@main
struct OnDueApp: App {
    @StateObject private var environmentStore = AppEnvironmentStore(.live())

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(environmentStore)
        }
    }
}
