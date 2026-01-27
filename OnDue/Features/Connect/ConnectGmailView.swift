import SwiftUI
import Combine

struct ConnectGmailView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = ConnectGmailViewModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                Text("Connect Gmail")
                    .font(.title2)
                Text("Read-only access. Processing happens on-device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Connect") {
                    Task {
                        await viewModel.connect(using: environment.value)
                    }
                }
                .buttonStyle(.borderedProminent)

                if let status = viewModel.statusMessage {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .navigationTitle("Connect")
        }
    }
}
