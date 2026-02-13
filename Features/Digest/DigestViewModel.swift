import Combine
import Foundation

@MainActor
final class DigestViewModel: ObservableObject {
    
    // MARK: - Dependencies
    
    private var environment: AppEnvironment?
    
    // MARK: - Published State
    
    @Published private(set) var sections: [ObligationListSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    @Published var undoBanner: UndoBanner?
    @Published var learningBanner: String?
    @Published var searchQuery: String = ""
    @Published var selectedLens: ObligationLens = .active
    @Published var selectedGrouping: ObligationGrouping = .dueDate

    private var pendingUndoTask: Task<Void, Never>?
    private var pendingWeightTask: Task<Void, Never>?
    private var pendingLearningTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }
    
    // MARK: - Actions
    
    func loadDigest(using environment: AppEnvironment) async {
        self.environment = environment
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        do {
            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let items: [ObligationListItem]
            if trimmedQuery.isEmpty {
                items = try await environment.obligationProjectionRepository.fetchItems(
                    lens: selectedLens,
                    query: "",
                    limit: 200
                )
            } else {
                items = try await environment.obligationProjectionRepository.fetchItems(
                    lens: selectedLens,
                    query: trimmedQuery,
                    limit: 200
                )
            }
            let filtered = items.filter { Self.shouldInclude($0.obligation, preferences: environment.filterPreferencesStore) }
            sections = Self.buildSections(from: filtered, grouping: selectedGrouping)
        } catch {
            self.error = error
            sections = []
        }
        
    }

