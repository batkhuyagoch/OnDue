import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            DigestView()
                .tabItem {
                    Label("Digest", systemImage: "list.bullet")
                }
            ConnectGmailView()
                .tabItem {
                    Label("Connect", systemImage: "envelope")
                }
        }
    }
}
