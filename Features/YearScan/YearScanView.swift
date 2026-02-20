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
                    ContentUnavailableView {
                        Label("Checking coverage", systemImage: "magnifyingglass")
                    } description: {
                        Text(viewModel.statusMessage ?? "Scanning your past year for missed bills and renewals.")
                    }
                    .symbolRenderingMode(.hierarchical)
                }
            } else if viewModel.isInProgress {
                Section {
                    ContentUnavailableView {
                        Label("Resume coverage check", systemImage: "play.circle")
                    } description: {
                        Text(viewModel.statusMessage ?? "Tap below to continue scanning your past year.")
                    } actions: {
                        Button("Resume check") {
                            viewModel.restartScan(using: environment.value)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else if viewModel.results.isEmpty {
                Section {
                    if viewModel.lastChecked != nil, viewModel.scannedMessageCount == 0 {
                        ContentUnavailableView {
                            Label("Connect Gmail to run coverage check", systemImage: "envelope.badge")
                        } description: {
                            Text("Sync your inbox first, then we'll scan the past year for missed bills and renewals.")
                        } actions: {
                            NavigationLink(destination: ConnectGmailView().environmentObject(environment)) {
                                Label("Connect Gmail", systemImage: "link")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("You're all clear", systemImage: "checkmark.circle")
                        } description: {
                            Text("We checked the last 12 months for missed bills, renewals, and official requests. Nothing looks unresolved.")
                        } actions: {
                            Button("Recheck now") {
                                viewModel.restartScan(using: environment.value)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

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
                        NavigationLink {
                            YearScanDetailView(
                                item: item,
                                onResolve: { resolve(item) },
                                onDismiss: { viewModel.dismiss(item) },
                                onOpen: { open(item) }
                            )
                        } label: {
                            YearScanRowView(item: item)
                        }
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
        .alert("Coverage check failed", isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("Try again") {
                viewModel.clearError()
                viewModel.restartScan(using: environment.value)
            }
            Button("Dismiss", role: .cancel) { viewModel.clearError() }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "Something went wrong. Tap Try again to rerun the check.")
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
        }
        .padding(.vertical, 4)
    }
}

private struct YearScanDetailView: View {
    let item: YearScanItem
    let onResolve: () -> Void
    let onDismiss: () -> Void
    let onOpen: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showDismissConfirmation = false

    var body: some View {
        List {
            Section {
                Text(item.subject)
                    .font(.title3.weight(.semibold))
                if !item.snippet.isEmpty {
                    Text(item.snippet)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !item.matchedReasons.isEmpty {
                Section("Why this was flagged") {
                    ForEach(Array(item.matchedReasons.enumerated()), id: \.offset) { _, reason in
                        Text(reason)
                    }
                }
            }

            Section("Actions") {
                Button("Open in Gmail and mark resolved") {
                    onResolve()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)

                Button("Open in Gmail only") {
                    onOpen()
                }

                Button(role: .destructive) {
                    showDismissConfirmation = true
                } label: {
                    Text("Dismiss")
                }
            }
        }
        .navigationTitle("Coverage Item")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Dismiss this coverage item?", isPresented: $showDismissConfirmation, titleVisibility: .visible) {
            Button("Dismiss", role: .destructive) {
                onDismiss()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the item from the coverage results.")
        }
    }
}