    func updateSearchQuery(_ query: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, let environment = self.environment else { return }
            await self.loadDigest(using: environment)
        }
    }

    func clearError() {
        error = nil
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
            try await environment.obligationRepository.markReviewed(id: obligation.id)
            showLearningBanner()
            if selectedLens == .needsReview {
                removeFromSections(obligation)
            }
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

    func blockSender(_ obligation: ObligationItem) async {
        guard let environment else { return }
        do {
            guard let message = try await environment.messageRepository.fetchByPk(obligation.messagePk) else { return }
            let sender = message.fromEmail
            try await environment.suppressionRepository.addSender(
                mailboxAccountId: obligation.mailboxAccountId,
                sender: sender
            )
            try await environment.obligationRepository.dismissBySender(
                mailboxAccountId: obligation.mailboxAccountId,
                sender: sender
            )
            await loadDigest(using: environment)
        } catch {
            self.error = error
        }
    }

    func blockDomain(_ obligation: ObligationItem) async {
        guard let environment else { return }
        do {
            guard let message = try await environment.messageRepository.fetchByPk(obligation.messagePk) else { return }
            guard let domain = message.fromDomain, !domain.isEmpty else { return }
            try await environment.suppressionRepository.addDomain(
                mailboxAccountId: obligation.mailboxAccountId,
                domain: domain
            )
            try await environment.obligationRepository.dismissByDomain(
                mailboxAccountId: obligation.mailboxAccountId,
                domain: domain
            )
            await loadDigest(using: environment)
        } catch {
            self.error = error
        }
    }

    // MARK: - Private Helpers
    
    private func removeFromSections(_ obligation: ObligationItem) {
        sections = sections.compactMap { section in
            let filtered = section.items.filter { $0.obligation.id != obligation.id }
            guard !filtered.isEmpty else { return nil }
            return ObligationListSection(id: section.id, title: section.title, items: filtered)
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

    private func showLearningBanner() {
        pendingLearningTask?.cancel()
        learningBanner = "Learning improved"
        pendingLearningTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.learningBanner = nil
        }
    }
    
    private static func buildSections(
        from items: [ObligationListItem],
        grouping: ObligationGrouping
    ) -> [ObligationListSection] {
        switch grouping {
        case .dueDate:
            return buildDueDateSections(items)
        case .detectionDate:
            return buildDetectionSections(items)
        case .sourceThread:
            return buildThreadSections(items)
        }
    }

    private static func buildDueDateSections(_ items: [ObligationListItem]) -> [ObligationListSection] {
        let grouped = Dictionary(grouping: items) { $0.dueBucket }
        let orderedBuckets: [ObligationDueBucket] = [.overdue, .today, .next3Days, .next7Days, .later, .noDueDate]
        return orderedBuckets.compactMap { bucket in
            guard let bucketItems = grouped[bucket], !bucketItems.isEmpty else { return nil }
            let sorted = bucketItems.sorted {
                if $0.obligation.urgencyRank != $1.obligation.urgencyRank {
                    return $0.obligation.urgencyRank < $1.obligation.urgencyRank
                }
                return $0.obligation.confidence > $1.obligation.confidence
            }
            return ObligationListSection(
                id: bucket.rawValue,
                title: bucket.title,
                items: sorted
            )
        }
    }

    private static func buildDetectionSections(_ items: [ObligationListItem]) -> [ObligationListSection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.obligation.createdAt) }
        let orderedDates = grouped.keys.sorted(by: >)
        return orderedDates.compactMap { date in
            guard let dateItems = grouped[date], !dateItems.isEmpty else { return nil }
            let sorted = dateItems.sorted { $0.obligation.createdAt > $1.obligation.createdAt }
            return ObligationListSection(
                id: date.formatted(date: .numeric, time: .omitted),
                title: dateTitle(for: date, calendar: calendar),
                items: sorted
            )
        }
    }

    private static func buildThreadSections(_ items: [ObligationListItem]) -> [ObligationListSection] {
        let grouped = Dictionary(grouping: items) { $0.primaryThreadId ?? $0.obligation.id }
        let orderedKeys = grouped.keys.sorted { lhs, rhs in
            let lhsDate = grouped[lhs]?.map { $0.lastActionAt ?? $0.obligation.updatedAt }.max() ?? .distantPast
            let rhsDate = grouped[rhs]?.map { $0.lastActionAt ?? $0.obligation.updatedAt }.max() ?? .distantPast
            return lhsDate > rhsDate
        }

        return orderedKeys.compactMap { key in
            guard let threadItems = grouped[key], !threadItems.isEmpty else { return nil }
            let sorted = threadItems.sorted {
                if $0.obligation.urgencyRank != $1.obligation.urgencyRank {
                    return $0.obligation.urgencyRank < $1.obligation.urgencyRank
                }
                return $0.obligation.confidence > $1.obligation.confidence
            }
            let title = "Thread • \(sorted.first?.obligation.title ?? "Thread")"
            return ObligationListSection(
                id: key,
                title: title,
                items: sorted
            )
        }
    }

    private static func dateTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private static func shouldInclude(_ item: ObligationItem, preferences: FilterPreferencesStoring) -> Bool {
        let combined = ([item.title, item.evidenceQuote] + item.matchedReasons).joined(separator: " ").lowercased()
        let matchedRuleSet = Set(item.matchedRuleIds)
        let matchedReasonSet = Set(item.matchedReasons.map { $0.lowercased() })
        let matchedSignalSet = Set(item.matchedSignalTypes.map { $0.lowercased() })
        if preferences.includeSecurityAlerts == false,
           (combined.contains("password changed") || combined.contains("sign-in attempt") || combined.contains("security alert")) {
            return false
        }
        if preferences.includeStatements == false,
           (combined.contains("statement available") || combined.contains("monthly statement") || combined.contains("account statement")) {
            return false
        }
        if preferences.includeMarketing == false {
            let hasMarketingRule = matchedRuleSet.contains("promo_label")
                || matchedRuleSet.contains("promo_keywords")
                || matchedRuleSet.contains("marketing_language")
                || matchedRuleSet.contains("newsletter")
                || matchedRuleSet.contains("promotional_label")
            let hasMarketingReason = matchedReasonSet.contains(where: {
                $0.contains("promotion") || $0.contains("marketing") || $0.contains("newsletter")
            })
            let hasMarketingSignals = matchedSignalSet.contains("label")
            let hasMarketingKeywords = combined.contains("unsubscribe")
                || combined.contains("sale")
                || combined.contains("promo")
                || combined.contains("discount")
                || combined.contains("offer")
                || combined.contains("coupon")
                || combined.contains("shop now")
            if hasMarketingRule || hasMarketingReason || (hasMarketingSignals && hasMarketingKeywords) {
                return false
            }
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

struct ObligationListSection: Identifiable {
    let id: String
    let title: String
    let items: [ObligationListItem]
}
