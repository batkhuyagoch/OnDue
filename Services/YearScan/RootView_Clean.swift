import SwiftUI
import SwiftUI
import GoogleSignIn
import Combine
import Foundation
import GRDB
import UserNotifications

// MARK: - Main App Entry Point

struct RootView_Clean: View {
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
                .navigationTitle("Obligations")
                .toolbar {
                    // Left: Filter menu (existing)
                    ToolbarItem(placement: .topBarLeading) {
                        // Keep existing filter menu from DigestView
                        EmptyView()
                    }
                    
                    // Right: Profile icon for settings
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
                    // Smart year scan banner (only shows when needed)
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
    
    var body: some View {
        NavigationStack {
            List {
                // Account Section
                AccountSection()
                
                // Quick Sync Section
                QuickSyncSection()
                
                // Year Scan Section
                YearScanSection()
                
                // Notifications Section
                NotificationsSection()
                
                // Privacy & Data Section
                PrivacyDataSection()
                
                // About Section
                AboutSection()
                
                #if DEBUG
                // Debug Section (only in debug builds)
                DebugSection()
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
}

// MARK: - Settings Sections

private struct AccountSection: View {
    @EnvironmentObject private var authState: AuthenticationState
    @State private var showSignOutConfirmation = false
    
    var body: some View {
        Section {
            if authState.isSignedIn, let email = authState.userEmail {
                // Connected state
                HStack(spacing: 12) {
                    Image(systemName: "person.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(email)
                            .font(.subheadline.weight(.semibold))
                        
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                            Text("Connected")
                                .font(.caption)
                        }
                        .foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 8)
                
                if let lastSync = authState.lastSyncDate {
                    HStack {
                        Text("Last synced")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(lastSync.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                
                Button {
                    showSignOutConfirmation = true
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                }
            } else {
                // Not connected
                Button {
                    Task {
                        await authState.signIn()
                    }
                } label: {
                    Label("Connect Gmail", systemImage: "envelope")
                }
            }
        } header: {
            Text("Account")
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirmation) {
            Button("Sign Out", role: .destructive) {
                Task {
                    await authState.signOut()
                }
            }
        } message: {
            Text("You'll need to reconnect to sync obligations")
        }
    }
}

private struct QuickSyncSection: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var authState: AuthenticationState
    @State private var isSyncing = false
    @State private var lastSyncDate: Date?
    @State private var syncStatus: String?
    @State private var syncError: String?
    @State private var daysToSync = 30
    @State private var forceFullSync = false
    @State private var showSyncOptions = false
    
    var body: some View {
        Section {
            // Last sync info
            if let lastSync = lastSyncDate {
                LabeledContent("Last synced", value: lastSync.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("Never synced")
                    .foregroundStyle(.secondary)
            }
            
            // Status message
            if let status = syncStatus {
                HStack {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(isSyncing ? .secondary : Color.green)
                }
            }
            
            // Error message
            if let error = syncError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            
            // Sync options (collapsible)
            DisclosureGroup("Sync Options", isExpanded: $showSyncOptions) {
                VStack(spacing: 12) {
                    // Days to sync picker
                    Picker("Days to sync", selection: $daysToSync) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.menu)
                    
                    // Force full sync toggle
                    Toggle("Force full re-scan", isOn: $forceFullSync)
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            
            // Sync button
            if isSyncing {
                HStack {
                    ProgressView()
                    Text("Syncing...")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task {
                        await performQuickSync()
                    }
                } label: {
                    Label("Sync Now (\(daysToSync) days)", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!authState.isSignedIn)
                
                // Reset sync checkpoint
                Button(role: .destructive) {
                    Task {
                        await resetSyncCheckpoint()
                    }
                } label: {
                    Label("Reset Sync Checkpoint", systemImage: "arrow.counterclockwise")
                }
                .disabled(!authState.isSignedIn)
            }
        } header: {
            Text("Quick Sync")
        } footer: {
            Text("Syncs recent messages (\(daysToSync) days) to find new obligations. Use 'Reset Sync Checkpoint' to force a complete re-download of the selected time range.")
        }
    }
    
    private func performQuickSync() async {
        guard authState.isSignedIn else { return }
        
        isSyncing = true
        syncStatus = "Syncing \(daysToSync) days of messages..."
        syncError = nil
        
        do {
            guard let account = try await resolveMailboxAccount() else {
                syncError = "No account found"
                isSyncing = false
                return
            }
            
            // Perform sync with user-selected days
            let report = try await environmentStore.value.gmailSyncCoordinator.sync(
                mailboxAccountId: account.id,
                daysBack: daysToSync,
                forceFullSync: forceFullSync
            )
            
            lastSyncDate = Date()
            authState.lastSyncDate = Date()
            
            syncStatus = "Synced \(report.messagesSavedCount) messages, found \(report.obligationsCount) obligations"
            isSyncing = false
            
            // Clear success message after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                syncStatus = nil
            }
            
        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
            isSyncing = false
            
            // Clear error after 10 seconds
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                syncError = nil
            }
        }
    }
    
    private func resetSyncCheckpoint() async {
        guard authState.isSignedIn else { return }
        
        syncStatus = "Resetting sync checkpoint..."
        
        do {
            guard let account = try await resolveMailboxAccount() else {
                syncError = "No account found"
                return
            }
            
            // Clear the sync checkpoint to force full re-download
            try await Database.shared.writeAsync { db in
                try db.execute(sql: """
                    UPDATE mailbox_account 
                    SET gmailLastHistoryId = NULL,
                        lastSyncAt = NULL,
                        lastFullSyncAt = NULL
                    WHERE id = ?
                    """, 
                    arguments: [account.id]
                )
            }
            
            syncStatus = "Checkpoint reset. Next sync will re-download all messages."
            forceFullSync = true
            
            // Clear message after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                syncStatus = nil
            }
            
        } catch {
            syncError = "Failed to reset: \(error.localizedDescription)"
            
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                syncError = nil
            }
        }
    }

    private func resolveMailboxAccount() async throws -> MailboxAccountRecord? {
        if let email = authState.userEmail, !email.isEmpty {
            return try await environmentStore.value.mailboxAccountRepository.getOrCreate(
                email: email,
                provider: .gmail
            )
        }
        if let account = try await environmentStore.value.mailboxAccountRepository.fetchFirst(provider: .gmail) {
            return account
        }
        return try await environmentStore.value.mailboxAccountRepository.fetchAll().first
    }
}

private struct YearScanSection: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var yearScanState: YearScanState
    
    var body: some View {
        Section {
            // Status
            if let lastScan = yearScanState.lastScanDate {
                LabeledContent("Last scan", value: lastScan.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Items found", value: "\(yearScanState.foundItemsCount)")
            } else {
                Text("Never scanned")
                    .foregroundStyle(.secondary)
            }
            
            // Scan button
            if yearScanState.isScanning {
                VStack(alignment: .leading, spacing: 8) {
                    if let progress = yearScanState.scanProgress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                        Text("\(Int((progress * 100).rounded(.down)))% complete")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }

                    Text(yearScanState.bannerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let totalMonths = yearScanState.totalMonths,
                       totalMonths > 0,
                       let currentMonthIndex = yearScanState.currentMonthIndex,
                       yearScanState.currentPhase == .backfill {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(0..<totalMonths, id: \.self) { index in
                                    let isCompleted = index < currentMonthIndex
                                    let isCurrent = index == currentMonthIndex
                                    Text("M\(index + 1)")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .foregroundStyle(isCurrent ? .blue : (isCompleted ? .green : .secondary))
                                        .background(
                                            Capsule()
                                                .fill(isCurrent ? Color.blue.opacity(0.14) : (isCompleted ? Color.green.opacity(0.14) : Color.secondary.opacity(0.10)))
                                        )
                                }
                            }
                        }
                    }

                    if yearScanState.liveDeltaCount > 0 {
                        Text("+\(yearScanState.liveDeltaCount) new findings")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    if !yearScanState.livePromotedPreview.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(yearScanState.livePromotedPreview.prefix(3).enumerated()), id: \.offset) { _, item in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "sparkle.magnifyingglass")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .padding(.top, 1)
                                    Text(item.subject)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                }
            } else {
                Button {
                    Task {
                        await yearScanState.startScan(using: environmentStore.value)
                    }
                } label: {
                    Label("Run Year Scan Now", systemImage: "calendar.badge.clock")
                }
            }
            
            // History
            NavigationLink {
                YearScanHistoryView()
            } label: {
                Label("Scan History", systemImage: "clock")
            }
        } header: {
            Text("Year Scan")
        } footer: {
            Text("Deep scan of your past 365 days to find missed obligations. Use this occasionally or when you first start using the app. For daily use, use Quick Sync instead.")
        }
    }
}

private struct NotificationsSection: View {
    @StateObject private var scheduler = DailyDigestScheduler.shared
    @AppStorage("notifications.dailyDigest.enabled") private var dailyDigestEnabled = false
    @AppStorage("notifications.dailyDigest.hour") private var digestHour = 9
    @AppStorage("notifications.dailyDigest.minute") private var digestMinute = 0
    @State private var showError: String?
    @State private var isScheduling = false
    
    var body: some View {
        Section {
            Toggle("Daily Digest", isOn: $dailyDigestEnabled)
                .onChange(of: dailyDigestEnabled) { _, newValue in
                    Task {
                        await handleToggleChange(enabled: newValue)
                    }
                }
            
            if dailyDigestEnabled {
                DatePicker(
                    "Time",
                    selection: Binding(
                        get: {
                            var components = DateComponents()
                            components.hour = digestHour
                            components.minute = digestMinute
                            return Calendar.current.date(from: components) ?? Date()
                        },
                        set: { newDate in
                            let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                            digestHour = components.hour ?? 9
                            digestMinute = components.minute ?? 0
                            
                            // Reschedule with new time
                            if dailyDigestEnabled {
                                Task {
                                    await scheduleNotification()
                                }
                            }
                        }
                    ),
                    displayedComponents: [.hourAndMinute]
                )
                
                if isScheduling {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating schedule...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            // Error message
            if let error = showError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Get a daily notification with obligations that need your attention")
        }
    }
    
    private func handleToggleChange(enabled: Bool) async {
        isScheduling = true
        defer { isScheduling = false }
        
        if enabled {
            await enableDigest()
        } else {
            disableDigest()
        }
    }
    
    private func enableDigest() async {
        do {
            // Request permission
            try await scheduler.requestAuthorization()
            
            // Schedule notification
            await scheduleNotification()
            
            showError = nil
        } catch {
            // Permission denied or error
            dailyDigestEnabled = false
            if case DigestError.notificationPermissionDenied = error {
                showError = "Please enable notifications in Settings"
            } else {
                showError = "Failed to schedule: \(error.localizedDescription)"
            }
            
            // Clear error after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                showError = nil
            }
        }
    }
    
    private func scheduleNotification() async {
        do {
            let time = DateComponents(hour: digestHour, minute: digestMinute)
            try await scheduler.scheduleDailyDigest(at: time)
            showError = nil
        } catch {
            showError = "Failed to schedule: \(error.localizedDescription)"
            
            // Clear error after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                showError = nil
            }
        }
    }
    
    private func disableDigest() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily-digest"])
        showError = nil
    }
}

private struct PrivacyDataSection: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var authState: AuthenticationState
    @State private var showClearCacheConfirmation = false
    @State private var showDeleteAllConfirmation = false
    @State private var isClearing = false
    @State private var statusMessage: String?
    @State private var messageCount: Int = 0
    @State private var obligationCount: Int = 0
    @State private var storageSize: String = "Calculating..."
    
    var body: some View {
        Section {
            if let privacyURL = AppPrivacyConfiguration.privacyPolicyURL {
                Link(destination: privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
            
            // Data stats - now using real data!
            LabeledContent("Messages", value: "\(messageCount)")
            LabeledContent("Obligations", value: "\(obligationCount)")
            LabeledContent("Storage", value: storageSize)
            
            // Status message
            if let status = statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if isClearing {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Clearing...")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(role: .destructive) {
                    showClearCacheConfirmation = true
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
                
                Button(role: .destructive) {
                    showDeleteAllConfirmation = true
                } label: {
                    Label("Delete All Data", systemImage: "trash.fill")
                }
            }
        } header: {
            Text("Privacy & Data")
        }
        .confirmationDialog("Clear cache?", isPresented: $showClearCacheConfirmation) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await clearCache()
                }
            }
        } message: {
            Text("Removes downloaded messages. Your obligations will be preserved.")
        }
        .confirmationDialog("Delete all data?", isPresented: $showDeleteAllConfirmation) {
            Button("Delete All Data", role: .destructive) {
                Task {
                    await deleteAllData()
                }
            }
        } message: {
            Text("This cannot be undone. All messages and obligations will be permanently deleted.")
        }
        .task {
            await loadDataStats()
        }
    }
    
