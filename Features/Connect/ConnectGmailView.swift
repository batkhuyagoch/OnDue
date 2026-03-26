import SwiftUI

struct ConnectGmailView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = ConnectGmailViewModel()
    @State private var showingPolicy = false
    @State private var showMoreOptions = false
    @State private var showResetConfirmation = false
    @State private var showDeleteAllConfirmation = false
    @State private var showDisconnectConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if viewModel.isConnected {
                    connectedView
                } else {
                    disconnectedView
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Connect Gmail")
            .sheet(isPresented: $showingPolicy) {
                SyncPolicyView()
                    .environmentObject(environment)
            }
            .onAppear {
                Task {
                    await viewModel.checkConnection(using: environment.value)
                }
            }
            .confirmationDialog("Reset local cache?", isPresented: $showResetConfirmation, titleVisibility: .visible) {
                Button("Reset local cache", role: .destructive) {
                    Task {
                        await viewModel.resetLocalData(using: environment.value)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes downloaded local messages and obligations on this device. Your Gmail account is not deleted.")
            }
            .confirmationDialog("Disconnect Gmail?", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    viewModel.disconnect(using: environment.value)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signs out and cancels any scheduled background sync. You'll need to reconnect before syncing again.")
            }
            .confirmationDialog("Delete all account data?", isPresented: $showDeleteAllConfirmation, titleVisibility: .visible) {
                Button("Delete all data", role: .destructive) {
                    Task {
                        await viewModel.deleteAllAccountData(using: environment.value)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Permanently removes all synced messages, obligations, feedback, and settings from this device. You will be signed out. This cannot be undone.")
            }
        }
    }
    
    // MARK: - Disconnected State
    
    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Connect Gmail to get started")
                .font(.title2.bold())
            
            Text("Read-only access to your inbox.\nAll processing happens on-device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            DisclosureGroup("What we read and store") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("• Reads: subject, sender, date, body text of inbox emails")
                    Text("• Stored: locally on this device only; nothing sent to our servers")
                    Text("• Retention: older messages beyond your sync range are pruned")
                    Text("• Deletion: Reset cache or Delete all data (when connected)")
                    if let privacyPolicyURL = AppPrivacyConfiguration.privacyPolicyURL {
                        Link("Privacy Policy", destination: privacyPolicyURL)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            
            Button {
                Task {
                    await viewModel.connect(using: environment.value)
                }
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text("Connect Gmail")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            if let status = viewModel.statusMessage {
                Text(statusMessage(status))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
    
    // MARK: - Connected State
    
    private var connectedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("Connected")
                .font(.title2.bold())
            
            if let email = viewModel.userEmail {
                Text(email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            if let lastSync = viewModel.lastSyncDate {
                Text("Last synced: \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            
            if let status = viewModel.statusMessage {
                Text(statusMessage(status))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            if let report = viewModel.lastSyncReport {
                VStack(spacing: 4) {
                    Text("Last sync stats")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("Searched: \(report.messageIDsCount) • Saved: \(report.messagesSavedCount) • Obligations: \(report.obligationsCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if report.deletedOldMessagesCount > 0 {
                        Text("Deleted old local messages: \(report.deletedOldMessagesCount)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .multilineTextAlignment(.center)
            }
            
            VStack(spacing: 12) {
                Button {
                    Task {
                        await viewModel.resync(using: environment.value)
                    }
                } label: {
                    HStack {
                        if viewModel.isSyncing {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Sync now")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSyncing || viewModel.isBackfilling)

                DisclosureGroup("More options", isExpanded: $showMoreOptions) {
                    VStack(spacing: 12) {
                        Button {
                            showingPolicy = true
                        } label: {
                            HStack {
                                Image(systemName: "slider.horizontal.3")
                                Text("Sync policy")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Toggle("Force full sync", isOn: $viewModel.forceFullSync)
                            .font(.footnote)

                        Button(role: .destructive) {
                            showResetConfirmation = true
                        } label: {
                            HStack {
                                if viewModel.isResetting {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "trash")
                                }
                                Text("Reset local cache")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isSyncing || viewModel.isBackfilling || viewModel.isResetting)

                        Button(role: .destructive) {
                            showDeleteAllConfirmation = true
                        } label: {
                            HStack {
                                if viewModel.isResetting {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "trash.circle")
                                }
                                Text("Delete all account data")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isSyncing || viewModel.isBackfilling || viewModel.isResetting)

                        if viewModel.backfillResumableState != nil {
                            Button {
                                Task {
                                    await viewModel.resumeBackfill(using: environment.value)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.circle")
                                    Text("Resume history search")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isSyncing || viewModel.isBackfilling)
                        }

                        Button(role: .destructive) {
                            showDisconnectConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "xmark.circle")
                                Text("Disconnect")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.top, 8)
                }
            }
            .controlSize(.large)
        }
    }

    private func statusMessage(_ rawStatus: String) -> String {
        guard !rawStatus.isEmpty else { return "Ready." }
        return "\(rawStatus) If this seems out of date, tap Sync now."
    }
}

struct SyncPolicyView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @Environment(\.dismiss) private var dismiss
    
    private var policy: SyncPolicyStore {
        environment.value.syncPolicyStore
    }
    
    private var defaultRangeBinding: Binding<SyncRange> {
        Binding(
            get: { policy.defaultSyncRange },
            set: { policy.defaultSyncRange = $0 }
        )
    }
    
    private var backgroundEnabledBinding: Binding<Bool> {
        Binding(
            get: { policy.backgroundSyncEnabled },
            set: { policy.backgroundSyncEnabled = $0 }
        )
    }
    
    private var backgroundIntervalBinding: Binding<Int> {
        Binding(
            get: { policy.backgroundIntervalHours },
            set: { policy.backgroundIntervalHours = $0 }
        )
    }
    
    private var maxMessagesBinding: Binding<Int> {
        Binding(
            get: { policy.maxMessagesPerSlice },
            set: { policy.maxMessagesPerSlice = $0 }
        )
    }

    private var longScanOptInBinding: Binding<Bool> {
        Binding(
            get: { policy.longScanAndBackgroundOptIn },
            set: { policy.longScanAndBackgroundOptIn = $0 }
        )
    }

    private var coverageScanMonthsBinding: Binding<Int> {
        Binding(
            get: { policy.coverageScanMonths },
            set: {
                policy.coverageScanMonths = SyncPolicyStore.clampCoverageMonths(
                    $0,
                    max: policy.effectiveMaximumCoverageMonths
                )
            }
        )
    }

    private var coverageScanIntensityBinding: Binding<CoverageScanIntensity> {
        Binding(
            get: { policy.coverageScanIntensity },
            set: { policy.coverageScanIntensity = $0 }
        )
    }

    private var coverageRequireChargingBinding: Binding<Bool> {
        Binding(
            get: { policy.coverageBackgroundRequiresCharging },
            set: { policy.coverageBackgroundRequiresCharging = $0 }
        )
    }

    private var coveragePreferWiFiBinding: Binding<Bool> {
        Binding(
            get: { policy.coveragePreferWiFi },
            set: { policy.coveragePreferWiFi = $0 }
        )
    }

    private var coverage36MonthExperimentalBinding: Binding<Bool> {
        Binding(
            get: { policy.coverage36MonthExperimentalEnabled },
            set: { policy.coverage36MonthExperimentalEnabled = $0 }
        )
    }

    private var extendedScanKillSwitchBinding: Binding<Bool> {
        Binding(
            get: { policy.extendedScanKillSwitchEnabled },
            set: { policy.extendedScanKillSwitchEnabled = $0 }
        )
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Default Sync Range")) {
                    Picker("Range", selection: defaultRangeBinding) {
                        ForEach(SyncRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(header: Text("Background Sync")) {
                    Toggle("Enable background sync", isOn: backgroundEnabledBinding)
                    Text("Periodically syncs in the background when the app is not in use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Interval", selection: backgroundIntervalBinding) {
                        ForEach([2, 6, 12, 24], id: \.self) { hours in
                            Text("Every \(hours)h").tag(hours)
                        }
                    }
                }

                Section {
                    Toggle("Allow long scans & background continuation", isOn: longScanOptInBinding)
                    Text("Allows extended coverage scans to continue in the background. Requires more battery and data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Long Scan & Background")
                }

                Section(header: Text("Coverage Scan")) {
                    Picker("Range", selection: coverageScanMonthsBinding) {
                        Text("1 month").tag(1)
                        Text("3 months").tag(3)
                        Text("6 months").tag(6)
                        Text("12 months").tag(12)
                        if policy.longScanAndBackgroundOptIn {
                            Text("24 months").tag(24)
                        }
                        if policy.coverage36MonthExperimentalEnabled {
                            Text("36 months (experimental)").tag(36)
                        }
                    }
                    Text("Selected range: \(policy.coverageScanMonths) months")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Current max range: \(policy.effectiveMaximumCoverageMonths) months")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Stepper(
                        value: coverageScanMonthsBinding,
                        in: SyncPolicyStore.minimumCoverageMonths...policy.effectiveMaximumCoverageMonths,
                        step: 1
                    ) {
                        Text("Custom range: \(policy.coverageScanMonths) months")
                    }

                    Picker("Scan intensity", selection: coverageScanIntensityBinding) {
                        ForEach(CoverageScanIntensity.allCases) { intensity in
                            Text(intensity.title).tag(intensity)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle("Background scans require charging", isOn: coverageRequireChargingBinding)
                    Toggle("Prefer Wi-Fi for long scans", isOn: coveragePreferWiFiBinding)
                    Text("Wi-Fi preference is best-effort for now and may continue on cellular if iOS schedules the task.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Extended Scan Flags")) {
                    Toggle("Enable 36-month experimental range", isOn: coverage36MonthExperimentalBinding)
                    Toggle("Emergency kill switch for extended ranges", isOn: extendedScanKillSwitchBinding)
                    Text("24-month range requires Long Scan opt-in. 36-month range remains experimental and can be disabled instantly via kill switch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Limits")) {
                    Stepper(value: maxMessagesBinding, in: 1000...200_000, step: 1000) {
                        Text("Max messages per slice: \(policy.maxMessagesPerSlice)")
                    }
                    Text("Higher values pull more mail but may be slower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sync Policy")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
