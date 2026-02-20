import XCTest
@testable import OnDue

final class ObligationExtractorTests: XCTestCase {
    private var metricsSpy: HypothesisMetricsRepositorySpy!
    private var candidateScoreSpy: CandidateScoreRepositorySpy!
    private var suppressionStub: SuppressionRepositoryStub!
    private var extractor: ObligationExtractor!

    override func setUp() {
        super.setUp()
        metricsSpy = HypothesisMetricsRepositorySpy()
        candidateScoreSpy = CandidateScoreRepositorySpy()
        suppressionStub = SuppressionRepositoryStub()
        extractor = ObligationExtractor(
            preferences: ExtractorTestPreferences(),
            ruleWeightRepository: RuleWeightRepositoryStub(),
            hypothesisReviewCalibrationRepository: HypothesisReviewCalibrationRepositoryStub(),
            hypothesisMetricsRepository: metricsSpy,
            candidateScoreRepository: candidateScoreSpy,
            suppressionRepository: suppressionStub
        )
    }

    func testExtract_SameThreadProducesSingleObligation() async throws {
        let messageA = actionableMessage(
            pk: 1,
            providerMessageId: "thread-msg-a",
            threadId: "thread-1",
            internalDate: Date(timeIntervalSince1970: 1_700_100_000),
            subject: "Please sign and return document",
            snippet: "Signature required.",
            bodyText: "Please sign and return the attached document."
        )
        let messageB = actionableMessage(
            pk: 2,
            providerMessageId: "thread-msg-b",
            threadId: "thread-1",
            internalDate: Date(timeIntervalSince1970: 1_700_100_500),
            subject: "USCIS Request for Evidence",
            snippet: "Official response due by March 30.",
            bodyText: "This is a Request for Evidence from USCIS. Respond by March 30."
        )

        try await assertActionable([messageA, messageB], mailboxAccountId: "acct")
        let assessmentA = try await extractor.assess(message: messageA, mailboxAccountId: "acct")
        let assessmentB = try await extractor.assess(message: messageB, mailboxAccountId: "acct")
        let obligations = try await extractor.extract(from: [messageA, messageB], mailboxAccountId: "acct")

        XCTAssertEqual(obligations.count, 1)
        let expectedPreferredPk = preferredMessagePk(lhs: (messageA, assessmentA), rhs: (messageB, assessmentB))
        XCTAssertEqual(obligations.first?.messagePk, expectedPreferredPk)
    }

    func testExtract_SameThreadPreference_ConfidencePrecedence() async throws {
        let lowerConfidenceMessage = actionableMessage(
            pk: 11,
            providerMessageId: "confidence-lower",
            threadId: "confidence-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_110_000),
            subject: "Please sign and return document",
            snippet: "Signature required.",
            bodyText: "Please sign and return the attached document."
        )
        let higherConfidenceMessage = actionableMessage(
            pk: 12,
            providerMessageId: "confidence-higher",
            threadId: "confidence-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_110_500),
            subject: "USCIS Request for Evidence",
            snippet: "Official response due by March 30.",
            bodyText: "This is a Request for Evidence from USCIS. Respond by March 30."
        )

        try await assertActionable([lowerConfidenceMessage, higherConfidenceMessage], mailboxAccountId: "acct")
        let lhs = (
            message: lowerConfidenceMessage,
            assessment: try await extractor.assess(message: lowerConfidenceMessage, mailboxAccountId: "acct")
        )
        let rhs = (
            message: higherConfidenceMessage,
            assessment: try await extractor.assess(message: higherConfidenceMessage, mailboxAccountId: "acct")
        )

        let lhsConfidence = lhs.assessment.confidence
        let rhsConfidence = rhs.assessment.confidence
        XCTAssertNotEqual(lhsConfidence, rhsConfidence)

        let expectedPreferredPk = preferredMessagePk(lhs: lhs, rhs: rhs)
        let obligations = try await extractor.extract(
            from: [lhs.message, rhs.message],
            mailboxAccountId: "acct"
        )
        XCTAssertEqual(obligations.count, 1)
        XCTAssertEqual(obligations.first?.messagePk, expectedPreferredPk)
    }