    private func loadDataStats() async {
        do {
            // Get message count
            messageCount = try await Database.shared.readAsync { db in
                try MessageRecord.fetchCount(db)
            }
            
            // Get obligation count
            obligationCount = try await Database.shared.readAsync { db in
                try ObligationRecord.fetchCount(db)
            }
            
            // Calculate storage size
            storageSize = await calculateStorageSize()
        } catch {
            print("Failed to load data stats: \(error)")
            messageCount = 0
            obligationCount = 0
            storageSize = "Unknown"
        }
    }
    
    private func calculateStorageSize() async -> String {
        do {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dbURL = appSupportURL.appendingPathComponent("OnDue.sqlite")
            
            var totalSize: Int64 = 0
            
            // Main database file
            if let attrs = try? fileManager.attributesOfItem(atPath: dbURL.path),
               let fileSize = attrs[.size] as? Int64 {
                totalSize += fileSize
            }
            
            // WAL file
            let walURL = appSupportURL.appendingPathComponent("OnDue.sqlite-wal")
            if let attrs = try? fileManager.attributesOfItem(atPath: walURL.path),
               let fileSize = attrs[.size] as? Int64 {
                totalSize += fileSize
            }
            
            // SHM file
            let shmURL = appSupportURL.appendingPathComponent("OnDue.sqlite-shm")
            if let attrs = try? fileManager.attributesOfItem(atPath: shmURL.path),
               let fileSize = attrs[.size] as? Int64 {
                totalSize += fileSize
            }
            
            return formatBytes(totalSize)
        } catch {
            return "Unknown"
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
    
    private func clearCache() async {
        guard authState.userEmail != nil else {
            statusMessage = "No account connected"
            return
        }
        
        isClearing = true
        statusMessage = "Clearing cache..."
        
        do {
            guard let account = try await resolveMailboxAccount() else {
                statusMessage = "No account found"
                isClearing = false
                return
            }
            
            let deleted = try await environmentStore.value.gmailSyncCoordinator.resetLocalCache(
                mailboxAccountId: account.id
            )
            
            statusMessage = "Cleared \(deleted) messages"
            
            // Refresh stats after clearing
            await loadDataStats()
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
        
        isClearing = false
        
        // Clear status after 3 seconds
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            statusMessage = nil
        }
    }
    
    private func deleteAllData() async {
        guard authState.userEmail != nil else {
            statusMessage = "No account connected"
            return
        }
        
        isClearing = true
        statusMessage = "Deleting all data..."
        
        do {
            guard let account = try await resolveMailboxAccount() else {
                statusMessage = "No account found"
                isClearing = false
                return
            }
            
            try await environmentStore.value.gmailSyncCoordinator.deleteAllAccountData(
                mailboxAccountId: account.id
            )
            
            // Refresh stats after deleting (should be 0)
            await loadDataStats()
            
            // Sign out after deletion
            await authState.signOut()
            
            statusMessage = "All data deleted"
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
        
        isClearing = false
    }

    private func resolveMailboxAccount() async throws -> MailboxAccountRecord? {
        if let email = authState.userEmail, !email.isEmpty {
            return try await environmentStore.value.mailboxAccountRepository.getOrCreate(
                email: email,
                provider: .gmail
            )
        }
        if let account = try await environmentStore.value.mailboxAccountRepository.fetchFirst(provider: .gmail) {
            return account
        }
        return try await environmentStore.value.mailboxAccountRepository.fetchAll().first
    }
}

private struct AboutSection: View {
    var body: some View {
        Section {
            LabeledContent("Version", value: "1.0.0")
            
            Link(destination: URL(string: "https://github.com/yourusername/ondue")!) {
                Label("View on GitHub", systemImage: "link")
            }
            
            Button {
                // Send feedback
            } label: {
                Label("Send Feedback", systemImage: "envelope")
            }
        } header: {
            Text("About")
        }
    }
}

#if DEBUG
private struct DebugSection: View {
    var body: some View {
        Section {
            NavigationLink {
                MessageStateDebugView()
            } label: {
                Label("Local State Debug", systemImage: "ladybug")
            }
            
            NavigationLink {
                GoldDatasetLabelView()
            } label: {
                Label("Label Dataset", systemImage: "square.and.pencil")
            }
            
            Button {
                // Export gold dataset
            } label: {
                Label("Export Gold Dataset", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Developer")
        }
    }
}
#endif

// MARK: - Supporting Views

private struct YearScanHistoryView: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @State private var snapshot: YearScanSnapshot?
    @State private var isLoading = true
    @State private var selectedItem: YearScanItem?
    @State private var showExpectedPatterns = false
    @State private var showDroppedDiagnostics = false
    @State private var lightweightPollTick: Int = 0
    
    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading scan history...")
            } else if let snapshot = snapshot {
                scanHistoryContent(snapshot)
            } else {
                noHistoryView
            }
        }
        .navigationTitle("Scan History")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadHistory()
        }
        .task(id: snapshot?.isInProgress == true) {
            guard snapshot?.isInProgress == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                lightweightPollTick += 1
                let includeResults = lightweightPollTick % 4 == 0
                await loadHistory(showLoading: false, includeResults: includeResults)
                if snapshot?.isInProgress != true {
                    break
                }
            }
        }
        .sheet(item: $selectedItem) { item in
            NavigationStack {
                YearScanItemDetailView(item: item)
            }
        }
    }
    
    private func scanHistoryContent(_ snapshot: YearScanSnapshot) -> some View {
        List {
            // Summary Section
            Section {
                if let lastChecked = snapshot.lastChecked {
                    LabeledContent("Last Scan", value: lastChecked.formatted(date: .abbreviated, time: .shortened))
                } else if snapshot.isInProgress {
                    LabeledContent("Status", value: "In Progress")
                } else {
                    Text("Never completed")
                        .foregroundStyle(.secondary)
                }
                
                LabeledContent("Messages Scanned", value: "\(snapshot.scannedMessageCount)")
                LabeledContent("Items Found", value: "\(snapshot.items.count)")
                LabeledContent("Expected Patterns", value: "\(snapshot.expectedEventSignals.count)")
                LabeledContent("Coverage", value: snapshot.coverageSummary)
                
                if snapshot.isInProgress {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(snapshot.statusMessage ?? "Scanning...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                if let lastPaused = snapshot.lastPaused {
                    LabeledContent("Paused At", value: lastPaused.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Text("Last Scan Summary")
            }

            if !snapshot.expectedEventSignals.isEmpty {
                Section {
                    DisclosureGroup(
                        "Expected Patterns (\(snapshot.expectedEventSignals.count))",
                        isExpanded: $showExpectedPatterns
                    ) {
                        ForEach(Array(snapshot.expectedEventSignals.prefix(6).enumerated()), id: \.offset) { _, signal in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(signal.subject)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                if !signal.snippet.isEmpty {
                                    Text(signal.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }

                                HStack(spacing: 8) {
                                    Text("Confidence \(Int((signal.confidence * 100).rounded()))%")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                    if let dueDate = signal.dueDate {
                                        Text("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()
                                }
                            }
                            .padding(.vertical, 2)
                        }

                        if snapshot.expectedEventSignals.count > 6 {
                            Text("+\(snapshot.expectedEventSignals.count - 6) more patterns")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Recurring or pattern-like signals captured during scan for future expected-event logic.")
                }
            }

            if !snapshot.droppedReasonCounts.isEmpty {
                Section {
                    DisclosureGroup("Dropped During Scan", isExpanded: $showDroppedDiagnostics) {
                        ForEach(droppedReasonRows(from: snapshot.droppedReasonCounts), id: \.reason) { row in
                            LabeledContent(row.label, value: "\(row.count)")
                        }
                    }
                } footer: {
                    Text("Findings excluded from promotion with explicit deterministic reason codes.")
                }
            }
            
            // Items Found Section
            if !snapshot.items.isEmpty {
                Section {
                    ForEach(snapshot.items) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.subject)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                
                                if !item.snippet.isEmpty {
                                    Text(item.snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                
                                HStack {
                                    if !item.matchedReasons.isEmpty {
                                        Text(item.matchedReasons.prefix(2).joined(separator: " • "))
                                            .font(.caption2)
                                            .foregroundStyle(.blue)
                                    }
                                    
                                    Spacer()
                                    
                                    Text(item.detectedAt.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("Items Found (\(snapshot.items.count))")
                } footer: {
                    Text("These items were flagged during the scan as potentially needing attention")
                }
            } else if snapshot.lastChecked != nil {
                Section {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("No items found in last scan")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("The scan completed successfully but didn't find any items that need attention")
                }
            }
            
            // Resume State Section (if paused)
            if let resumeState = snapshot.resumeState {
                Section {
                    LabeledContent("Phase", value: resumeState.phase.rawValue.capitalized)
                    LabeledContent("Progress", value: "\(resumeState.monthIndex + 1) of \(resumeState.totalMonths) months")
                    
                    if let lastStatus = resumeState.lastStatusMessage {
                        LabeledContent("Status", value: lastStatus)
                    }
                } header: {
                    Text("Resume Info")
                } footer: {
                    Text("This scan was paused and can be resumed from the Year Scan section")
                }
            }
        }
    }
    
    private var noHistoryView: some View {
        ContentUnavailableView {
            Label("No Scan History", systemImage: "calendar.badge.clock")
        } description: {
            Text("Run your first year scan from the settings to see history here")
        }
    }
    
    private func loadHistory(showLoading: Bool = true, includeResults: Bool = true) async {
        if showLoading {
            isLoading = true
        }
        do {
            if includeResults || snapshot == nil {
                snapshot = try await environmentStore.value.yearScanRepository.fetchLatest()
            } else if let state = try await environmentStore.value.yearScanRepository.fetchLatestState(),
                      let current = snapshot {
                snapshot = mergedSnapshot(current: current, state: state)
            } else {
                snapshot = try await environmentStore.value.yearScanRepository.fetchLatest()
            }
        } catch {
            print("Failed to load scan history: \(error)")
            snapshot = nil
        }
        if showLoading {
            isLoading = false
        }
    }

    private func mergedSnapshot(current: YearScanSnapshot, state: YearScanStateSnapshot) -> YearScanSnapshot {
        YearScanSnapshot(
            items: current.items,
            expectedEventSignals: current.expectedEventSignals,
            droppedReasonCounts: current.droppedReasonCounts,
            lastChecked: state.lastChecked,
            lastPaused: state.lastPaused,
            scannedMessageCount: state.scannedMessageCount,
            coverageSummary: state.coverageSummary,
            isInProgress: state.isInProgress,
            statusMessage: state.statusMessage,
            updatedAt: state.updatedAt,
            resumeState: state.resumeState,
            scanRangeMonths: state.scanRangeMonths,
            scanIntensity: state.scanIntensity
        )
    }

    private func droppedReasonRows(
        from counts: [LongScanPromotionReasonCode: Int]
    ) -> [(reason: LongScanPromotionReasonCode, label: String, count: Int)] {
        let order: [LongScanPromotionReasonCode] = [
            .suppressed,
            .lowConfidence,
            .missingDueDate,
            .convertedExpectedEvent,
            .promotedActionable
        ]
        return order.compactMap { code in
            guard let count = counts[code], count > 0 else { return nil }
            return (code, droppedReasonLabel(for: code), count)
        }
    }

    private func droppedReasonLabel(for code: LongScanPromotionReasonCode) -> String {
        switch code {
        case .suppressed:
            return "Suppressed"
        case .lowConfidence:
            return "Low confidence"
        case .missingDueDate:
            return "Missing due date"
        case .convertedExpectedEvent:
            return "Converted to expected event"
        case .promotedActionable:
            return "Promoted actionable"
        }
    }
}

private struct YearScanItemDetailView: View {
    let item: YearScanItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.subject)
                        .font(.title3.weight(.semibold))
                    
                    if !item.snippet.isEmpty {
                        Text(item.snippet)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Message Details")
            }
            
            Section {
                LabeledContent("Score", value: String(format: "%.2f", item.score))
                LabeledContent("Detected", value: item.detectedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Message ID", value: item.providerMessageId)
                    .font(.caption)
                    .textSelection(.enabled)
            } header: {
                Text("Metadata")
            }
            
            if !item.matchedReasons.isEmpty {
                Section {
                    ForEach(Array(item.matchedReasons.enumerated()), id: \.offset) { _, reason in
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                            Text(reason)
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("Matched Reasons")
                } footer: {
                    Text("These patterns triggered this item to be flagged")
                }
            }
            
            Section {
                Button {
                    openGmail()
                } label: {
                    Label("Open in Gmail", systemImage: "envelope.open")
                }
            } header: {
                Text("Actions")
            }
        }
        .navigationTitle("Scan Item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
    
    private func openGmail() {
        let target = (item.threadId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? item.threadId!
            : item.providerMessageId
        let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
        let urlString = "https://mail.google.com/mail/u/0/#all/\(encodedTarget)"
        if let url = URL(string: urlString) {
            openURL(url)
        }
    }
}

