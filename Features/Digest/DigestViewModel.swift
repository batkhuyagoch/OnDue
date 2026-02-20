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
    @Published var showOverdueItems: Bool = false

    private var pendingUndoTask: Task<Void, Never>?
    private var pendingLearningTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var currentDigestRenderId: String = UUID().uuidString
    private var exposureKeysLogged: Set<String> = []
    private var firstExposureByObligationId: [String: Date] = [:]
    var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }
    
    // MARK: - Actions
    
    func loadDigest(using environment: AppEnvironment) async {
        self.environment = environment
        currentDigestRenderId = UUID().uuidString
        exposureKeysLogged = []
        firstExposureByObligationId = [:]
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
            let filtered = items.filter { Self.shouldIncludeForDigest($0.obligation, preferences: environment.filterPreferencesStore) }
            let visibilityFiltered = filtered.filter { item in
                if selectedLens == .active, showOverdueItems == false, item.dueBucket == .overdue {
                    return false
                }
                return true
            }
            sections = Self.buildSections(from: visibilityFiltered, grouping: selectedGrouping)
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
        Task { @MainActor [weak self] in
            self?.error = nil
        }
    }

    func logExposure(
        obligation: ObligationItem,
        state: ObligationLifecycleState,
        position: Int
    ) async {
        guard let environment else { return }
        let dedupeKey = "\(currentDigestRenderId)|\(obligation.id)"
        guard !exposureKeysLogged.contains(dedupeKey) else { return }
        exposureKeysLogged.insert(dedupeKey)

        let hypothesisClass = obligation.primaryHypothesisId ?? "unknown"
        let exposedAt = Date()
        let record = UserExposureEventRecord(
            mailboxAccountId: obligation.mailboxAccountId,
            obligationId: obligation.id,
            digestRenderId: currentDigestRenderId,
            hypothesisClass: hypothesisClass,
            projectionState: state.rawValue,
            digestPosition: position,
            exposedAt: exposedAt,
            policyVersion: obligation.policyVersion
        )
        do {
            let inserted = try await environment.userExposureEventRepository.logFirstExposure(record)
            if inserted {
                firstExposureByObligationId[obligation.id] = exposedAt
                try await environment.hypothesisMetricsRepository.increment(
                    mailboxAccountId: obligation.mailboxAccountId,
                    profile: .digest,
                    hypothesisIds: [hypothesisClass],
                    counter: "digestExposureCount"
                )
                if state == .needsReview {
                    try await environment.hypothesisMetricsRepository.increment(
                        mailboxAccountId: obligation.mailboxAccountId,
                        profile: .digest,
                        hypothesisIds: [hypothesisClass],
                        counter: "reviewCount"
                    )
                }
            }
        } catch {
            self.error = error
        }
    }
    
    func snooze(_ obligation: ObligationItem) async {
        guard let environment else { return }
        
        // Default snooze: 1 day from now
        let snoozeUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        
        do {
            let feedback = try await buildFeedbackRecord(
                obligation: obligation,
                action: .snoozed,
                reason: "snoozed",
                environment: environment
            )
            try await environment.obligationRepository.snooze(id: obligation.id, until: snoozeUntil)
            try await environment.feedbackRepository.save(feedback)
            try? await environment.hypothesisMetricsRepository.increment(
                mailboxAccountId: obligation.mailboxAccountId,
                profile: .digest,
                hypothesisIds: [obligation.primaryHypothesisId ?? "unknown"],
                counter: "reviewCount"
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
            let feedback = try await buildFeedbackRecord(
                obligation: obligation,
                action: .dismissed,
                reason: "dismissed",
                environment: environment
            )
            try await environment.feedbackRepository.save(feedback)
            try? await environment.hypothesisMetricsRepository.increment(
                mailboxAccountId: obligation.mailboxAccountId,
                profile: .digest,
                hypothesisIds: [obligation.primaryHypothesisId ?? "unknown"],
                counter: "digestDismissCount"
            )
            if isFastDismiss(obligationId: obligation.id, actionTimestamp: feedback.actionTimestamp) {
                try? await environment.hypothesisMetricsRepository.increment(
                    mailboxAccountId: obligation.mailboxAccountId,
                    profile: .digest,
                    hypothesisIds: [obligation.primaryHypothesisId ?? "unknown"],
                    counter: "fastDismissCount"
                )
            }
            if obligation.confidence >= 0.8 {
                try? await environment.hypothesisMetricsRepository.increment(
                    mailboxAccountId: obligation.mailboxAccountId,
                    profile: .digest,
                    hypothesisIds: [obligation.primaryHypothesisId ?? "unknown"],
                    counter: "postAcceptCorrectionCount"
                )
            }
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
            let feedback = try await buildFeedbackRecord(
                obligation: obligation,
                action: .accepted,
                reason: "confirmed",
                environment: environment
            )
            try await environment.feedbackRepository.save(feedback)
            try? await environment.hypothesisMetricsRepository.increment(
                mailboxAccountId: obligation.mailboxAccountId,
                profile: .digest,
                hypothesisIds: [obligation.primaryHypothesisId ?? "unknown"],
                counter: "acceptCount"
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
            let feedback = try await buildFeedbackRecord(
                obligation: obligation,
                action: .accepted,
                reason: "done",
                environment: environment
            )
            try await environment.feedbackRepository.save(feedback)
            try? await environment.hypothesisMetricsRepository.increment(
                mailboxAccountId: obligation.mailboxAccountId,
                profile: .digest,
                hypothesisIds: [obligation.primaryHypothesisId ?? "unknown"],
                counter: "acceptCount"
            )
            try await environment.obligationRepository.markDone(id: obligation.id)
            removeFromSections(obligation)
            scheduleUndo(for: obligation, action: .accepted)
            showLearningBanner()
        } catch {
            self.error = error
        }
    }

    func blockSender(_ obligation: ObligationItem, senderOverride: String? = nil) async {
        guard let environment else { return }
        do {
            let sender: String
            if let senderOverride, !senderOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sender = senderOverride
            } else if let message = try await environment.messageRepository.fetchByPk(obligation.messagePk) {
                sender = message.fromEmail
            } else {
                error = NSError(
                    domain: "OnDue.Digest",
                    code: 1001,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to resolve sender for this message."]
                )
                return
            }
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

    func blockDomain(_ obligation: ObligationItem, domainOverride: String? = nil) async {
        guard let environment else { return }
        do {
            let domain: String
            if let domainOverride, !domainOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                domain = domainOverride
            } else if let message = try await environment.messageRepository.fetchByPk(obligation.messagePk) {
                if let fromDomain = message.fromDomain, !fromDomain.isEmpty {
                    domain = fromDomain
                } else if let extracted = extractDomain(from: message.fromEmail) {
                    domain = extracted
                } else {
                    error = NSError(
                        domain: "OnDue.Digest",
                        code: 1002,
                        userInfo: [NSLocalizedDescriptionKey: "Unable to resolve domain for this message."]
                    )
                    return
                }
            } else {
                error = NSError(
                    domain: "OnDue.Digest",
                    code: 1002,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to resolve domain for this message."]
                )
                return
            }
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

    private func extractDomain(from email: String) -> String? {
        guard let atIndex = email.lastIndex(of: "@") else { return nil }
        let domain = String(email[email.index(after: atIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return domain.isEmpty ? nil : domain
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

        undoBanner = UndoBanner(
            message: action == .dismissed ? "Marked as not an obligation" : "Marked done",
            obligation: obligation,
            action: action
        )

        pendingUndoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            self?.undoBanner = nil
        }
    }

    func undoLastAction() async {
        guard let environment, let banner = undoBanner else { return }
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
        let orderedBuckets: [ObligationDueBucket] = [.today, .next3Days, .next7Days, .later, .noDueDate, .overdue]
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

    static func shouldIncludeForDigest(_ item: ObligationItem, preferences: FilterPreferencesStoring) -> Bool {
        evaluateDigestFilter(item, preferences: preferences).isIncluded
    }

    static func digestFilterExplain(_ item: ObligationItem, preferences: FilterPreferencesStoring) -> String {
        evaluateDigestFilter(item, preferences: preferences).debugMessage
    }

    private static func evaluateDigestFilter(
        _ item: ObligationItem,
        preferences: FilterPreferencesStoring
    ) -> (isIncluded: Bool, debugMessage: String) {
        let combined = ([item.title, item.evidenceQuote] + item.matchedReasons).joined(separator: " ").lowercased()
        let matchedRuleSet = Set(item.matchedRuleIds)
        let matchedReasonSet = Set(item.matchedReasons.map { $0.lowercased() })
        let reasonCode = item.reasonCode
        let isDeliveryAction = item.primaryHypothesisId == ObligationHypothesis.deliveryRequired.rawValue || reasonCode == .deliveryActionRequired

        if preferences.includeSecurityAlerts == false,
           (reasonCode == .securityInformational
                || combined.contains("password changed")
                || combined.contains("sign-in attempt")
                || combined.contains("security alert")) {
            return (false, "Excluded: security alerts disabled")
        }
        if preferences.includeStatements == false,
           (combined.contains("statement available") || combined.contains("monthly statement") || combined.contains("account statement")) {
            return (false, "Excluded: statements disabled")
        }
        if preferences.includeMarketing == false {
            let hasMarketingRule = matchedRuleSet.contains(ObligationHypothesis.marketingNoise.rawValue)
            let hasMarketingHypothesis = item.primaryHypothesisId == ObligationHypothesis.marketingNoise.rawValue
            let hasMarketingReason = matchedReasonSet.contains(where: {
                $0.contains("promotion") || $0.contains("marketing") || $0.contains("newsletter")
            })
            let hasMarketingReasonCode = reasonCode == .marketingPromo
            let hasMarketingKeywords = combined.contains("unsubscribe")
                || combined.contains("sale")
                || combined.contains("promo")
                || combined.contains("discount")
                || combined.contains("offer")
                || combined.contains("coupon")
                || combined.contains("shop now")
            if hasMarketingRule || hasMarketingHypothesis || hasMarketingReason || hasMarketingReasonCode || hasMarketingKeywords {
                return (false, "Excluded: marketing disabled")
            }
        }
        if preferences.includeNewsletters == false,
           (combined.contains("newsletter") || combined.contains("announcement") || combined.contains("roundup")) {
            return (false, "Excluded: newsletters disabled")
        }
        if preferences.includeShipping == false {
            if isDeliveryAction {
                return (true, "Included: delivery action override")
            }
            if combined.contains("out for delivery")
                || combined.contains("delivered")
                || combined.contains("tracking")
                || combined.contains("shipment")
                || combined.contains("package")
                || combined.contains("shipped") {
                return (false, "Excluded: shipping updates disabled")
            }
        }
        return (true, "Included: passes active filters")
    }

    private func buildFeedbackRecord(
        obligation: ObligationItem,
        action: FeedbackRecord.FeedbackAction,
        reason: String,
        environment: AppEnvironment
    ) async throws -> FeedbackRecord {
        let message = try await environment.messageRepository.fetchByPk(obligation.messagePk)
        guard let primaryHypothesisId = obligation.primaryHypothesisId,
              !primaryHypothesisId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(
                domain: "OnDue.Digest",
                code: 1201,
                userInfo: [NSLocalizedDescriptionKey: "Missing canonical primary hypothesis id."]
            )
        }
        let senderDomain = message?.fromDomain?.lowercased()
        let senderDomainClass: String
        if let senderDomain {
            if senderDomain.hasSuffix(".gov") || senderDomain.hasSuffix(".mil") {
                senderDomainClass = "government"
            } else if ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com"].contains(senderDomain) {
                senderDomainClass = "consumer"
            } else {
                senderDomainClass = "business"
            }
        } else {
            senderDomainClass = "unknown"
        }

        let labels = Set(
            (message?.labelIds ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        let labelCluster: String
        if labels.contains("category_promotions") || labels.contains("promotions") {
            labelCluster = "promotions"
        } else if labels.contains("category_social") || labels.contains("social") {
            labelCluster = "social"
        } else if labels.contains("inbox") {
            labelCluster = "inbox"
        } else {
            labelCluster = "other"
        }

        let subject = message?.subject.lowercased() ?? obligation.title.lowercased()
        let threadPattern = subject.hasPrefix("re:") || subject.hasPrefix("fwd:") ? "replyChain" : "newThread"
        let exposureTimestamp: Date?
        if let cached = firstExposureByObligationId[obligation.id] {
            exposureTimestamp = cached
        } else {
            exposureTimestamp = try? await environment.userExposureEventRepository.fetchFirstExposureTimestamp(
                mailboxAccountId: obligation.mailboxAccountId,
                obligationId: obligation.id
            )
        }

        return FeedbackRecord(
            mailboxAccountId: obligation.mailboxAccountId,
            messagePk: obligation.messagePk,
            obligationId: obligation.id,
            action: action,
            reason: reason,
            matchedRuleIds: obligation.matchedRuleIds.joined(separator: ","),
            primaryHypothesisId: primaryHypothesisId,
            senderDomainClass: senderDomainClass,
            labelCluster: labelCluster,
            threadPattern: threadPattern,
            exposureTimestamp: exposureTimestamp,
            actionTimestamp: Date()
        )
    }

    private func isFastDismiss(obligationId: String, actionTimestamp: Date?) -> Bool {
        guard let actionTimestamp,
              let exposure = firstExposureByObligationId[obligationId] else { return false }
        return actionTimestamp.timeIntervalSince(exposure) <= 120
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
