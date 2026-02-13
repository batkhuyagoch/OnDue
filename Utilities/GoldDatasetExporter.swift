import Foundation

struct GoldDatasetExportItem: Codable {
    let obligationId: String
    let messagePk: Int64
    let subject: String
    let snippet: String?
    let bodyText: String?
    let bodyHtml: String?
    let sender: String
    let senderDomain: String?
    let labelIds: [String]
    let internalDate: Date
    let normalizedText: String
    let currentDecision: ObligationDecision
    let rawDecision: String
    let currentConfidence: String
    let currentHypotheses: [String]
    let currentReasons: [String]
    var expectedOutcome: String?
    var expectedHypothesis: String?
    var expectedReason: String?
}

struct GoldDatasetExport: Codable {
    let generatedAt: Date
    let metadata: GoldDatasetMetadata
    let items: [GoldDatasetExportItem]
}

struct GoldDatasetMetadata: Codable {
    let editableFields: [String]
    let decisionValues: [String]
    let hypothesisValues: [String]
}

struct GoldDatasetExporter {
    static func export(environment: AppEnvironment) async throws -> URL {
        let items = try await buildObligationItems(environment: environment, limit: 2000)
        return try writeExport(items: items, filename: "obligation-gold-dataset.json")
    }

    static func exportNearMisses(environment: AppEnvironment, limit: Int = 100) async throws -> URL {
        let items = try await buildNearMissItems(environment: environment, limit: limit)
        return try writeExport(items: items, filename: "non-obligation-gold-dataset.json")
    }

    static func exportStratified(environment: AppEnvironment, total: Int = 200) async throws -> URL {
        let items = try await buildStratifiedItems(environment: environment, total: total)
        return try writeExport(items: items, filename: "gold-dataset-stratified.json")
    }

    static func buildObligationItems(environment: AppEnvironment, limit: Int) async throws -> [GoldDatasetExportItem] {
        let obligations = try await environment.obligationRepository.fetchTopDigest(limit: limit)
        let parser = EmailParser()
        let engine = RuleEngine(preferences: environment.filterPreferencesStore)

        var items: [GoldDatasetExportItem] = []
        for obligation in obligations {
            guard let message = try await environment.messageRepository.fetchByPk(obligation.messagePk) else { continue }
            let parsed = parser.parse(message: message)
            let assessment = engine.assess(email: parsed)
            let confidence = engine.confidenceLabel(for: parsed)

            let item = GoldDatasetExportItem(
                obligationId: obligation.id,
                messagePk: obligation.messagePk,
                subject: message.subject,
                snippet: message.snippet,
                bodyText: message.bodyText,
                bodyHtml: message.bodyHtml,
                sender: message.fromEmail,
                senderDomain: message.fromDomain,
                labelIds: parsed.labelIds,
                internalDate: message.internalDate,
                normalizedText: parsed.normalizedText,
                currentDecision: assessment.decision,
                rawDecision: assessment.decision.rawValue,
                currentConfidence: confidence,
                currentHypotheses: assessment.matchedRuleIds,
                currentReasons: assessment.matchedReasons,
                expectedOutcome: nil,
                expectedHypothesis: nil,
                expectedReason: nil
            )
            items.append(item)
        }
        return items
    }

    static func buildNearMissItems(environment: AppEnvironment, limit: Int) async throws -> [GoldDatasetExportItem] {
        let obligations = try await environment.obligationRepository.fetchTopDigest(limit: 5000)
        let obligationMessagePks = Set(obligations.map(\.messagePk))
        let accounts = try await environment.mailboxAccountRepository.fetchAll()

        let parser = EmailParser()
        let engine = RuleEngine(preferences: environment.filterPreferencesStore)

        var candidates: [(item: GoldDatasetExportItem, sortKey: Date)] = []
        for account in accounts {
            let recent = try await environment.messageRepository.fetchRecent(
                mailboxAccountId: account.id,
                daysBack: 180,
                limit: 2000
            )
            for message in recent {
                guard let pk = message.pk, !obligationMessagePks.contains(pk) else { continue }
                let parsed = parser.parse(message: message)
                let assessment = engine.assess(email: parsed)
                let confidence = engine.confidenceLabel(for: parsed)
                guard assessment.decision == .needsReview else { continue }

                let item = GoldDatasetExportItem(
                    obligationId: "",
                    messagePk: pk,
                    subject: message.subject,
                    snippet: message.snippet,
                    bodyText: message.bodyText,
                    bodyHtml: message.bodyHtml,
                    sender: message.fromEmail,
                    senderDomain: message.fromDomain,
                    labelIds: parsed.labelIds,
                    internalDate: message.internalDate,
                    normalizedText: parsed.normalizedText,
                    currentDecision: assessment.decision,
                    rawDecision: assessment.decision.rawValue,
                    currentConfidence: confidence,
                    currentHypotheses: assessment.matchedRuleIds,
                    currentReasons: assessment.matchedReasons,
                    expectedOutcome: nil,
                    expectedHypothesis: nil,
                    expectedReason: nil
                )
                candidates.append((item, message.internalDate))
            }
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.item.currentDecision != rhs.item.currentDecision {
                    return lhs.item.currentDecision == .needsReview
                }
                return lhs.sortKey > rhs.sortKey
            }
            .prefix(limit)
            .map(\.item)
    }

