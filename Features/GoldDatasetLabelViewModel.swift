import SwiftUI
@preconcurrency import Combine

@MainActor
final class GoldDatasetLabelViewModel: ObservableObject {
    @Published private(set) var items: [GoldDatasetExportItem] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var savePath: String?
    @Published private(set) var savedURL: URL?
    @Published var searchQuery: String = ""
    @Published private(set) var currentIndex: Int = 0

    private var metadata: GoldDatasetMetadata?
    private var sourceFilename: String = GoldDatasetStore.obligationsFilename

    func load() {
        errorMessage = nil
        savePath = nil
        savedURL = nil

        if let stratified = GoldDatasetStore.load(filename: GoldDatasetStore.stratifiedFilename) {
            metadata = stratified.metadata
            sourceFilename = GoldDatasetStore.stratifiedFilename
            items = stratified.items
        } else if let obligations = GoldDatasetStore.load(filename: GoldDatasetStore.obligationsFilename) {
            metadata = obligations.metadata
            sourceFilename = GoldDatasetStore.obligationsFilename
            items = obligations.items
        } else if let nearMisses = GoldDatasetStore.load(filename: GoldDatasetStore.nearMissFilename) {
            metadata = nearMisses.metadata
            sourceFilename = GoldDatasetStore.nearMissFilename
            items = nearMisses.items
        } else {
            items = []
        }
        currentIndex = 0
        if items.isEmpty {
            errorMessage = "No exported datasets found. Use Settings → Debug to export first."
        }
    }

    func save() {
        let export = GoldDatasetExport(
            generatedAt: Date(),
            metadata: metadata ?? defaultMetadata(),
            items: items
        )
        do {
            let url = try GoldDatasetStore.save(export: export, filename: sourceFilename)
            savePath = url.path
            savedURL = url
        } catch {
            errorMessage = error.localizedDescription
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
                $0.expectedReason = item.currentReasons.first
            }
        }
        save()
        advance()
    }

    func approveCurrent() {
        guard let item = currentItem else { return }
        update(item) {
            $0.expectedOutcome = item.currentDecision.rawValue
            $0.expectedHypothesis = item.currentHypotheses.first
            $0.expectedReason = item.currentReasons.first
        }
        save()
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
        save()
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
                "marketingNoise"
            ]
        )
    }

    func advance() {
        guard !items.isEmpty else { return }
        currentIndex = min(currentIndex + 1, items.count - 1)
    }

    func back() {
        currentIndex = max(currentIndex - 1, 0)
    }

    private func update(_ item: GoldDatasetExportItem, mutate: (inout GoldDatasetExportItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.messagePk == item.messagePk && $0.obligationId == item.obligationId }) else {
            return
        }
        var copy = items[index]
        mutate(&copy)
        items[index] = copy
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
            "marketingNoise"
        ]
    }

    var reasonOptions: [String] {
        [
            "Direct request with a clear deadline",
            "Direct request without a deadline",
            "Deadline mentioned without a request",
            "Waiting on someone else to respond",
            "Legal or compliance requirement",
            "Security alert / informational",
            "Receipt or confirmation only",
            "Marketing / newsletter / promo",
            "Other..."
        ]
    }

    func shouldChooseHypothesis(for outcome: String?) -> Bool {
        guard let outcome, !outcome.isEmpty else { return false }
        return outcome != "reject"
    }
}
