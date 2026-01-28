import SwiftUI

struct ConnectGmailView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = ConnectGmailViewModel()

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
            .onAppear {
                viewModel.checkConnection(using: environment.value)
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
                .disabled(viewModel.isSyncing)
                
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
