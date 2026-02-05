import Combine
import Foundation

@MainActor
final class DigestViewModel: ObservableObject {
    
    // MARK: - Dependencies
    
    private var environment: AppEnvironment?
    
    // MARK: - Published State
    
    @Published private(set) var sections: [DigestSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published var undoBanner: UndoBanner?
    @Published var learningBanner: String?
    @Published private(set) var borderlineItems: [BorderlineItem] = []
    @Published private(set) var hasMoreBorderline = false
    @Published private(set) var isLoadingMoreBorderline = false
    @Published var searchQuery: String = ""

    private var pendingUndoTask: Task<Void, Never>?
    private var pendingWeightTask: Task<Void, Never>?
    private var pendingLearningTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var borderlineOffset = 0
    private let borderlinePageSize = 10
    
    var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty } && borderlineItems.isEmpty
    }
    
    // MARK: - Actions
    
    func loadDigest(using environment: AppEnvironment) async {
        self.environment = environment
        isLoading = true
        error = nil
        
        do {
            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let obligations: [ObligationItem]
            if trimmedQuery.isEmpty {
                obligations = try await environment.obligationRepository.fetchTopDigest(limit: 50)
            } else {
                obligations = try await environment.obligationRepository.fetchDigest(query: trimmedQuery, limit: 50)
            }
            sections = Self.buildSections(from: obligations, preferences: environment.filterPreferencesStore)
            borderlineOffset = 0
            await loadBorderlinePage(reset: true)
        } catch {
            self.error = error
            sections = []
            borderlineItems = []
            hasMoreBorderline = false
        }
        
        isLoading = false
    }

    func updateSearchQuery(_ query: String) {
        searchQuery = query
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, let environment = self.environment else { return }
            await self.loadDigest(using: environment)
        }
    }
    
    func snooze(_ obligation: ObligationItem) async {
        guard let environment else { return }
        
        // Default snooze: 1 day from now
        let snoozeUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        
        do {
            try await environment.obligationRepository.snooze(id: obligation.id, until: snoozeUntil)
            try await environment.feedbackRepository.save(
                FeedbackRecord(
                    mailboxAccountId: obligation.mailboxAccountId,
                    messagePk: obligation.messagePk,
                    obligationId: obligation.id,
                    action: .snoozed,
                    reason: "snoozed",
                    matchedRuleIds: obligation.matchedRuleIds.joined(separator: ",")
                )
            )
            try await environment.ruleWeightRepository.applyFeedback(
                mailboxAccountId: obligation.mailboxAccountId,
                matchedRuleIds: obligation.matchedRuleIds,
                action: .snoozed
            )
            showLearningBanner()
            removeFromSections(obligation)
        } catch {
            self.error = error
        }
    }
    
    func dismiss(_ obligation: ObligationItem) async {
        guard let environment else { return }
        
        do {
            try await environment.feedbackRepository.save(
                FeedbackRecord(
                    mailboxAccountId: obligation.mailboxAccountId,
                    messagePk: obligation.messagePk,
                    obligationId: obligation.id,
                    action: .dismissed,
                    reason: "dismissed",
                    matchedRuleIds: obligation.matchedRuleIds.joined(separator: ",")
                )
            )
            try await environment.obligationRepository.dismiss(id: obligation.id)
            removeFromSections(obligation)
            scheduleUndo(for: obligation, action: .dismissed)
        } catch {
            self.error = error
        }
    }

    func confirm(_ obligation: ObligationItem) async {
        guard let environment else { return }

        do {
            try await environment.feedbackRepository.save(
                FeedbackRecord(
                    mailboxAccountId: obligation.mailboxAccountId,
                    messagePk: obligation.messagePk,
                    obligationId: obligation.id,
                    action: .accepted,
                    reason: "confirmed",
                    matchedRuleIds: obligation.matchedRuleIds.joined(separator: ",")
                )
            )
            try await environment.ruleWeightRepository.applyFeedback(
                mailboxAccountId: obligation.mailboxAccountId,
                matchedRuleIds: obligation.matchedRuleIds,
                action: .accepted
            )
            showLearningBanner()
        } catch {
            self.error = error
        }
    }

    func markDone(_ obligation: ObligationItem) async {
        guard let environment else { return }

        do {
            try await environment.feedbackRepository.save(
                FeedbackRecord(
                    mailboxAccountId: obligation.mailboxAccountId,
                    messagePk: obligation.messagePk,
                    obligationId: obligation.id,
                    action: .accepted,
                    reason: "done",
                    matchedRuleIds: obligation.matchedRuleIds.joined(separator: ",")
                )
            )
            try await environment.obligationRepository.markDone(id: obligation.id)
            removeFromSections(obligation)
            scheduleUndo(for: obligation, action: .accepted)
            showLearningBanner()
        } catch {
            self.error = error
        }
    }

    func promote(_ item: BorderlineItem) async {
        guard let environment else { return }
        do {
            guard let message = try await environment.messageRepository.fetchByPk(item.messagePk) else { return }
            guard let messagePk = message.pk else { return }
            let assessment = try await environment.obligationExtractor.assess(
                message: message,
                mailboxAccountId: item.mailboxAccountId
            )
            let obligation = environment.obligationExtractor.makeObligation(
                from: assessment,
                message: message,
                mailboxAccountId: item.mailboxAccountId,
                messagePk: messagePk
            )
            try await environment.obligationRepository.save(obligation)
            try await environment.feedbackRepository.save(
                FeedbackRecord(
                    mailboxAccountId: item.mailboxAccountId,
                    messagePk: item.messagePk,
                    obligationId: obligation.id,
                    action: .accepted,
                    reason: "promoted",
                    matchedRuleIds: item.matchedRuleIds.joined(separator: ",")
                )
            )
            try await environment.ruleWeightRepository.applyFeedback(
                mailboxAccountId: item.mailboxAccountId,
                matchedRuleIds: item.matchedRuleIds,
                action: .accepted
            )
            try await environment.candidateScoreRepository.delete(messagePk: item.messagePk)
            borderlineItems.removeAll { $0.messagePk == item.messagePk }
            await loadDigest(using: environment)
            showLearningBanner()
        } catch {
            self.error = error
        }
    }

    func dismissBorderline(_ item: BorderlineItem) async {
        guard let environment else { return }
        do {
            try await environment.feedbackRepository.save(
                FeedbackRecord(
                    mailboxAccountId: item.mailboxAccountId,
                    messagePk: item.messagePk,
                    obligationId: nil,
                    action: .dismissed,
                    reason: "borderline_dismissed",
                    matchedRuleIds: item.matchedRuleIds.joined(separator: ",")
                )
            )
            try await environment.ruleWeightRepository.applyFeedback(
                mailboxAccountId: item.mailboxAccountId,
                matchedRuleIds: item.matchedRuleIds,
                action: .dismissed
            )
            try await environment.candidateScoreRepository.delete(messagePk: item.messagePk)
            borderlineItems.removeAll { $0.messagePk == item.messagePk }
            showLearningBanner()
            if hasMoreBorderline {
                await loadMoreBorderline()
            }
        } catch {
            self.error = error
        }
    }
    
    // MARK: - Private Helpers
    
    private func removeFromSections(_ obligation: ObligationItem) {
        sections = sections.compactMap { section in
            let filtered = section.items.filter { $0.id != obligation.id }
            guard !filtered.isEmpty else { return nil }
            return DigestSection(kind: section.kind, items: filtered)
        }
    }

    private func scheduleUndo(for obligation: ObligationItem, action: FeedbackRecord.FeedbackAction) {
        pendingUndoTask?.cancel()
        pendingWeightTask?.cancel()

        undoBanner = UndoBanner(
            message: action == .dismissed ? "Dismissed" : "Marked done",
            obligation: obligation,
            action: action
        )

        pendingWeightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, let environment = self.environment, let banner = self.undoBanner else { return }
            try? await environment.ruleWeightRepository.applyFeedback(
                mailboxAccountId: banner.obligation.mailboxAccountId,
                matchedRuleIds: banner.obligation.matchedRuleIds,
                action: banner.action
            )
            self.undoBanner = nil
            self.showLearningBanner()
        }

        pendingUndoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            self?.undoBanner = nil
        }
    }

    func undoLastAction() async {
        guard let environment, let banner = undoBanner else { return }
        pendingWeightTask?.cancel()
        pendingUndoTask?.cancel()
        undoBanner = nil

        do {
            try await environment.obligationRepository.updateStatus(id: banner.obligation.id, status: .open)
            await loadDigest(using: environment)
        } catch {
            self.error = error
        }
    }

    func loadMoreBorderline() async {
        guard let environment, !isLoadingMoreBorderline, hasMoreBorderline else { return }
        isLoadingMoreBorderline = true
        await loadBorderlinePage(reset: false)
        isLoadingMoreBorderline = false
    }

    private func loadBorderlinePage(reset: Bool) async {
        guard let environment else { return }
        do {
            let offset = reset ? 0 : borderlineOffset
            let page = try await environment.candidateScoreRepository.fetchBorderline(
                limit: borderlinePageSize + 1,
                offset: offset
            )
            let moreAvailable = page.count > borderlinePageSize
            let items = moreAvailable ? Array(page.prefix(borderlinePageSize)) : page
            if reset {
                borderlineItems = items
                borderlineOffset = items.count
            } else {
                borderlineItems.append(contentsOf: items)
                borderlineOffset += items.count
            }
            hasMoreBorderline = moreAvailable
        } catch {
            self.error = error
            hasMoreBorderline = false
        }
    }

    private func showLearningBanner() {
        pendingLearningTask?.cancel()
        learningBanner = "Learning improved"
        pendingLearningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.learningBanner = nil
        }
    }
    
    private static func buildSections(
        from obligations: [ObligationItem],
        preferences: FilterPreferencesStoring
    ) -> [DigestSection] {
        // Group by digestSection computed property
        let filtered = obligations.filter { shouldInclude($0, preferences: preferences) }
        let grouped = Dictionary(grouping: filtered) { $0.digestSection }
        
        let orderedKinds: [DigestSection.Kind] = [.thisWeek, .upcoming, .waitingOn, .overdue]
        return orderedKinds.compactMap { kind in
            guard let items = grouped[kind.sectionType], !items.isEmpty else { return nil }
            
            let sorted = items.sorted {
                if $0.urgencyRank != $1.urgencyRank {
                    return $0.urgencyRank < $1.urgencyRank
                }
                if $0.confidence != $1.confidence {
                    return $0.confidence > $1.confidence
                }
                return ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
            }
            return DigestSection(kind: kind, items: sorted)
        }
    }

    private static func shouldInclude(_ item: ObligationItem, preferences: FilterPreferencesStoring) -> Bool {
        let combined = ([item.title, item.evidenceQuote] + item.matchedReasons).joined(separator: " ").lowercased()
        if preferences.includeSecurityAlerts == false,
           (combined.contains("password changed") || combined.contains("sign-in attempt") || combined.contains("security alert")) {
            return false
        }
        if preferences.includeStatements == false,
           (combined.contains("statement available") || combined.contains("monthly statement") || combined.contains("account statement")) {
            return false
        }
        if preferences.includeMarketing == false,
           (combined.contains("unsubscribe") || combined.contains("sale") || combined.contains("promo") || combined.contains("discount")) {
            return false
        }
        if preferences.includeNewsletters == false,
           (combined.contains("newsletter") || combined.contains("announcement") || combined.contains("roundup")) {
            return false
        }
        if preferences.includeShipping == false,
           (combined.contains("out for delivery") || combined.contains("delivered") || combined.contains("tracking") || combined.contains("shipment")) {
            return false
        }
        return true
    }
}