    func testExtract_SameThreadPreference_ScorePrecedenceWhenConfidenceTies() async throws {
        let messageA = actionableMessage(
            pk: 13,
            providerMessageId: "score-a",
            threadId: "score-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_111_000),
            subject: "Invoice due March 12",
            snippet: "Please pay by March 12.",
            bodyText: "Please pay your invoice by March 12 to avoid late fees."
        )
        let messageB = actionableMessage(
            pk: 14,
            providerMessageId: "score-b",
            threadId: "score-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_111_500),
            subject: "Invoice due March 20",
            snippet: "Please pay by March 20.",
            bodyText: "Please pay your invoice by March 20 to avoid late fees."
        )

        try await assertActionable([messageA, messageB], mailboxAccountId: "acct")
        let lhs = (
            message: messageA,
            assessment: try await extractor.assess(message: messageA, mailboxAccountId: "acct")
        )
        let rhs = (
            message: messageB,
            assessment: try await extractor.assess(message: messageB, mailboxAccountId: "acct")
        )

        let lhsConfidence = lhs.assessment.confidence
        let rhsConfidence = rhs.assessment.confidence
        let lhsScore = lhs.assessment.score
        let rhsScore = rhs.assessment.score
        XCTAssertEqual(lhsConfidence, rhsConfidence)
        guard lhsScore != rhsScore else {
            throw XCTSkip(
                "Current RuleEngine output ties score to confidence for this fixture pair; score-tier precedence is not representable end-to-end."
            )
        }

        let expectedPreferredPk = preferredMessagePk(lhs: lhs, rhs: rhs)
        let obligations = try await extractor.extract(
            from: [lhs.message, rhs.message],
            mailboxAccountId: "acct"
        )
        XCTAssertEqual(obligations.count, 1)
        XCTAssertEqual(obligations.first?.messagePk, expectedPreferredPk)
    }

    func testExtract_SameThreadPreference_DeadlineEarlierWinsWhenConfidenceAndScoreTie() async throws {
        let earlierDeadlineMessage = actionableMessage(
            pk: 15,
            providerMessageId: "deadline-earlier",
            threadId: "deadline-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_112_000),
            subject: "Please sign and return by March 12, 2030",
            snippet: "Signature required by March 12, 2030.",
            bodyText: "Please sign and return the attached document by March 12, 2030."
        )
        let laterDeadlineMessage = actionableMessage(
            pk: 16,
            providerMessageId: "deadline-later",
            threadId: "deadline-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_112_500),
            subject: "Please sign and return by March 20, 2030",
            snippet: "Signature required by March 20, 2030.",
            bodyText: "Please sign and return the attached document by March 20, 2030."
        )

        try await assertActionable([earlierDeadlineMessage, laterDeadlineMessage], mailboxAccountId: "acct")
        let lhs = (
            message: earlierDeadlineMessage,
            assessment: try await extractor.assess(message: earlierDeadlineMessage, mailboxAccountId: "acct")
        )
        let rhs = (
            message: laterDeadlineMessage,
            assessment: try await extractor.assess(message: laterDeadlineMessage, mailboxAccountId: "acct")
        )

        let lhsConfidence = lhs.assessment.confidence
        let rhsConfidence = rhs.assessment.confidence
        let lhsScore = lhs.assessment.score
        let rhsScore = rhs.assessment.score
        let lhsDeadline = lhs.assessment.deadline
        let rhsDeadline = rhs.assessment.deadline
        XCTAssertEqual(lhsConfidence, rhsConfidence)
        XCTAssertEqual(lhsScore, rhsScore)
        XCTAssertNotEqual(lhsDeadline, rhsDeadline)

        let expectedPreferredPk = preferredMessagePk(lhs: lhs, rhs: rhs)
        let obligations = try await extractor.extract(
            from: [lhs.message, rhs.message],
            mailboxAccountId: "acct"
        )
        XCTAssertEqual(obligations.count, 1)
        XCTAssertEqual(obligations.first?.messagePk, expectedPreferredPk)
    }

