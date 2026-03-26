import SwiftUI
import Foundation
import GRDB
import UserNotifications
import Combine

// MARK: - Settings Sections

struct AccountSection: View {
    @EnvironmentObject private var authState: AuthenticationState
    @State private var showSignOutConfirmation = false
    
    var body: some View {
        Section {
            if authState.isSignedIn, let email = authState.userEmail {
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

struct QuickSyncSection: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var authState: AuthenticationState
    @EnvironmentObject private var yearScanState: YearScanState
    @StateObject private var viewModel = QuickSyncSectionViewModel()
    @State private var showResetCheckpointConfirmation = false

    var body: some View {
        Section {
            if let lastSync = viewModel.lastSyncDate {
                LabeledContent("Last synced", value: lastSync.formatted(date: .abbreviated, time: .shortened))
            } else {
                Text("Never synced")
                    .foregroundStyle(.secondary)
            }

            if let status = viewModel.syncStatus {
                HStack {
                    if viewModel.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(viewModel.isSyncing ? .secondary : Color.green)
                }
            }

            if let error = viewModel.syncError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if viewModel.isSyncing {
                HStack {
                    ProgressView()
                    Text("Refreshing...")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    Task {
                        await viewModel.performQuickSync(
                            environment: environmentStore.value,
                            authState: authState
                        )
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!authState.isSignedIn || yearScanState.isScanning)

                Button(role: .destructive) {
                    showResetCheckpointConfirmation = true
                } label: {
                    Label("Reset Sync Checkpoint", systemImage: "arrow.counterclockwise")
                }
                .disabled(!authState.isSignedIn || yearScanState.isScanning)
            }
        } header: {
            Text("Quick Sync")
        } footer: {
            Text("Checks recent emails for new obligations. Pull down on the main screen to refresh at any time.")
        }
        .confirmationDialog("Reset sync checkpoint?", isPresented: $showResetCheckpointConfirmation) {
            Button("Reset Checkpoint", role: .destructive) {
                Task {
                    await viewModel.resetSyncCheckpoint(
                        environment: environmentStore.value,
                        authState: authState
                    )
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Next refresh will re-download recent message history.")
        }
    }
}

@MainActor
private final class QuickSyncSectionViewModel: ObservableObject {
    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var syncStatus: String?
    @Published var syncError: String?

    func performQuickSync(environment: AppEnvironment, authState: AuthenticationState) async {
        guard authState.isSignedIn else { return }
        isSyncing = true
        syncStatus = "Checking for new obligations..."
        syncError = nil

        do {
            guard let account = try await resolveMailboxAccount(environment: environment, authState: authState) else {
                syncError = "No account found"
                isSyncing = false
                return
            }

            let report = try await environment.gmailSyncCoordinator.sync(
                mailboxAccountId: account.id,
                daysBack: 30,
                forceFullSync: false
            )

            let now = Date()
            lastSyncDate = now
            authState.lastSyncDate = now
            let count = report.obligationsCount
            syncStatus = count > 0
                ? "Found \(count) new obligation\(count == 1 ? "" : "s")"
                : "Up to date"
            isSyncing = false

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.syncStatus = nil
            }
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "RootView.quickSync.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                isSyncing = false
                return
            }
            AppLog.error(
                "RootView.quickSync.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            syncError = AppUserErrorMapper.message(for: error, fallback: "Sync failed. Please try again.")
            isSyncing = false

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self.syncError = nil
            }
        }
    }

    func resetSyncCheckpoint(environment: AppEnvironment, authState: AuthenticationState) async {
        guard authState.isSignedIn else { return }
        syncStatus = "Resetting sync checkpoint..."

        do {
            guard let account = try await resolveMailboxAccount(environment: environment, authState: authState) else {
                syncError = "No account found"
                return
            }

            try await environment.database.writeAsync { db in
                try db.execute(
                    sql: """
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

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.syncStatus = nil
            }
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "RootView.resetSyncCheckpoint.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                return
            }
            AppLog.error(
                "RootView.resetSyncCheckpoint.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            syncError = AppUserErrorMapper.message(
                for: error,
                fallback: "Failed to reset sync checkpoint. Please try again."
            )

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                self.syncError = nil
            }
        }
    }

    private func resolveMailboxAccount(
        environment: AppEnvironment,
        authState: AuthenticationState
    ) async throws -> MailboxAccountRecord? {
        if let email = authState.userEmail, !email.isEmpty {
            return try await environment.mailboxAccountRepository.getOrCreate(
                email: email,
                provider: .gmail
            )
        }
        if let account = try await environment.mailboxAccountRepository.fetchFirst(provider: .gmail) {
            return account
        }
        return try await environment.mailboxAccountRepository.fetchAll().first
    }
}

struct InboxHistorySection: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var yearScanState: YearScanState
    @State private var showCancelConfirmation = false
    @State private var showStartNewConfirmation = false

    private var policy: SyncPolicyStore { environmentStore.value.syncPolicyStore }

    private var scanDepthBinding: Binding<Int> {
        Binding(
            get: { [3, 12, 24].contains(policy.coverageScanMonths) ? policy.coverageScanMonths : 12 },
            set: { newValue in
                if newValue == 24 { policy.longScanAndBackgroundOptIn = true }
                policy.coverageScanMonths = newValue
            }
        )
    }

    var body: some View {
        Section {
            if !yearScanState.isScanning {
                Picker("Scan depth", selection: scanDepthBinding) {
                    Text("Last 3 months").tag(3)
                    Text("Last year").tag(12)
                    Text("Last 2 years").tag(24)
                }
                .disabled(yearScanState.canResume)
                if yearScanState.canResume {
                    Text("Scan depth is locked while a paused scan is resumable. Use Start New Scan to change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !yearScanState.isScanning {
                if let lastScan = yearScanState.lastScanDate {
                    LabeledContent("Last scan", value: lastScan.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Items found", value: "\(yearScanState.foundItemsCount)")
                } else {
                    Text("Never scanned")
                        .foregroundStyle(.secondary)
                }
            }

            if yearScanState.isScanning {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Progress")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if let progress = yearScanState.scanProgress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                            Text("\(Int((progress * 100).rounded(.down)))% complete")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if yearScanState.isFinalizing {
                                Text("Finalizing results and promoting to Now/Later...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            ProgressView()
                        }

                        Text(yearScanState.bannerSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let resumePoint = yearScanState.resumePointText {
                            Text(resumePoint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if yearScanState.currentPhase == .backfill {
                            Text("Promoted/Expected/Dropped counts populate during the final review pass.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        if let totalMonths = yearScanState.totalMonths,
                           totalMonths > 0,
                           let currentMonthIndex = yearScanState.currentMonthIndex,
                           yearScanState.currentPhase == .backfill {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(0..<totalMonths, id: \.self) { index in
                                        let isCompleted = index < currentMonthIndex
                                        let isCurrent = index == currentMonthIndex
                                        let label = pillLabel(
                                            index: index,
                                            totalMonths: totalMonths,
                                            summaries: yearScanState.monthSummaries
                                        )
                                        Text(label)
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
                            Text("Live findings")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
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

                        if !yearScanState.monthSummaries.isEmpty {
                            Text("Month breakdown")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(displayedMonthSummaries(yearScanState.monthSummaries)) { summary in
                                    HStack {
                                        Text(summary.monthLabel)
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(summaryLine(summary))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text("Promoted • Expected • Dropped")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if hiddenMonthSummariesCount(yearScanState.monthSummaries) > 0 {
                                    Text("+\(hiddenMonthSummariesCount(yearScanState.monthSummaries)) more months in Scan History")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Divider()
                            .padding(.vertical, 2)

                        Text("Actions")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Button {
                                Task {
                                    await yearScanState.pauseScan(using: environmentStore.value)
                                }
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .disabled(!yearScanState.canPause)

                            Button(role: .destructive) {
                                showCancelConfirmation = true
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle")
                            }
                            .disabled(!yearScanState.canCancel)
                        }
                    }
                } label: {
                    Label("In progress", systemImage: "waveform.path.ecg")
                        .font(.subheadline.weight(.semibold))
                }
            } else if yearScanState.canResume {
                Button {
                    Task {
                        await yearScanState.resumeScan(using: environmentStore.value)
                    }
                } label: {
                    Label("Resume deep scan", systemImage: "play.fill")
                }

                Menu {
                    Button(role: .destructive) {
                        showStartNewConfirmation = true
                    } label: {
                        Label("Start New Scan", systemImage: "arrow.clockwise.circle")
                    }

                    Button(role: .destructive) {
                        showCancelConfirmation = true
                    } label: {
                        Label("Discard Paused Checkpoint", systemImage: "trash")
                    }
                } label: {
                    Label("More Actions", systemImage: "ellipsis.circle")
                }
            } else {
                Button {
                    Task { await yearScanState.startScan(using: environmentStore.value) }
                } label: {
                    Label("Start deep scan", systemImage: "magnifyingglass.circle")
                }
            }

            NavigationLink {
                YearScanHistoryView()
            } label: {
                Label("Scan History", systemImage: "clock")
            }
        } header: {
            Text("Deep Scan")
        } footer: {
            Text("Scans your email history to find obligations you may have missed. Progress is saved — you can pause and resume at any time.")
        }
        .confirmationDialog(cancelDialogTitle, isPresented: $showCancelConfirmation) {
            Button(cancelDialogConfirmLabel, role: .destructive) {
                Task {
                    await yearScanState.cancelScan(using: environmentStore.value)
                }
            }
            Button(cancelDialogCancelLabel, role: .cancel) {}
        } message: {
            Text(cancelDialogMessage)
        }
        .confirmationDialog("Start a new scan?", isPresented: $showStartNewConfirmation) {
            Button("Start New Scan", role: .destructive) {
                Task {
                    await yearScanState.startScan(using: environmentStore.value)
                }
            }
            Button("Resume Existing", role: .cancel) {}
        } message: {
            Text("Your paused checkpoint will be replaced by a fresh run.")
        }
    }

    // MARK: - Helpers

    /// Returns an adaptive label for a month progress pill.
    /// ≤ 6 months: abbreviated month name from summaries if available ("Jan", "Feb")
    /// 7–15 months: short index label ("M1", "M2")
    /// > 15 months: quarter label ("Q1", "Q2")
    private func pillLabel(index: Int, totalMonths: Int, summaries: [YearScanMonthSummary]) -> String {
        if totalMonths <= 6 {
            if let summary = summaries.first(where: { $0.monthIndex == index }) {
                return String(summary.monthLabel.prefix(3))
            }
        }
        if totalMonths > 15 {
            return "Q\((index / 3) + 1)"
        }
        return "M\(index + 1)"
    }

    private func displayedMonthSummaries(_ summaries: [YearScanMonthSummary]) -> [YearScanMonthSummary] {
        let inProgress = summaries.filter(\.isInProgress).sorted { $0.monthIndex > $1.monthIndex }
        let completed = summaries.filter { !$0.isInProgress }.sorted { $0.monthIndex > $1.monthIndex }
        return Array((inProgress + completed).prefix(3))
    }

    private func hiddenMonthSummariesCount(_ summaries: [YearScanMonthSummary]) -> Int {
        max(0, summaries.count - displayedMonthSummaries(summaries).count)
    }

    private var cancelDialogTitle: String {
        yearScanState.isScanning ? "Cancel deep scan?" : "Discard paused checkpoint?"
    }

    private var cancelDialogConfirmLabel: String {
        yearScanState.isScanning ? "Cancel Scan" : "Discard Checkpoint"
    }

    private var cancelDialogCancelLabel: String {
        yearScanState.isScanning ? "Keep Running" : "Keep Paused State"
    }

    private var cancelDialogMessage: String {
        yearScanState.isScanning
            ? "This stops the current run and clears resumable checkpoint state."
            : "This removes the paused checkpoint so the next run starts fresh."
    }

    private func summaryLine(_ summary: YearScanMonthSummary) -> String {
        let counts = "Promoted \(summary.promotedCount) • Expected \(summary.expectedCount) • Dropped \(summary.droppedCount)"
        if summary.messagesScanned > 0 {
            return "\(summary.messagesScanned) msgs • \(counts)"
        }
        return counts
    }
}

struct NotificationsSection: View {
    @StateObject private var viewModel = NotificationsSectionViewModel()
    @AppStorage("notifications.dailyDigest.enabled") private var dailyDigestEnabled = false
    @AppStorage("notifications.dailyDigest.hour") private var digestHour = 9
    @AppStorage("notifications.dailyDigest.minute") private var digestMinute = 0
    
    var body: some View {
        Section {
            Toggle("Daily Digest", isOn: $dailyDigestEnabled)
                .onChange(of: dailyDigestEnabled) { _, newValue in
                    Task {
                        await viewModel.handleToggleChange(
                            enabled: newValue,
                            digestHour: digestHour,
                            digestMinute: digestMinute,
                            onDisable: {
                                dailyDigestEnabled = false
                            }
                        )
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
                            if dailyDigestEnabled {
                                Task {
                                    await viewModel.scheduleNotification(
                                        digestHour: digestHour,
                                        digestMinute: digestMinute
                                    )
                                }
                            }
                        }
                    ),
                    displayedComponents: [.hourAndMinute]
                )
                
                if viewModel.isScheduling {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating schedule...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            if let error = viewModel.showError {
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
}

@MainActor
private final class NotificationsSectionViewModel: ObservableObject {
    @Published var showError: String?
    @Published var isScheduling = false
    private let scheduler = DailyDigestScheduler.shared

    func handleToggleChange(
        enabled: Bool,
        digestHour: Int,
        digestMinute: Int,
        onDisable: @escaping @MainActor () -> Void
    ) async {
        isScheduling = true
        defer { isScheduling = false }
        if enabled {
            await enableDigest(
                digestHour: digestHour,
                digestMinute: digestMinute,
                onDisable: onDisable
            )
        } else {
            disableDigest()
        }
    }

    func scheduleNotification(digestHour: Int, digestMinute: Int) async {
        do {
            let time = DateComponents(hour: digestHour, minute: digestMinute)
            try await scheduler.scheduleDailyDigest(at: time)
            showError = nil
        } catch {
            showError = "Failed to schedule: \(error.localizedDescription)"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.showError = nil
            }
        }
    }

    private func enableDigest(
        digestHour: Int,
        digestMinute: Int,
        onDisable: @escaping @MainActor () -> Void
    ) async {
        do {
            try await scheduler.requestAuthorization()
            await scheduleNotification(digestHour: digestHour, digestMinute: digestMinute)
            showError = nil
        } catch {
            onDisable()
            if case DigestError.notificationPermissionDenied = error {
                showError = "Please enable notifications in Settings"
            } else {
                showError = "Failed to schedule: \(error.localizedDescription)"
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.showError = nil
            }
        }
    }

    private func disableDigest() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily-digest"])
        showError = nil
    }
}

struct PrivacyDataSection: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @EnvironmentObject private var authState: AuthenticationState
    @StateObject private var viewModel = PrivacyDataSectionViewModel()
    
    var body: some View {
        Section {
            if let privacyURL = AppPrivacyConfiguration.privacyPolicyURL {
                Link(destination: privacyURL) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
            }
            
            LabeledContent("Messages", value: "\(viewModel.messageCount)")
            LabeledContent("Obligations", value: "\(viewModel.obligationCount)")
            LabeledContent("Storage", value: viewModel.storageSize)
            
            if let status = viewModel.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if viewModel.isClearing {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Clearing...")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button(role: .destructive) {
                    viewModel.showClearCacheConfirmation = true
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }
                
                Button(role: .destructive) {
                    viewModel.showDeleteAllConfirmation = true
                } label: {
                    Label("Delete All Data", systemImage: "trash.fill")
                }
            }
        } header: {
            Text("Privacy & Data")
        }
        .confirmationDialog("Clear cache?", isPresented: $viewModel.showClearCacheConfirmation) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    await viewModel.clearCache(environment: environmentStore.value)
                }
            }
        } message: {
            Text("Removes downloaded messages. Your obligations will be preserved.")
        }
        .confirmationDialog("Delete all data?", isPresented: $viewModel.showDeleteAllConfirmation) {
            Button("Delete All Data", role: .destructive) {
                Task {
                    await viewModel.deleteAllData(
                        environment: environmentStore.value,
                        authState: authState
                    )
                }
            }
        } message: {
            Text("This cannot be undone. All messages and obligations will be permanently deleted.")
        }
        .task {
            await viewModel.loadDataStats()
        }
    }
}

@MainActor
private final class PrivacyDataSectionViewModel: ObservableObject {
    @Published var showClearCacheConfirmation = false
    @Published var showDeleteAllConfirmation = false
    @Published var isClearing = false
    @Published var statusMessage: String?
    @Published var messageCount: Int = 0
    @Published var obligationCount: Int = 0
    @Published var storageSize: String = "Calculating..."

    func loadDataStats() async {
        do {
            messageCount = try await Database.shared.readAsync { db in
                try MessageRecord.fetchCount(db)
            }
            obligationCount = try await Database.shared.readAsync { db in
                try ObligationRecord.fetchCount(db)
            }
            storageSize = await calculateStorageSize()
        } catch {
            messageCount = 0
            obligationCount = 0
            storageSize = "Unknown"
        }
    }

    func clearCache(environment: AppEnvironment) async {
        isClearing = true
        statusMessage = "Clearing cache..."
        do {
            let accounts = try await environment.mailboxAccountRepository.fetchAll()
            guard !accounts.isEmpty else {
                statusMessage = "No local mailbox account found."
                isClearing = false
                return
            }
            var deleted = 0
            for account in accounts {
                deleted += try await environment.gmailSyncCoordinator.resetLocalCache(
                    mailboxAccountId: account.id
                )
            }
            statusMessage = deleted > 0 ? "Cleared \(deleted) messages" : "No cached messages to clear"
            await loadDataStats()
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "Settings.clearCache.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = nil
                isClearing = false
                return
            }
            AppLog.error(
                "Settings.clearCache.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            statusMessage = AppUserErrorMapper.message(for: error, fallback: "Unable to clear cache. Please try again.")
        }
        isClearing = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.statusMessage = nil
        }
    }

    func deleteAllData(environment: AppEnvironment, authState: AuthenticationState) async {
        isClearing = true
        statusMessage = "Deleting all data..."
        do {
            let accounts = try await environment.mailboxAccountRepository.fetchAll()
            guard !accounts.isEmpty else {
                statusMessage = "No local mailbox account found."
                isClearing = false
                return
            }
            for account in accounts {
                try await environment.gmailSyncCoordinator.deleteAllAccountData(
                    mailboxAccountId: account.id
                )
            }
            await loadDataStats()
            await authState.signOut()
            statusMessage = "All data deleted"
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "Settings.deleteAllData.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = nil
                isClearing = false
                return
            }
            AppLog.error(
                "Settings.deleteAllData.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            statusMessage = AppUserErrorMapper.message(for: error, fallback: "Unable to delete local data. Please try again.")
        }
        isClearing = false
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
            if let attrs = try? fileManager.attributesOfItem(atPath: dbURL.path),
               let fileSize = attrs[.size] as? Int64 {
                totalSize += fileSize
            }
            let walURL = appSupportURL.appendingPathComponent("OnDue.sqlite-wal")
            if let attrs = try? fileManager.attributesOfItem(atPath: walURL.path),
               let fileSize = attrs[.size] as? Int64 {
                totalSize += fileSize
            }
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
}

struct AboutSection: View {
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
struct DebugSection: View {
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
