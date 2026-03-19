import SwiftUI
import Combine

// MARK: - Year Scan History

struct YearScanHistoryView: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @StateObject private var viewModel = YearScanHistoryViewModel()
    @State private var selectedItem: YearScanItem?
    @State private var showExpectedPatterns = false
    @State private var showDroppedDiagnostics = false

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView("Loading scan history...")
            } else if let snapshot = viewModel.snapshot {
                scanHistoryContent(snapshot)
            } else {
                noHistoryView
            }
        }
        .navigationTitle("Scan History")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadHistory(repository: environmentStore.value.yearScanRepository)
        }
        .task(id: viewModel.snapshot?.isInProgress == true) {
            guard viewModel.snapshot?.isInProgress == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                viewModel.lightweightPollTick += 1
                let includeResults = viewModel.lightweightPollTick % 4 == 0
                await viewModel.loadHistory(
                    repository: environmentStore.value.yearScanRepository,
                    showLoading: false,
                    includeResults: includeResults
                )
                if viewModel.snapshot?.isInProgress != true {
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

                if let lastRefreshAt = viewModel.lastRefreshAt, snapshot.isInProgress {
                    LabeledContent("Last update", value: lastRefreshAt.formatted(date: .omitted, time: .standard))
                }
                if snapshot.isInProgress, viewModel.newSinceLastRefreshCount > 0 {
                    LabeledContent("New since refresh", value: "+\(viewModel.newSinceLastRefreshCount)")
                }

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

            if let resumeState = snapshot.resumeState {
                Section {
                    LabeledContent("Phase", value: resumeState.phase.rawValue.capitalized)
                    LabeledContent("Progress", value: "\(resumeState.monthIndex + 1) of \(resumeState.totalMonths) months")
                    if let monthLabel = resumeState.currentMonthLabel, !monthLabel.isEmpty {
                        LabeledContent("Resume Month", value: monthLabel)
                    }
                    if let page = resumeState.currentPage, page > 0 {
                        LabeledContent("Resume Page", value: "\(page)")
                    }
                    if let throttleReason = throttleReasonLabel(resumeState.lastThrottleReason) {
                        LabeledContent("Paused Reason", value: throttleReason)
                    }

                    if let lastStatus = resumeState.lastStatusMessage {
                        LabeledContent("Status", value: lastStatus)
                    }
                } header: {
                    Text("Resume Info")
                } footer: {
                    Text("This scan was paused and can be resumed from the Year Scan section")
                }
            }

            if let summaries = snapshot.resumeState?.monthSummaries, !summaries.isEmpty {
                Section {
                    ForEach(monthSummaryRows(from: summaries)) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(summary.monthLabel)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                if summary.isInProgress {
                                    Text("Scanning")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.blue)
                                } else if let completedAt = summary.completedAt {
                                    Text(completedAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(monthSummarySubtitle(summary))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Monthly Progress")
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

    private func monthSummaryRows(from summaries: [YearScanMonthSummary]) -> [YearScanMonthSummary] {
        let inProgress = summaries.filter(\.isInProgress).sorted { $0.monthIndex > $1.monthIndex }
        let completed = summaries.filter { !$0.isInProgress }.sorted { $0.monthIndex > $1.monthIndex }
        return inProgress + completed
    }

    private func monthSummarySubtitle(_ summary: YearScanMonthSummary) -> String {
        let counts = "Promoted \(summary.promotedCount) • Expected \(summary.expectedCount) • Dropped \(summary.droppedCount)"
        if summary.messagesScanned > 0 {
            return "\(summary.messagesScanned) scanned • \(counts)"
        }
        return counts
    }

    private func throttleReasonLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw {
        case "memory": return "Memory pressure"
        case "thermal": return "Thermal pressure"
        case "lowPower": return "Low Power Mode"
        case "recovery": return "Recovery mode"
        default: return raw.capitalized
        }
    }
}

@MainActor
final class YearScanHistoryViewModel: ObservableObject {
    @Published var snapshot: YearScanSnapshot?
    @Published var isLoading = true
    @Published var lastRefreshAt: Date?
    @Published var newSinceLastRefreshCount: Int = 0
    var lightweightPollTick: Int = 0

    func loadHistory(
        repository: YearScanRepositorying,
        showLoading: Bool = true,
        includeResults: Bool = true
    ) async {
        if showLoading {
            isLoading = true
        }
        let previousItemsCount = snapshot?.items.count ?? 0
        do {
            if includeResults || snapshot == nil {
                snapshot = try await repository.fetchLatest()
            } else if let state = try await repository.fetchLatestState(),
                      let current = snapshot {
                snapshot = mergedSnapshot(current: current, state: state)
            } else {
                snapshot = try await repository.fetchLatest()
            }
            if let snapshot {
                lastRefreshAt = Date()
                if snapshot.isInProgress {
                    newSinceLastRefreshCount = max(0, snapshot.items.count - previousItemsCount)
                } else {
                    newSinceLastRefreshCount = 0
                }
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
}

struct YearScanItemDetailView: View {
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