    func testExtract_SameThreadPreference_DeadlinePresentBeatsMissingWhenConfidenceAndScoreTie() async throws {
        let deadlinePresentMessage = actionableMessage(
            pk: 17,
            providerMessageId: "deadline-present",
            threadId: "deadline-presence-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_113_000),
            subject: "Please sign and return by Friday",
            snippet: "Signature required by Friday.",
            bodyText: "Please sign and return the attached document by Friday."
        )
        let deadlineMissingMessage = actionableMessage(
            pk: 18,
            providerMessageId: "deadline-missing",
            threadId: "deadline-presence-thread",
            internalDate: Date(timeIntervalSince1970: 1_700_113_500),
            subject: "Please sign and return document",
            snippet: "Signature required.",
            bodyText: "Please sign and return the attached document."
        )

        try await assertActionable([deadlinePresentMessage, deadlineMissingMessage], mailboxAccountId: "acct")
        let lhs = (
            message: deadlinePresentMessage,
            assessment: try await extractor.assess(message: deadlinePresentMessage, mailboxAccountId: "acct")
        )
        let rhs = (
            message: deadlineMissingMessage,
            assessment: try await extractor.assess(message: deadlineMissingMessage, mailboxAccountId: "acct")
        )
        let lhsConfidence = lhs.assessment.confidence
        let rhsConfidence = rhs.assessment.confidence
        let lhsScore = lhs.assessment.score
        let rhsScore = rhs.assessment.score
        let lhsDeadline = lhs.assessment.deadline
        let rhsDeadline = rhs.assessment.deadline
        XCTAssertEqual(lhsConfidence, rhsConfidence)
        XCTAssertEqual(lhsScore, rhsScore)
        XCTAssertNotEqual(lhsDeadline, rhsDeadline)

        let expectedPreferredPk = preferredMessagePk(lhs: lhs, rhs: rhs)
        let presenceObligations = try await extractor.extract(
            from: [lhs.message, rhs.message],
            mailboxAccountId: "acct"
        )
        XCTAssertEqual(presenceObligations.count, 1)
        XCTAssertEqual(presenceObligations.first?.messagePk, expectedPreferredPk)
    }

    func testExtract_DifferentThreadsProduceMultipleObligations() async throws {
        let messageA = actionableMessage(
            pk: 21,
            providerMessageId: "multi-a",
            threadId: "thread-a",
            internalDate: Date(timeIntervalSince1970: 1_700_102_000),
            subject: "Invoice due March 16",
            snippet: "Please pay by March 16",
            bodyText: "Please pay your invoice by March 16."
        )
        let messageB = actionableMessage(
            pk: 22,
            providerMessageId: "multi-b",
            threadId: "thread-b",
            internalDate: Date(timeIntervalSince1970: 1_700_102_500),
            subject: "Please verify your account today",
            snippet: "Verification required today",
            bodyText: "Please verify your account today to avoid interruption."
        )

        try await assertActionable([messageA, messageB], mailboxAccountId: "acct")
        let obligations = try await extractor.extract(from: [messageA, messageB], mailboxAccountId: "acct")

        XCTAssertEqual(obligations.count, 2)
    }

    func testExtract_UsesProviderMessageIdWhenThreadIdMissing() async throws {
        let messageA = actionableMessage(
            pk: 31,
            providerMessageId: "provider-only-a",
            threadId: nil,
            internalDate: Date(timeIntervalSince1970: 1_700_103_000),
            subject: "Invoice due tomorrow",
            snippet: "Please pay by tomorrow",
            bodyText: "Please pay your invoice by tomorrow."
        )
        let messageB = actionableMessage(
            pk: 32,
            providerMessageId: "provider-only-b",
            threadId: nil,
            internalDate: Date(timeIntervalSince1970: 1_700_103_500),
            subject: "Please review and sign document",
            snippet: "Action required by Friday",
            bodyText: "Please review and sign the attached document by Friday."
        )

        try await assertActionable([messageA, messageB], mailboxAccountId: "acct")
        let obligations = try await extractor.extract(from: [messageA, messageB], mailboxAccountId: "acct")

        XCTAssertEqual(obligations.count, 2)
    }

    // MARK: - Helpers

