import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            DigestView()
                .tabItem {
                    Label("Important", systemImage: "checklist")
                }
            ConnectGmailView()
                .tabItem {
                    Label("Connect", systemImage: "envelope")
                }
        }
    }
}
