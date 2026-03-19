import SwiftUI

struct AccountSettingsView: View {
    var body: some View {
        List {
            AccountSection()
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SyncCoverageSettingsView: View {
    var body: some View {
        List {
            QuickSyncSection()
            YearScanSection()
        }
        .navigationTitle("Sync & Coverage")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct NotificationsSettingsView: View {
    var body: some View {
        List {
            NotificationsSection()
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyDataSettingsView: View {
    var body: some View {
        List {
            PrivacyDataSection()
        }
        .navigationTitle("Privacy & Data")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AboutSettingsView: View {
    var body: some View {
        List {
            AboutSection()
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
struct DeveloperSettingsView: View {
    var body: some View {
        List {
            DebugSection()
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