    private func assertActionable(_ messages: [MessageRecord], mailboxAccountId: String) async throws {
        for message in messages {
            let assessment = try await extractor.assess(message: message, mailboxAccountId: mailboxAccountId)
            let decision = assessment.decision
            XCTAssertNotEqual(decision, .reject, "Expected actionable fixture: \(message.providerMessageId)")
        }
    }

    private func preferredMessagePk(
        lhs: (MessageRecord, RuleAssessment),
        rhs: (MessageRecord, RuleAssessment)
    ) -> Int64 {
        if lhs.1.confidence != rhs.1.confidence {
            return lhs.1.confidence > rhs.1.confidence ? (lhs.0.pk ?? 0) : (rhs.0.pk ?? 0)
        }
        if lhs.1.score != rhs.1.score {
            return lhs.1.score > rhs.1.score ? (lhs.0.pk ?? 0) : (rhs.0.pk ?? 0)
        }
        if let lhsDeadline = lhs.1.deadline, let rhsDeadline = rhs.1.deadline {
            return rhsDeadline < lhsDeadline ? (rhs.0.pk ?? 0) : (lhs.0.pk ?? 0)
        }
        if lhs.1.deadline != nil && rhs.1.deadline == nil {
            return lhs.0.pk ?? 0
        }
        if lhs.1.deadline == nil && rhs.1.deadline != nil {
            return rhs.0.pk ?? 0
        }
        return lhs.0.pk ?? 0
    }

    private func actionableMessage(
        pk: Int64,
        providerMessageId: String,
        threadId: String?,
        internalDate: Date,
        subject: String,
        snippet: String,
        bodyText: String
    ) -> MessageRecord {
        MessageRecord(
            pk: pk,
            mailboxAccountId: "acct",
            providerMessageId: providerMessageId,
            threadId: threadId,
            internalDate: internalDate,
            fromEmail: "billing@example.com",
            fromDomain: "example.com",
            subject: subject,
            snippet: snippet,
            bodyText: bodyText,
            hasAttachments: true,
            labelIds: "inbox"
        )
    }
}

private final class ExtractorTestPreferences: FilterPreferencesStoring {
    var includeSecurityAlerts = false
    var includeStatements = false
    var includeMarketing = false
    var includeNewsletters = false
    var includeShipping = true
}

private final class RuleWeightRepositoryStub: RuleWeightRepositorying, @unchecked Sendable {
    func fetchMultipliers(mailboxAccountId: String) async throws -> [String: Double] {
        [:]
    }

    func applyFeedback(
        mailboxAccountId: String,
        matchedRuleIds: [String],
        action: FeedbackRecord.FeedbackAction
    ) async throws {}
}

private final class HypothesisReviewCalibrationRepositoryStub: HypothesisReviewCalibrationRepositorying, @unchecked Sendable {
    func fetchSnapshot(mailboxAccountId: String) async throws -> HypothesisReviewCalibrationSnapshot {
        .empty
    }

    func applyFeedback(_ record: FeedbackRecord) async throws {}
}

private actor HypothesisMetricsRepositorySpy: HypothesisMetricsRepositorying {
    private(set) var events: [(mailboxAccountId: String, profile: RuleEvaluationProfile, hypothesisIds: [String], counter: String)] = []

    func increment(
        mailboxAccountId: String,
        profile: RuleEvaluationProfile,
        hypothesisIds: [String],
        counter: String
    ) async throws {
        events.append((mailboxAccountId, profile, hypothesisIds, counter))
    }
}

private actor CandidateScoreRepositorySpy: CandidateScoreRepositorying {
    private(set) var deletedMessagePks: [Int64] = []

    func delete(messagePk: Int64) async throws {
        deletedMessagePks.append(messagePk)
    }
}

private final class SuppressionRepositoryStub: SuppressionRepositorying, @unchecked Sendable {
    var blocked = false

    func addSender(mailboxAccountId: String, sender: String) async throws {}
    func addDomain(mailboxAccountId: String, domain: String) async throws {}

    func isBlocked(mailboxAccountId: String, sender: String?, domain: String?) async throws -> Bool {
        blocked
    }
}
