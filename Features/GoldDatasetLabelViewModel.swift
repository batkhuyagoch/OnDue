import SwiftUI
@preconcurrency import Combine

@MainActor
final class GoldDatasetLabelViewModel: ObservableObject {
    @Published private(set) var items: [GoldDatasetExportItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var savePath: String?
    @Published private(set) var savedURL: URL?
    @Published private(set) var availableDatasetFilenames: [String] = []
    @Published var selectedDatasetFilename: String = ""
    @Published var searchQuery: String = ""
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var hasUnsavedChanges: Bool = false

    private var metadata: GoldDatasetMetadata?
    private var sourceFilename: String = GoldDatasetStore.obligationsFilename
    private var sourceURL: URL?

    func load() {
        errorMessage = nil
        savePath = nil
        savedURL = nil
        hasUnsavedChanges = false
        refreshDatasetChoices()

        let selected = selectedDatasetFilename.isEmpty ? GoldDatasetStore.defaultDatasetFilename() : selectedDatasetFilename
        guard let filename = selected, let dataset = GoldDatasetStore.load(filename: filename) else {
            items = []
            errorMessage = "No exported datasets found. Use Settings → Debug to export first."
            currentIndex = 0
            return
        }
        metadata = dataset.metadata
        sourceFilename = filename
        sourceURL = nil
        selectedDatasetFilename = filename
        GoldDatasetStore.setSelectedDatasetFilename(filename)
        items = dataset.items
        currentIndex = min(currentIndex, max(items.count - 1, 0))
    }

    func save() {
        let export = GoldDatasetExport(
            generatedAt: Date(),
            metadata: metadata ?? defaultMetadata(),
            items: items
        )
        do {
            let targetFilename = sourceURL?.lastPathComponent ?? sourceFilename
            let url = try GoldDatasetStore.save(export: export, filename: targetFilename)
            savePath = url.path
            savedURL = url
            sourceURL = nil
            sourceFilename = targetFilename
            selectedDatasetFilename = targetFilename
            GoldDatasetStore.setSelectedDatasetFilename(targetFilename)
            refreshDatasetChoices()
            hasUnsavedChanges = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importDataset(from url: URL) {
        errorMessage = nil
        guard let imported = GoldDatasetStore.load(url: url) else {
            errorMessage = "Unable to read dataset JSON."
            return
        }
        metadata = imported.metadata
        items = imported.items
        currentIndex = 0
        sourceURL = url
        sourceFilename = url.lastPathComponent
        selectedDatasetFilename = sourceFilename
        savePath = nil
        savedURL = nil
        hasUnsavedChanges = false
    }

    func selectDataset(_ filename: String) {
        guard !filename.isEmpty else { return }
        selectedDatasetFilename = filename
        GoldDatasetStore.setSelectedDatasetFilename(filename)
        load()
    }

    func refreshDatasetChoices() {
        availableDatasetFilenames = GoldDatasetStore.availableDatasetFilenames()
        if selectedDatasetFilename.isEmpty,
           let preferred = GoldDatasetStore.defaultDatasetFilename() {
            selectedDatasetFilename = preferred
        }
    }

    var filteredItems: [GoldDatasetExportItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.subject.lowercased().contains(trimmed) ||
            $0.normalizedText.lowercased().contains(trimmed) ||
            $0.sender.lowercased().contains(trimmed)
        }
    }

    var currentItem: GoldDatasetExportItem? {
        guard !items.isEmpty else { return nil }
        let index = min(max(currentIndex, 0), items.count - 1)
        return items[index]
    }

    var progressText: String {
        "\(labeledCount)/\(items.count) labeled"
    }

    var labeledCount: Int {
        items.filter { $0.expectedOutcome != nil }.count
    }

    func updateExpectedOutcome(_ item: GoldDatasetExportItem, value: String?) {
        update(item) { $0.expectedOutcome = value }
    }

    func updateExpectedHypothesis(_ item: GoldDatasetExportItem, value: String?) {
        update(item) { $0.expectedHypothesis = value }
    }

    func updateExpectedReason(_ item: GoldDatasetExportItem, value: String) {
        update(item) { $0.expectedReason = value }
    }

    func labelCurrent(outcome: String) {
        guard let item = currentItem else { return }
        update(item) {
            $0.expectedOutcome = outcome
            if outcome == "reject" {
                $0.expectedHypothesis = nil
            } else if $0.expectedHypothesis == nil {
                $0.expectedHypothesis = item.currentHypotheses.first
            }
            if $0.expectedReason == nil {
                $0.expectedReason = canonicalReasonText(for: item) ?? item.currentReasons.first
            }
        }
        advance()
    }

    func approveCurrent() {
        guard let item = currentItem else { return }
        update(item) {
            $0.expectedOutcome = item.currentDecision.rawValue
            $0.expectedHypothesis = item.currentHypotheses.first
            $0.expectedReason = canonicalReasonText(for: item) ?? item.currentReasons.first
        }
        advance()
    }

    func applyReason(_ reason: String) {
        guard let item = currentItem else { return }
        update(item) {
            $0.expectedReason = reason
            if $0.expectedOutcome == nil {
                $0.expectedOutcome = "needsReview"
                $0.expectedHypothesis = item.currentHypotheses.first
            }
        }
        advance()
    }

    private func defaultMetadata() -> GoldDatasetMetadata {
        GoldDatasetMetadata(
            editableFields: ["expectedOutcome", "expectedHypothesis", "expectedReason"],
            decisionValues: ["accept", "needsReview", "reject"],
            hypothesisValues: [
                "userActionRequired",
                "deadlineImplied",
                "waitingOnThirdParty",
                "legalOrCompliance",
                "accountChangeRequired",
                "paymentFailure",
                "documentExpiration",
                "identityVerification",
                "deliveryRequired",
                "appointmentActionRequired",
                "thirdPartyAwaitingYou",
                "legalComplianceResponse",
                "marketingNoise"
            ]
        )
    }

    func advance() {
        guard !items.isEmpty else { return }
        currentIndex = min(currentIndex + 1, items.count - 1)
        savePath = nil
        savedURL = nil
    }

    func back() {
        currentIndex = max(currentIndex - 1, 0)
        savePath = nil
        savedURL = nil
    }

    private func update(_ item: GoldDatasetExportItem, mutate: (inout GoldDatasetExportItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.messagePk == item.messagePk && $0.obligationId == item.obligationId }) else {
            return
        }
        var copy = items[index]
        mutate(&copy)
        items[index] = copy
        hasUnsavedChanges = true
    }

    var decisionValues: [String] {
        metadata?.decisionValues ?? ["accept", "needsReview", "reject"]
    }

    var hypothesisValues: [String] {
        metadata?.hypothesisValues ?? [
            "userActionRequired",
            "deadlineImplied",
            "waitingOnThirdParty",
            "legalOrCompliance",
            "accountChangeRequired",
            "paymentFailure",
            "documentExpiration",
            "identityVerification",
            "deliveryRequired",
            "appointmentActionRequired",
            "thirdPartyAwaitingYou",
            "legalComplianceResponse",
            "marketingNoise"
        ]
    }

    var reasonOptions: [String] {
        ReasonCatalog.labelingOptions
    }

    func canonicalReasonText(for item: GoldDatasetExportItem) -> String? {
        guard let first = item.currentReasons.first else { return nil }
        if let code = ReasonCode(rawValue: first) {
            return ReasonCatalog.displayText(for: code)
        }
        return first
    }

    func shouldChooseHypothesis(for outcome: String?) -> Bool {
        guard let outcome, !outcome.isEmpty else { return false }
        return outcome != "reject"
    }
}
