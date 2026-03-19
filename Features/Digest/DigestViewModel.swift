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
    @Published var selectedMode: DigestMode = .now
    @Published var selectedLens: ObligationLens = .active
    @Published var selectedGrouping: ObligationGrouping = .dueDate
    @Published private(set) var isGlobalSearchActive = false

    private var pendingUndoTask: Task<Void, Never>?
    private var pendingLearningTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var currentDigestRenderId: String = UUID().uuidString
    private var activeLoadToken: UUID = UUID()
    private var exposureKeysLogged: Set<String> = []
    private var firstExposureByObligationId: [String: Date] = [:]
    var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }
    
    // MARK: - Actions
    
    func loadDigest(using environment: AppEnvironment) async {
        self.environment = environment
        let loadToken = UUID()
        activeLoadToken = loadToken
        currentDigestRenderId = UUID().uuidString
        exposureKeysLogged = []
        firstExposureByObligationId = [:]
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        do {
            let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let mode = selectedMode
            let grouping = selectedGrouping
            let filterSettings = DigestFilterSettings(from: environment.filterPreferencesStore)
            let useGlobalSearch = !trimmedQuery.isEmpty
            let items: [ObligationListItem]
            if useGlobalSearch {
                items = try await environment.obligationProjectionRepository.fetchItemsForGlobalSearch(query: trimmedQuery, limit: 500)
            } else {
                items = try await environment.obligationProjectionRepository.fetchItems(mode: mode, query: "", limit: 300)
            }
            let builtSections = await Self.buildSectionsInBackground(
                items: items,
                useGlobalSearch: useGlobalSearch,
                mode: mode,
                grouping: grouping,
                filterSettings: filterSettings
            )
            guard activeLoadToken == loadToken else { return }
            isGlobalSearchActive = useGlobalSearch
            sections = builtSections
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                // View/task cancellation during typing/navigation should not show user-facing errors.
                AppLog.debug(
                    "Digest.loadDigest.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                return
            }
            guard activeLoadToken == loadToken else { return }
            AppLog.error(
                "Digest.loadDigest.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            self.error = error
            sections = []
        }
        
    }

    func updateSearchQuery(_ query: String) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let environment = self.environment else { return }
            await self.loadDigest(using: environment)
        }
    }

    func clearError() {
        Task { @MainActor [weak self] in
            self?.error = nil
        }
    }

    func presentError(_ error: Error) {
        guard !AppErrorClassifier.shouldSuppressUserFacing(error) else {
            AppLog.debug(
                "Digest.presentError.suppressed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            return
        }
        AppLog.error(
            "Digest.presentError",
            fields: [
                "errorClass": AppErrorClassifier.classLabel(for: error),
                "error": error.localizedDescription
            ]
        )
        self.error = error
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
        } catch is CancellationError {
            return
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
            await loadDigest(using: environment)
        } catch is CancellationError {
            return
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
            scheduleUndo(for: obligation, action: .dismissed)
            await loadDigest(using: environment)
        } catch is CancellationError {
            return
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
            await loadDigest(using: environment)
        } catch is CancellationError {
            return
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
            scheduleUndo(for: obligation, action: .accepted)
            showLearningBanner()
            await loadDigest(using: environment)
        } catch is CancellationError {
            return
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
        } catch is CancellationError {
            return
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
        } catch is CancellationError {
            return
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
        } catch is CancellationError {
            return
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
    
    private nonisolated static func buildSections(
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

    private nonisolated static func buildModeSections(
        from items: [ObligationListItem],
        mode: DigestMode,
        grouping: ObligationGrouping
    ) -> [ObligationListSection] {
        let modeItems = items.filter { digestMode(for: $0) == mode }
        guard !modeItems.isEmpty else { return [] }

        if grouping == .dueDate {
            return buildDueDateSectionsForMode(modeItems, mode: mode)
        }

        return buildSections(from: modeItems, grouping: grouping)
    }

    private nonisolated static func buildDueDateSectionsForMode(
        _ items: [ObligationListItem],
        mode: DigestMode
    ) -> [ObligationListSection] {
        switch mode {
        case .now:
            var needsConfirmation: [ObligationListItem] = []
            var dueToday: [ObligationListItem] = []
            var dueSoon: [ObligationListItem] = []
            var overdue: [ObligationListItem] = []
            needsConfirmation.reserveCapacity(items.count / 3)
            dueToday.reserveCapacity(items.count / 3)
            dueSoon.reserveCapacity(items.count / 3)
            overdue.reserveCapacity(items.count / 3)

            for item in items {
                if item.state == .overdue || item.dueBucket == .overdue {
                    overdue.append(item)
                }
                if item.state == .needsReview {
                    needsConfirmation.append(item)
                }
                if item.state == .active && item.dueBucket == .today {
                    dueToday.append(item)
                }
                if item.state == .active && item.dueBucket == .next3Days {
                    dueSoon.append(item)
                }
            }
            return [
                section(title: "Need Confirmation", id: "now_review", items: sortItemsForDisplay(needsConfirmation)),
                section(title: "Due Today", id: "now_today", items: sortItemsForDisplay(dueToday)),
                section(title: "Due Soon", id: "now_due_soon", items: sortItemsForDisplay(dueSoon)),
                section(title: "Overdue", id: "now_overdue", items: sortItemsForDisplay(overdue))
            ].compactMap { $0 }
        case .later:
            var upcoming: [ObligationListItem] = []
            var snoozed: [ObligationListItem] = []
            upcoming.reserveCapacity(items.count / 2)
            snoozed.reserveCapacity(items.count / 4)

            for item in items {
                if item.state == .active && (item.dueBucket == .next7Days || item.dueBucket == .later || item.dueBucket == .noDueDate) {
                    upcoming.append(item)
                }
                if item.state == .snoozed {
                    snoozed.append(item)
                }
            }
            return [
                section(title: "Upcoming", id: "later_upcoming", items: sortItemsForDisplay(upcoming)),
                section(title: "Snoozed", id: "later_snoozed", items: sortItemsForDisplay(snoozed))
            ].compactMap { $0 }
        case .done:
            let now = Date()
            var recent: [ObligationListItem] = []
            var earlier: [ObligationListItem] = []
            recent.reserveCapacity(items.count / 4)
            earlier.reserveCapacity(items.count / 4)
            let recencyWindow: TimeInterval = 7 * 24 * 60 * 60

            for item in items where item.state == .resolved {
                if now.timeIntervalSince(item.obligation.updatedAt) <= recencyWindow {
                    recent.append(item)
                } else {
                    earlier.append(item)
                }
            }
            return [
                section(title: "Completed Recently", id: "done_recent", items: sortItemsForDisplay(recent)),
                section(title: "Completed Earlier", id: "done_earlier", items: sortItemsForDisplay(earlier))
            ].compactMap { $0 }
        }
    }

    private nonisolated static func sortItemsForDisplay(_ items: [ObligationListItem]) -> [ObligationListItem] {
        items.sorted { lhs, rhs in
            let lhsUrgency = urgencyRank(for: lhs.obligation)
            let rhsUrgency = urgencyRank(for: rhs.obligation)
            if lhsUrgency != rhsUrgency {
                return lhsUrgency < rhsUrgency
            }
            let lhsDeadline = lhs.obligation.deadline ?? .distantFuture
            let rhsDeadline = rhs.obligation.deadline ?? .distantFuture
            if lhsDeadline != rhsDeadline {
                return lhsDeadline < rhsDeadline
            }
            if lhs.obligation.confidence != rhs.obligation.confidence {
                return lhs.obligation.confidence > rhs.obligation.confidence
            }
            return lhs.obligation.updatedAt > rhs.obligation.updatedAt
        }
    }

    private nonisolated static func normalizedThreadSectionKey(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private nonisolated static func buildGlobalSearchSections(_ items: [ObligationListItem]) -> [ObligationListSection] {
        let sortedByModeThenUrgency = items.sorted { lhs, rhs in
            let leftMode = modeRank(for: lhs)
            let rightMode = modeRank(for: rhs)
            if leftMode != rightMode {
                return leftMode < rightMode
            }
            let lhsUrgency = urgencyRank(for: lhs.obligation)
            let rhsUrgency = urgencyRank(for: rhs.obligation)
            if lhsUrgency != rhsUrgency {
                return lhsUrgency < rhsUrgency
            }
            return lhs.obligation.confidence > rhs.obligation.confidence
        }
        var nowItems: [ObligationListItem] = []
        var laterItems: [ObligationListItem] = []
        var doneItems: [ObligationListItem] = []
        nowItems.reserveCapacity(sortedByModeThenUrgency.count / 3)
        laterItems.reserveCapacity(sortedByModeThenUrgency.count / 3)
        doneItems.reserveCapacity(sortedByModeThenUrgency.count / 3)

        for item in sortedByModeThenUrgency {
            switch digestMode(for: item) {
            case .now:
                nowItems.append(item)
            case .later:
                laterItems.append(item)
            case .done:
                doneItems.append(item)
            }
        }
        return [
            section(title: "Now", id: "search_now", items: nowItems),
            section(title: "Later", id: "search_later", items: laterItems),
            section(title: "Done", id: "search_done", items: doneItems)
        ].compactMap { $0 }
    }

    private nonisolated static func section(title: String, id: String, items: [ObligationListItem]) -> ObligationListSection? {
        guard !items.isEmpty else { return nil }
        return ObligationListSection(id: id, title: title, items: items)
    }

    private nonisolated static func digestMode(for item: ObligationListItem) -> DigestMode {
        switch item.state {
        case .resolved:
            return .done
        case .snoozed:
            return .later
        case .overdue, .needsReview:
            return .now
        case .active:
            if item.dueBucket == .today || item.dueBucket == .next3Days || item.dueBucket == .overdue {
                return .now
            }
            return .later
        case .suppressed:
            return .done
        }
    }

    private nonisolated static func modeRank(for item: ObligationListItem) -> Int {
        switch digestMode(for: item) {
        case .now: return 0
        case .later: return 1
        case .done: return 2
        }
    }

    private nonisolated static func buildDueDateSections(_ items: [ObligationListItem]) -> [ObligationListSection] {
        let grouped = Dictionary(grouping: items) { $0.dueBucket }
        let orderedBuckets: [ObligationDueBucket] = [.today, .next3Days, .next7Days, .later, .noDueDate, .overdue]
        return orderedBuckets.compactMap { bucket in
            guard let bucketItems = grouped[bucket], !bucketItems.isEmpty else { return nil }
            let sorted = sortItemsForDisplay(bucketItems)
            return ObligationListSection(
                id: bucket.rawValue,
                title: dueBucketTitle(for: bucket),
                items: sorted
            )
        }
    }

    private nonisolated static func buildDetectionSections(_ items: [ObligationListItem]) -> [ObligationListSection] {
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

    private nonisolated static func buildThreadSections(_ items: [ObligationListItem]) -> [ObligationListSection] {
        let grouped = Dictionary(grouping: items) { normalizedThreadSectionKey($0.primaryThreadId, fallback: $0.obligation.id) }
        var latestByKey: [String: Date] = [:]
        latestByKey.reserveCapacity(grouped.count)
        for (key, threadItems) in grouped {
            latestByKey[key] = threadItems.map { $0.lastActionAt ?? $0.obligation.updatedAt }.max() ?? .distantPast
        }
        let orderedKeys = grouped.keys.sorted { lhs, rhs in
            let lhsDate = latestByKey[lhs] ?? .distantPast
            let rhsDate = latestByKey[rhs] ?? .distantPast
            return lhsDate > rhsDate
        }

        return orderedKeys.compactMap { key in
            guard let threadItems = grouped[key], !threadItems.isEmpty else { return nil }
            let sorted = sortItemsForDisplay(threadItems)
            let title = "Thread (\(sorted.count))"
            return ObligationListSection(
                id: key,
                title: title,
                items: sorted
            )
        }
    }

    private nonisolated static func urgencyRank(for obligation: ObligationItem) -> Int {
        guard let deadline = obligation.deadline else { return 5 }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        if deadline < startOfToday { return 0 }
        if calendar.isDateInToday(deadline) { return 1 }
        let daysUntil = calendar.dateComponents([.day], from: now, to: deadline).day ?? 0
        if daysUntil <= 3 { return 2 }
        if daysUntil <= 7 { return 3 }
        return 4
    }

    private nonisolated static func dueBucketTitle(for bucket: ObligationDueBucket) -> String {
        switch bucket {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .next3Days: return "Next 3 Days"
        case .next7Days: return "Next 7 Days"
        case .later: return "Later"
        case .noDueDate: return "No Due Date"
        }
    }

    private nonisolated static func dateTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func shouldIncludeForDigest(_ item: ObligationItem, preferences: FilterPreferencesStoring) -> Bool {
        evaluateDigestFilter(
            item,
            settings: DigestFilterSettings(from: preferences)
        ).isIncluded
    }

    static func digestFilterExplain(_ item: ObligationItem, preferences: FilterPreferencesStoring) -> String {
        evaluateDigestFilter(
            item,
            settings: DigestFilterSettings(from: preferences)
        ).debugMessage
    }

    private nonisolated static func evaluateDigestFilter(
        _ item: ObligationItem,
        settings: DigestFilterSettings
    ) -> (isIncluded: Bool, debugMessage: String) {
        let combined = ([item.title, item.evidenceQuote] + item.matchedReasons).joined(separator: " ").lowercased()
        let matchedRuleSet = Set(item.matchedRuleIds)
        let matchedReasonSet = Set(item.matchedReasons.map { $0.lowercased() })
        let reasonCode = item.reasonCode
        let isDeliveryAction = item.primaryHypothesisId == ObligationHypothesis.deliveryRequired.rawValue || reasonCode == .deliveryActionRequired

        if settings.includeSecurityAlerts == false,
           (reasonCode == .securityInformational
                || combined.contains("password changed")
                || combined.contains("sign-in attempt")
                || combined.contains("security alert")) {
            return (false, "Excluded: security alerts disabled")
        }
        if settings.includeStatements == false,
           (combined.contains("statement available") || combined.contains("monthly statement") || combined.contains("account statement")) {
            return (false, "Excluded: statements disabled")
        }
        if settings.includeMarketing == false {
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
        if settings.includeNewsletters == false,
           (combined.contains("newsletter") || combined.contains("announcement") || combined.contains("roundup")) {
            return (false, "Excluded: newsletters disabled")
        }
        if settings.includeShipping == false {
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

    private nonisolated static func buildSectionsInBackground(
        items: [ObligationListItem],
        useGlobalSearch: Bool,
        mode: DigestMode,
        grouping: ObligationGrouping,
        filterSettings: DigestFilterSettings
    ) async -> [ObligationListSection] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let filtered = items.filter {
                    evaluateDigestFilter($0.obligation, settings: filterSettings).isIncluded
                }
                let sections: [ObligationListSection]
                if useGlobalSearch {
                    sections = buildGlobalSearchSections(filtered)
                } else {
                    sections = buildModeSections(from: filtered, mode: mode, grouping: grouping)
                }
                continuation.resume(returning: sections)
            }
        }
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

private struct DigestFilterSettings: Sendable {
    let includeSecurityAlerts: Bool
    let includeStatements: Bool
    let includeMarketing: Bool
    let includeNewsletters: Bool
    let includeShipping: Bool

    init(from preferences: FilterPreferencesStoring) {
        self.includeSecurityAlerts = preferences.includeSecurityAlerts
        self.includeStatements = preferences.includeStatements
        self.includeMarketing = preferences.includeMarketing
        self.includeNewsletters = preferences.includeNewsletters
        self.includeShipping = preferences.includeShipping
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
