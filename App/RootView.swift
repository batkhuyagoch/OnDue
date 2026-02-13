import SwiftUI

struct RootView: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    
    var body: some View {
        TabView {
            NavigationStack {
                DigestView()
            }
            .tabItem {
                Label("Obligations", systemImage: "checklist")
            }
            
            ConnectGmailView()
                .tabItem {
                    Label("Connect", systemImage: "envelope")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }

#if DEBUG
            NavigationStack {
                GoldDatasetLabelView()
            }
            .tabItem {
                Label("Label", systemImage: "square.and.pencil")
            }
#endif
        }
    }
}
