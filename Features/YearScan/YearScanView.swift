import SwiftUI

struct CoverageStatusView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = YearScanViewModel()
    @Environment(\.openURL) private var openURL
    @State private var showDetails = false

    var body: some View {
        List {
            if viewModel.isLoading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            } else if viewModel.isInProgress {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Coverage check paused")
                            .font(.subheadline.weight(.semibold))
                        if let status = viewModel.statusMessage {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Resume to continue the coverage check.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Resume check") {
                            viewModel.restartScan(using: environment.value)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 4)
                }
            } else if viewModel.results.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.lastChecked != nil, viewModel.scannedMessageCount == 0 {
                            Text("No messages to scan yet")
                                .font(.title3.weight(.semibold))
                            Text("Connect Gmail and sync to run a safety check over the past year.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("You’re all clear")
                                .font(.title3.weight(.semibold))
                            Text("We checked the last 12 months for missed bills, renewals, and official requests. Nothing looks unresolved or risky.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)

                    DisclosureGroup("Details", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let lastChecked = viewModel.lastChecked {
                                Text("Last checked: \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                            }
                            Text("Messages scanned: \(viewModel.scannedMessageCount)")
                            Text("Coverage: \(viewModel.coverageSummary)")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    }
                }
            } else {
                Section(header: Text(resultsHeader)) {
                    ForEach(viewModel.results) { item in
                        YearScanRowView(
                            item: item,
                            onResolve: { resolve(item) },
                            onDismiss: { viewModel.dismiss(item) },
                            onOpen: { open(item) }
                        )
                    }
                }
            }
        }
        .navigationTitle("Coverage")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Recheck now") {
                    viewModel.restartScan(using: environment.value)
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "Something went wrong.")
        }
        .onAppear {
            viewModel.startScan(using: environment.value)
            Task {
                await viewModel.loadCached(using: environment.value)
            }
        }
    }

    private var resultsHeader: String {
        let count = viewModel.results.count
        return count == 1 ? "1 item may need attention" : "\(count) items may need attention"
    }

    private func resolve(_ item: YearScanItem) {
        open(item)
        viewModel.dismiss(item)
    }

    private func open(_ item: YearScanItem) {
        if let url = viewModel.providerURL(for: item) {
            openURL(url)
        }
    }
}

private struct YearScanRowView: View {
    let item: YearScanItem
    let onResolve: () -> Void
    let onDismiss: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.subject)
                .font(.subheadline.weight(.semibold))
            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !item.matchedReasons.isEmpty {
                Text(item.matchedReasons.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 12) {
                Button("Resolve") { onResolve() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.bordered)
                Button("Open in Gmail") { onOpen() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
