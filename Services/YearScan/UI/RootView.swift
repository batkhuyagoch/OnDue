import SwiftUI

// MARK: - Main App Entry Point

struct RootView: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @StateObject private var authState = AuthenticationState()
    
    var body: some View {
        Group {
            if authState.isCheckingSignIn {
                SplashScreen()
            } else if authState.isSignedIn {
                MainAppView()
                    .environmentObject(authState)
            } else {
                OnboardingFlow()
                    .environmentObject(authState)
            }
        }
        .task {
            await authState.checkSignInStatus()
            if authState.isSignedIn, let email = authState.userEmail {
                _ = try? await environmentStore.value.mailboxAccountRepository.getOrCreate(
                    email: email,
                    provider: .gmail
                )
            }
        }
    }
}

// MARK: - Splash Screen

private struct SplashScreen: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
                .symbolEffect(.pulse)
            
            Text("OnDue")
                .font(.largeTitle.weight(.bold))
            
            ProgressView()
                .controlSize(.regular)
                .padding(.top, 20)
        }
    }
}

// MARK: - Main App (Single Tab with Profile Icon)

struct MainAppView: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var authState: AuthenticationState
    @State private var showSettings = false
    @StateObject private var yearScanState = YearScanState()
    
    var body: some View {
        NavigationStack {
            DigestView_Redesigned()
                .environmentObject(yearScanState)
                .navigationTitle("Obligations")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        EmptyView()
                    }
                    
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "person.circle")
                                .font(.title3)
                                .foregroundStyle(.primary)
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if yearScanState.shouldShowBanner {
                        YearScanBanner(state: yearScanState)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsSheet()
                        .environmentObject(environmentStore)
                        .environmentObject(authState)
                        .environmentObject(yearScanState)
                }
        }
        .task {
            await yearScanState.loadStatus(using: environmentStore.value)
        }
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var authState: AuthenticationState
    @EnvironmentObject private var yearScanState: YearScanState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notifications.dailyDigest.enabled") private var dailyDigestEnabled = false
    
    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    AccountSettingsView()
                } label: {
                    SettingsIndexRow(
                        title: "Account",
                        subtitle: accountSubtitle,
                        subtitleColor: accountSubtitleColor,
                        subtitleSystemImage: authState.isSignedIn ? "checkmark.circle.fill" : "xmark.circle",
                        subtitleSystemImageColor: authState.isSignedIn ? .green : .secondary,
                        systemImage: "person.crop.circle"
                    )
                }

                NavigationLink {
                    SyncCoverageSettingsView()
                } label: {
                    SettingsIndexRow(
                        title: "Sync & Coverage",
                        subtitle: syncCoverageSubtitle,
                        subtitleColor: syncCoverageSubtitleColor,
                        subtitleSystemImage: syncCoverageSubtitleSystemImage,
                        subtitleSystemImageColor: syncCoverageSubtitleColor,
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }

                NavigationLink {
                    NotificationsSettingsView()
                } label: {
                    SettingsIndexRow(
                        title: "Notifications",
                        subtitle: dailyDigestEnabled ? "Daily Digest enabled" : "Daily Digest off",
                        subtitleColor: dailyDigestEnabled ? .blue : .secondary,
                        subtitleSystemImage: dailyDigestEnabled ? "bell.fill" : "bell.slash",
                        subtitleSystemImageColor: dailyDigestEnabled ? .blue : .secondary,
                        systemImage: "bell.badge"
                    )
                }

                NavigationLink {
                    PrivacyDataSettingsView()
                } label: {
                    SettingsIndexRow(
                        title: "Privacy & Data",
                        subtitle: "Manage local storage and data",
                        systemImage: "hand.raised"
                    )
                }

                NavigationLink {
                    AboutSettingsView()
                } label: {
                    SettingsIndexRow(
                        title: "About",
                        subtitle: appVersionSubtitle,
                        systemImage: "info.circle"
                    )
                }

                #if DEBUG
                NavigationLink {
                    DeveloperSettingsView()
                } label: {
                    SettingsIndexRow(
                        title: "Developer",
                        subtitle: "Debug tools and dataset utilities",
                        systemImage: "hammer"
                    )
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var accountSubtitle: String {
        if authState.isSignedIn, let email = authState.userEmail, !email.isEmpty {
            return email
        }
        return "Not connected"
    }

    private var accountSubtitleColor: Color {
        authState.isSignedIn ? .green : .secondary
    }

    private var syncCoverageSubtitle: String {
        if yearScanState.isScanning {
            if let progress = yearScanState.scanProgress {
                return "Running • \(Int((progress * 100).rounded(.down)))% complete"
            }
            return "Running"
        }
        if yearScanState.canResume {
            return "Paused • Resume available"
        }
        if let lastScan = yearScanState.lastScanDate {
            return "Last scan \(lastScan.formatted(.relative(presentation: .named)))"
        }
        return "Not started"
    }

    private var syncCoverageSubtitleColor: Color {
        if yearScanState.isScanning {
            return .blue
        }
        if yearScanState.canResume {
            return .orange
        }
        return .secondary
    }

    private var syncCoverageSubtitleSystemImage: String {
        if yearScanState.isScanning {
            return "arrow.clockwise"
        }
        if yearScanState.canResume {
            return "pause.circle.fill"
        }
        if yearScanState.lastScanDate != nil {
            return "checkmark.circle"
        }
        return "clock"
    }

    private var appVersionSubtitle: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (s?, b?) where !s.isEmpty && !b.isEmpty:
            return "Version \(s) (\(b))"
        case let (s?, _) where !s.isEmpty:
            return "Version \(s)"
        default:
            return "App information"
        }
    }
}

private struct SettingsIndexRow: View {
    let title: String
    let subtitle: String
    var subtitleColor: Color = .secondary
    var subtitleSystemImage: String? = nil
    var subtitleSystemImageColor: Color = .secondary
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    if let subtitleSystemImage {
                        Image(systemName: subtitleSystemImage)
                            .font(.caption2)
                            .foregroundStyle(subtitleSystemImageColor)
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(subtitleColor)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
