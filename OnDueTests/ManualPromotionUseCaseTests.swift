import XCTest
@testable import OnDue

final class ManualPromotionUseCaseTests: XCTestCase {
    func testPromoteThrowsWhenMessageNotFound() async throws {
        let messageRepo = MessageRepositoryStub()
        messageRepo.message = nil
        let extractor = ObligationExtractorStub()
        let obligationRepo = ObligationRepositorySpy()
        let useCase = ManualPromotionUseCase(
            messageRepository: messageRepo,
            obligationExtractor: extractor,
            obligationRepository: obligationRepo
        )

        await XCTAssertThrowsErrorAsync(
            try await useCase.promote(messageId: "missing", mailboxAccountId: "acct")
        ) { error in
            XCTAssertEqual(error as? ManualPromotionError, .messageNotFound)
        }
    }

    func testPromoteThrowsWhenMessageIsMissingPk() async throws {
        let messageRepo = MessageRepositoryStub()
        messageRepo.message = MessageRecord(
            pk: nil,
            mailboxAccountId: "acct",
            providerMessageId: "provider-1",
            internalDate: Date(),
            fromEmail: "billing@example.com",
            fromDomain: "example.com",
            subject: "Invoice due",
            snippet: "Please pay",
            bodyText: "Please pay now",
            labelIds: "inbox"
        )
        let extractor = ObligationExtractorStub()
        let obligationRepo = ObligationRepositorySpy()
        let useCase = ManualPromotionUseCase(
            messageRepository: messageRepo,
            obligationExtractor: extractor,
            obligationRepository: obligationRepo
        )

        await XCTAssertThrowsErrorAsync(
            try await useCase.promote(messageId: "provider-1", mailboxAccountId: "acct")
        ) { error in
            XCTAssertEqual(error as? ManualPromotionError, .messageMissingPk)
        }
    }

    func testPromoteUsesInjectedMailboxAccountId() async throws {
        let messageRepo = MessageRepositoryStub()
        let message = MessageRecord(
            pk: 44,
            mailboxAccountId: "sourceAcct",
            providerMessageId: "provider-44",
            internalDate: Date(timeIntervalSince1970: 1_700_000_000),
            fromEmail: "billing@example.com",
            fromDomain: "example.com",
            subject: "Invoice due",
            snippet: "Please pay",
            bodyText: "Please pay now",
            labelIds: "inbox"
        )
        messageRepo.message = message

        let extractor = ObligationExtractorStub()
        extractor.assessment = makeAssessment()

        let obligationRepo = ObligationRepositorySpy()
        let expectedItem = ObligationItem(
            record: ObligationRecord(
                mailboxAccountId: "targetAcct",
                messagePk: 44,
                category: .request,
                title: "Invoice due",
                deadlineAt: nil,
                risk: .medium,
                whoOwes: .me,
                confidence: 0.9,
                evidenceQuote: "Please pay now",
                obligationKey: "targetAcct|example.com|useractionrequired",
                score: 2.0,
                matchedRuleIds: "userActionRequired",
                matchedSignalTypes: "keyword",
                matchedReasons: "Direct request with a clear deadline",
                primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
                reasonCode: ReasonCode.directRequestWithDeadline.rawValue,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue
            )
        )
        obligationRepo.promoteResult = expectedItem

        let useCase = ManualPromotionUseCase(
            messageRepository: messageRepo,
            obligationExtractor: extractor,
            obligationRepository: obligationRepo
        )

        let item = try await useCase.promote(messageId: "provider-44", mailboxAccountId: "targetAcct")
        XCTAssertEqual(item.mailboxAccountId, "targetAcct")
        XCTAssertEqual(extractor.lastMailboxAccountId, "targetAcct")
        XCTAssertEqual(await obligationRepo.capturedMailboxAccountId(), "targetAcct")
        XCTAssertEqual(await obligationRepo.capturedMessageProviderId(), "provider-44")
    }

    private func makeAssessment() -> RuleAssessment {
        RuleAssessment(
            decision: .accept,
            score: 1.2,
            category: .request,
            risk: .medium,
            confidence: 0.7,
            evidenceQuote: "Please pay now",
            deadline: nil,
            matchedSignalIds: ["request_keyword"],
            matchedRuleIds: [ObligationHypothesis.userActionRequired.rawValue],
            matchedSignalTypes: [.keyword],
            matchedReasons: ["Direct request with a clear deadline"],
            hypothesisResults: [],
            decisionContract: DecisionContract(
                outcome: .accept,
                primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
                reasonCode: .directRequestWithDeadline,
                reasonText: "Direct request with a clear deadline",
                evidence: ["request_keyword"],
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue
            )
        )
    }
}

private final class MessageRepositoryStub: MessageRepositorying, @unchecked Sendable {
    var message: MessageRecord?

