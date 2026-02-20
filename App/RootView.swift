import SwiftUI
#if DEBUG
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
#endif

struct RootView: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    
    var body: some View {
        TabView {
            NavigationStack {
                DigestView()
            }
            .tabItem {
                Label("Obligations", systemImage: "checklist")
            }
            
            ConnectGmailView()
                .tabItem {
                    Label("Connect Gmail", systemImage: "envelope")
                }
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }

#if DEBUG
            NavigationStack {
                GoldDatasetLabelView()
            }
            .tabItem {
                Label("Dev: Label", systemImage: "square.and.pencil")
            }

            NavigationStack {
                PolicyDiffDebugView()
            }
            .tabItem {
                Label("Dev: Policy Diff", systemImage: "arrow.triangle.branch")
            }
#endif
        }
    }
}

#if DEBUG
private struct PolicyDiffDebugView: View {
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @AppStorage(GoldDatasetStore.selectedDatasetDefaultsKey) private var selectedDatasetFilename: String = ""
    @State private var reportText: String = "Run policy diff to compare baseline vs candidate mapping."
    @State private var isRunning = false
    @State private var statsText: String = ""
    @State private var actionText: String = ""
    @State private var showExporter = false
    @State private var exportDocument = MarkdownFileDocument(text: "")
    @State private var availableDatasetFilenames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(availableDatasetFilenames, id: \.self) { filename in
                        Button(filename) {
                            selectedDatasetFilename = filename
                            actionText = "Using dataset: \(filename)"
                        }
                    }
                } label: {
                    Label(
                        selectedDatasetFilename.isEmpty ? "Choose dataset" : selectedDatasetFilename,
                        systemImage: "folder"
                    )
                }

                Button("Refresh files") {
                    refreshDatasetChoices()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 12) {
                Button("Run Policy Diff") {
                    Task { await runDiff() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning)

                Button("Copy Report") {
                    copyReport()
                }
                .buttonStyle(.bordered)
                .disabled(reportText.isEmpty)

                Button("Export .md") {
                    exportDocument = MarkdownFileDocument(text: reportText)
                    showExporter = true
                }
                .buttonStyle(.bordered)
                .disabled(reportText.isEmpty)

                if isRunning {
                    ProgressView()
                }
            }

            if !statsText.isEmpty {
                Text(statsText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !actionText.isEmpty {
                Text(actionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(reportText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }
        }
        .padding()
        .navigationTitle("Policy Diff")
        .onAppear {
            refreshDatasetChoices()
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "policy-diff-report"
        ) { result in
            switch result {
            case let .success(url):
                actionText = "Exported report to \(url.lastPathComponent)"
            case let .failure(error):
                actionText = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    private func runDiff() async {
        isRunning = true
        defer { isRunning = false }
        refreshDatasetChoices()

        let items = loadDatasetItems()
        guard !items.isEmpty else {
            statsText = "No dataset available."
            reportText = "No dataset JSON found in Documents. Export a dataset first from Settings."
            return
        }

        let baseline = RuleEngine(
            preferences: environmentStore.value.filterPreferencesStore,
            policyVersion: .v1StaticBridge
        )
        let candidate = RuleEngine(
            preferences: environmentStore.value.filterPreferencesStore,
            policyVersion: .v2PolicyDriven
        )
        var changedCount = 0
        let maxRows = 60
        var previewRows: [LocalPolicyDiffRow] = []
        previewRows.reserveCapacity(maxRows)

        for item in items {
            autoreleasepool {
                let sampleId = item.obligationId.isEmpty ? "message_\(item.messagePk)" : item.obligationId
                let email = ParsedEmail(
                    subject: item.subject,
                    snippet: item.snippet ?? "",
                    bodyText: item.bodyText ?? "",
                    sender: item.sender,
                    senderDomain: item.senderDomain,
                    hasAttachments: false,
                    labelIds: item.labelIds,
                    normalizedText: item.normalizedText
                )
                let before = baseline.assess(email: email)
                let after = candidate.assess(email: email)
                let row = LocalPolicyDiffRow(
                    sampleId: sampleId,
                    beforeOutcome: before.decision,
                    afterOutcome: after.decision,
                    beforeHypothesis: before.decisionContract.primaryHypothesisId,
                    afterHypothesis: after.decisionContract.primaryHypothesisId,
                    beforeReasonCode: before.decisionContract.reasonCode,
                    afterReasonCode: after.decisionContract.reasonCode
                )
                if row.changed {
                    changedCount += 1
                    if previewRows.count < maxRows {
                        previewRows.append(row)
                    }
                }
            }
        }

        statsText = "Compared \(items.count) samples • changed \(changedCount) • unchanged \(items.count - changedCount)"
        reportText = markdownSummary(
            rows: previewRows,
            changedCount: changedCount,
            totalCount: items.count,
            maxRows: maxRows
        )
    }

    private func loadDatasetItems() -> [GoldDatasetExportItem] {
        let filename = selectedDatasetFilename.isEmpty ? GoldDatasetStore.defaultDatasetFilename() : selectedDatasetFilename
        if let filename, let export = GoldDatasetStore.load(filename: filename) {
            selectedDatasetFilename = filename
            return export.items
        }
        return []
    }

    private func markdownSummary(
        rows: [LocalPolicyDiffRow],
        changedCount: Int,
        totalCount: Int,
        maxRows: Int
    ) -> String {
        var lines: [String] = []
        lines.append("Policy Diff Summary")
        lines.append("- total: \(totalCount)")
        lines.append("- changed: \(changedCount)")
        lines.append("- unchanged: \(totalCount - changedCount)")
        lines.append("")
        lines.append("| sample | outcome (before->after) | hypothesis (before->after) | reason (before->after) |")
        lines.append("|---|---|---|---|")
        for row in rows.prefix(maxRows) {
            let beforeHyp = row.beforeHypothesis ?? "-"
            let afterHyp = row.afterHypothesis ?? "-"
            lines.append(
                "| \(row.sampleId) | \(row.beforeOutcome.rawValue) -> \(row.afterOutcome.rawValue) | \(beforeHyp) -> \(afterHyp) | \(row.beforeReasonCode.rawValue) -> \(row.afterReasonCode.rawValue) |"
            )
        }
        if changedCount > maxRows {
            lines.append("| ... | ... | ... | ... |")
        }
        return lines.joined(separator: "\n")
    }

    private func copyReport() {
#if canImport(UIKit)
        UIPasteboard.general.string = reportText
        actionText = "Copied report to clipboard."
#else
        actionText = "Clipboard copy is unavailable on this platform."
#endif
    }

    private func refreshDatasetChoices() {
        availableDatasetFilenames = GoldDatasetStore.availableDatasetFilenames()
        if selectedDatasetFilename.isEmpty,
           let fallback = GoldDatasetStore.defaultDatasetFilename() {
            selectedDatasetFilename = fallback
        } else if !selectedDatasetFilename.isEmpty,
                  !availableDatasetFilenames.contains(selectedDatasetFilename),
                  let fallback = GoldDatasetStore.defaultDatasetFilename() {
            selectedDatasetFilename = fallback
        }
    }
}

private struct LocalPolicyDiffRow {
    let sampleId: String
    let beforeOutcome: ObligationDecision
    let afterOutcome: ObligationDecision
    let beforeHypothesis: String?
    let afterHypothesis: String?
    let beforeReasonCode: ReasonCode
    let afterReasonCode: ReasonCode

    var changed: Bool {
        beforeOutcome != afterOutcome
            || beforeHypothesis != afterHypothesis
            || beforeReasonCode != afterReasonCode
    }
}

private struct MarkdownFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let string = String(data: data, encoding: .utf8) {
            text = string
        } else {
            text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
#endif