    static func buildStratifiedItems(environment: AppEnvironment, total: Int) async throws -> [GoldDatasetExportItem] {
        let accounts = try await environment.mailboxAccountRepository.fetchAll()
        let parser = EmailParser()
        let engine = RuleEngine(preferences: environment.filterPreferencesStore)

        var candidates: [GoldDatasetExportItem] = []
        for account in accounts {
            let recent = try await environment.messageRepository.fetchRecent(
                mailboxAccountId: account.id,
                daysBack: 365,
                limit: 3000
            )
            for message in recent {
                guard let pk = message.pk else { continue }
                let parsed = parser.parse(message: message)
                let assessment = engine.assess(email: parsed)
                let confidence = engine.confidenceLabel(for: parsed)
                let item = GoldDatasetExportItem(
                    obligationId: "",
                    messagePk: pk,
                    subject: message.subject,
                    snippet: message.snippet,
                    bodyText: message.bodyText,
                    bodyHtml: message.bodyHtml,
                    sender: message.fromEmail,
                    senderDomain: message.fromDomain,
                    labelIds: parsed.labelIds,
                    internalDate: message.internalDate,
                    normalizedText: parsed.normalizedText,
                    currentDecision: assessment.decision,
                    rawDecision: assessment.decision.rawValue,
                    currentConfidence: confidence,
                    currentHypotheses: assessment.matchedRuleIds,
                    currentReasons: assessment.matchedReasons,
                    expectedOutcome: nil,
                    expectedHypothesis: nil,
                    expectedReason: nil
                )
                candidates.append(item)
            }
        }

        let buckets = stratify(candidates: candidates)
        let targets = stratifiedTargets(total: total)

        var sampled: [GoldDatasetExportItem] = []
        sampled.append(contentsOf: sample(buckets.accept, count: targets.accept))
        sampled.append(contentsOf: sample(buckets.needsReview, count: targets.needsReview))
        sampled.append(contentsOf: sample(buckets.rejectMarketing, count: targets.rejectMarketing))
        sampled.append(contentsOf: sample(buckets.rejectOther, count: targets.rejectOther))

        return sampled.shuffled()
    }

    private static func writeExport(items: [GoldDatasetExportItem], filename: String) throws -> URL {
        let export = GoldDatasetExport(
            generatedAt: Date(),
            metadata: metadata(),
            items: items
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)

        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        Logger.info("Gold dataset exported to \(url.path)")
        return url
    }

    private static func metadata() -> GoldDatasetMetadata {
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

    private struct StratifiedBuckets {
        let accept: [GoldDatasetExportItem]
        let needsReview: [GoldDatasetExportItem]
        let rejectMarketing: [GoldDatasetExportItem]
        let rejectOther: [GoldDatasetExportItem]
    }

    private struct StratifiedTargets {
        let accept: Int
        let needsReview: Int
        let rejectMarketing: Int
        let rejectOther: Int
    }

    private static func stratify(candidates: [GoldDatasetExportItem]) -> StratifiedBuckets {
        let marketingLabels = ["category_promotions", "category_social", "promotions", "newsletter"]
        let accept = candidates.filter { $0.currentDecision == .accept }
        let needsReview = candidates.filter { $0.currentDecision == .needsReview }
        let reject = candidates.filter { $0.currentDecision == .reject }
        let rejectMarketing = reject.filter { item in
            item.labelIds.contains(where: { marketingLabels.contains($0) }) ||
            item.currentHypotheses.contains("marketingNoise")
        }
        let rejectOther = reject.filter { item in
            !rejectMarketing.contains(where: { $0.messagePk == item.messagePk })
        }
        return StratifiedBuckets(
            accept: accept,
            needsReview: needsReview,
            rejectMarketing: rejectMarketing,
            rejectOther: rejectOther
        )
    }

    private static func stratifiedTargets(total: Int) -> StratifiedTargets {
        let accept = Int(Double(total) * 0.3)
        let needsReview = Int(Double(total) * 0.2)
        let rejectMarketing = Int(Double(total) * 0.3)
        let rejectOther = max(0, total - accept - needsReview - rejectMarketing)
        return StratifiedTargets(
            accept: accept,
            needsReview: needsReview,
            rejectMarketing: rejectMarketing,
            rejectOther: rejectOther
        )
    }

    private static func sample(_ items: [GoldDatasetExportItem], count: Int) -> [GoldDatasetExportItem] {
        guard count > 0 else { return [] }
        return Array(items.shuffled().prefix(min(count, items.count)))
    }
}
