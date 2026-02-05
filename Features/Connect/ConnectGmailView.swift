import SwiftUI

struct ConnectGmailView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = ConnectGmailViewModel()
    @State private var showingPolicy = false

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                if viewModel.isConnected {
                    connectedView
                } else {
                    disconnectedView
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Connect")
            .sheet(isPresented: $showingPolicy) {
                SyncPolicyView()
                    .environmentObject(environment)
            }
            .onAppear {
                Task {
                    await viewModel.checkConnection(using: environment.value)
                }
            }
        }
    }
    
    // MARK: - Disconnected State
    
    private var disconnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Connect Gmail")
                .font(.title2.bold())
            
            Text("Read-only access to your inbox.\nAll processing happens on-device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                Task {
                    await viewModel.connect(using: environment.value)
                }
            } label: {
                HStack {
                    Image(systemName: "link")
                    Text("Connect with Google")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            
            if let status = viewModel.statusMessage {
                Text(status)
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
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                        Text("Sync Now")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isSyncing || viewModel.isBackfilling)
                
                Button(role: .destructive) {
                    Task {
                        await viewModel.resetLocalData(using: environment.value)
                    }
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

                Button {
                    Task {
                        await viewModel.backfillLast12Months(using: environment.value)
                    }
                } label: {
                    HStack {
                        if viewModel.isBackfilling {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        Text("Backfill 12 Months")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSyncing || viewModel.isBackfilling)
                
                Button(role: .destructive) {
                    viewModel.disconnect(using: environment.value)
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Disconnect")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
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
                    Picker("Interval", selection: backgroundIntervalBinding) {
                        ForEach([2, 6, 12, 24], id: \.self) { hours in
                            Text("Every \(hours)h").tag(hours)
                        }
                    }
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