    func save(_ messages: [MessageRecord]) async throws {}
    func fetchRecent(mailboxAccountId: String, daysBack: Int) async throws -> [MessageRecord] { [] }
    func fetchRecent(mailboxAccountId: String, daysBack: Int, limit: Int) async throws -> [MessageRecord] { [] }
    func fetchRecentPage(
        mailboxAccountId: String,
        daysBack: Int,
        beforeDate: Date?,
        beforePk: Int64?,
        limit: Int
    ) async throws -> [MessageRecord] { [] }
    func fetchByPk(_ pk: Int64) async throws -> MessageRecord? { nil }
    func fetchByProviderMessageId(_ providerMessageId: String) async throws -> MessageRecord? { message }
    func fetchByProviderMessageIds(mailboxAccountId: String, providerMessageIds: Set<String>) async throws -> [MessageRecord] {
        guard let message, providerMessageIds.contains(message.providerMessageId) else { return [] }
        return [message]
    }
    func fetchProviderMessageIdsWithBodyText(mailboxAccountId: String, providerMessageIds: [String]) async throws -> Set<String> { [] }
    func fetchProviderMessageIdsWithBody(mailboxAccountId: String, providerMessageIds: Set<String>) async throws -> Set<String> { [] }
    func search(query: String, mailboxAccountId: String, limit: Int) async throws -> [MessageRecord] { [] }
    func softDeleteOlderThan(mailboxAccountId: String, daysBack: Int) async throws -> Int { 0 }
    func deleteAll(for mailboxAccountId: String) async throws -> Int { 0 }
}

private final class ObligationExtractorStub: ObligationExtracting, @unchecked Sendable {
    var assessment: RuleAssessment = RuleAssessment(
        decision: .accept,
        score: 1.0,
        category: .request,
        risk: .medium,
        confidence: 0.8,
        evidenceQuote: "",
        deadline: nil,
        matchedSignalIds: [],
        matchedRuleIds: [ObligationHypothesis.userActionRequired.rawValue],
        matchedSignalTypes: [],
        matchedReasons: [],
        hypothesisResults: [],
        decisionContract: DecisionContract(
            outcome: .accept,
            primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
            reasonCode: .directRequestWithDeadline,
            reasonText: "",
            evidence: [],
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue
        )
    )
    var lastMailboxAccountId: String?

    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord] { [] }
    func assess(message: MessageRecord, mailboxAccountId: String) async throws -> RuleAssessment {
        lastMailboxAccountId = mailboxAccountId
        return assessment
    }
    func makeObligation(from assessment: RuleAssessment, message: MessageRecord, mailboxAccountId: String, messagePk: Int64) -> ObligationRecord {
        ObligationRecord(
            mailboxAccountId: mailboxAccountId,
            messagePk: messagePk,
            category: assessment.category,
            title: message.subject,
            deadlineAt: assessment.deadline,
            risk: assessment.risk,
            whoOwes: .me,
            confidence: assessment.confidence,
            evidenceQuote: assessment.evidenceQuote,
            obligationKey: "\(mailboxAccountId)|example.com|\(assessment.matchedRuleIds.joined(separator: "|"))"
        )
    }
    func scanYear(messages: [MessageRecord], mailboxAccountId: String) async throws -> [YearScanItem] { [] }
}

private actor ObligationRepositorySpy: ObligationRepositorying {
    var promoteResult = ObligationItem(
        record: ObligationRecord(
            mailboxAccountId: "acct",
            messagePk: 1,
            category: .request,
            title: "stub",
            deadlineAt: nil,
            risk: .medium,
            whoOwes: .me,
            confidence: 0.9,
            evidenceQuote: "stub",
            obligationKey: "acct|example.com|stub",
            score: 2.0,
            matchedRuleIds: "userActionRequired",
            matchedSignalTypes: "keyword",
            matchedReasons: "stub",
            primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
            reasonCode: ReasonCode.directRequestWithDeadline.rawValue,
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue
        )
    )
    var lastMessage: MessageRecord?
    var lastMailboxAccountId: String?

    func fetchTopDigest(limit: Int) async throws -> [ObligationItem] { [] }
    func fetchDigest(query: String, limit: Int) async throws -> [ObligationItem] { [] }
    func save(_ record: ObligationRecord) async throws {}
    func save(_ records: [ObligationRecord]) async throws {}
    func updateStatus(id: String, status: ObligationStatus) async throws {}
    func markReviewed(id: String) async throws {}
    func snooze(id: String, until: Date) async throws {}
    func dismiss(id: String) async throws {}
    func markDone(id: String) async throws {}
    func dismissBySender(mailboxAccountId: String, sender: String) async throws {}
    func dismissByDomain(mailboxAccountId: String, domain: String) async throws {}
    func promoteManually(
        message: MessageRecord,
        mailboxAccountId: String,
        assessment: RuleAssessment
    ) async throws -> ObligationItem {
        lastMessage = message
        lastMailboxAccountId = mailboxAccountId
        return promoteResult
    }

    func capturedMailboxAccountId() -> String? { lastMailboxAccountId }
    func capturedMessageProviderId() -> String? { lastMessage?.providerMessageId }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Any,
    _ handler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown")
    } catch {
        handler(error)
    }
}