struct UndoBanner: Identifiable {
    let id = UUID().uuidString
    let message: String
    let obligation: ObligationItem
    let action: FeedbackRecord.FeedbackAction
}

// MARK: - Section Model

struct DigestSection: Identifiable {
    let kind: Kind
    let items: [ObligationItem]
    
    var id: Kind { kind }
    
    enum Kind: CaseIterable, Identifiable {
        case overdue
        case thisWeek
        case upcoming
        case waitingOn
        
        var id: Self { self }
        
        var title: String {
            switch self {
            case .overdue: "Overdue"
            case .thisWeek: "This Week"
            case .upcoming: "Upcoming"
            case .waitingOn: "Waiting On"
            }
        }
        
        var icon: String {
            switch self {
            case .overdue: "exclamationmark.triangle.fill"
            case .thisWeek: "flame.fill"
            case .upcoming: "calendar"
            case .waitingOn: "hourglass"
            }
        }
        
        var color: ColorToken {
            switch self {
            case .overdue: .red
            case .thisWeek: .orange
            case .upcoming: .blue
            case .waitingOn: .purple
            }
        }
        
        var sectionType: ObligationItem.DigestSectionType {
            switch self {
            case .overdue: .overdue
            case .thisWeek: .thisWeek
            case .upcoming: .upcoming
            case .waitingOn: .waitingOn
            }
        }
    }
    
    enum ColorToken {
        case red, orange, blue, purple
    }
}
