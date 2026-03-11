import XCTest
@testable import OnDue

final class ObligationProjectionRepositoryTests: XCTestCase {
    private var database: OnDue.Database!
    private var repository: ObligationProjectionRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: true)
        repository = ObligationProjectionRepository(database: database)
        try seedMailbox()
    }

    func testFetchItemsByModeMapsLifecycleIntoNowLaterDone() async throws {
        let nowOverdue = try seedObligation(
            providerMessageId: "now-overdue",
            title: "Past due payment",
            status: .open,
            confidence: 0.9,
            deadlineAt: Calendar.current.date(byAdding: .day, value: -1, to: Date())
        )
        let nowNeedsReview = try seedObligation(
            providerMessageId: "now-review",
            title: "Please verify your account",
            status: .open,
            confidence: 0.4,
            deadlineAt: nil
        )
        let laterUpcoming = try seedObligation(
            providerMessageId: "later-upcoming",
            title: "Renewal reminder next week",
            status: .open,
            confidence: 0.9,
            deadlineAt: Calendar.current.date(byAdding: .day, value: 8, to: Date())
        )
        let laterSnoozed = try seedObligation(
            providerMessageId: "later-snoozed",
            title: "Snoozed document upload",
            status: .snoozed,
            confidence: 0.9,
            deadlineAt: nil
        )
        let doneResolved = try seedObligation(
            providerMessageId: "done-resolved",
            title: "Completed obligation",
            status: .done,
            confidence: 0.9,
            deadlineAt: nil
        )

        let now = try await repository.fetchItems(mode: .now, query: "", limit: 100)
        let later = try await repository.fetchItems(mode: .later, query: "", limit: 100)
        let done = try await repository.fetchItems(mode: .done, query: "", limit: 100)

        XCTAssertTrue(now.contains(where: { $0.obligation.id == nowOverdue.id }))
        XCTAssertTrue(now.contains(where: { $0.obligation.id == nowNeedsReview.id }))
        XCTAssertFalse(now.contains(where: { $0.obligation.id == laterUpcoming.id }))
        XCTAssertFalse(now.contains(where: { $0.obligation.id == doneResolved.id }))

        XCTAssertTrue(later.contains(where: { $0.obligation.id == laterUpcoming.id }))
        XCTAssertTrue(later.contains(where: { $0.obligation.id == laterSnoozed.id }))
        XCTAssertFalse(later.contains(where: { $0.obligation.id == nowOverdue.id }))

        XCTAssertTrue(done.contains(where: { $0.obligation.id == doneResolved.id }))
        XCTAssertFalse(done.contains(where: { $0.obligation.id == nowNeedsReview.id }))
    }

    func testFetchItemsForGlobalSearchReturnsAllUserVisibleStates() async throws {
        let nowItem = try seedObligation(
            providerMessageId: "global-now",
            title: "Action needed now",
            status: .open,
            confidence: 0.4,
            deadlineAt: nil
        )
        let laterItem = try seedObligation(
            providerMessageId: "global-later",
            title: "Reminder for later",
            status: .snoozed,
            confidence: 0.9,
            deadlineAt: nil
        )
        let doneItem = try seedObligation(
            providerMessageId: "global-done",
            title: "Completed action",
            status: .done,
            confidence: 0.9,
            deadlineAt: nil
        )

        let items = try await repository.fetchItemsForGlobalSearch(query: "", limit: 200)

        XCTAssertTrue(items.contains(where: { $0.obligation.id == nowItem.id }))
        XCTAssertTrue(items.contains(where: { $0.obligation.id == laterItem.id }))
        XCTAssertTrue(items.contains(where: { $0.obligation.id == doneItem.id }))
    }

    private func seedMailbox() throws {
        try database.write { db in
            var mailbox = MailboxAccountRecord(
                id: "acct",
                provider: .gmail,
                emailAddress: "acct@example.com",
                createdAt: Date()
            )
            try mailbox.insert(db)
        }
    }

    private func seedObligation(
        providerMessageId: String,
        title: String,
        status: ObligationStatus,
        confidence: Double,
        deadlineAt: Date?
    ) throws -> ObligationRecord {
        try database.write { db in
            var message = MessageRecord(
                mailboxAccountId: "acct",
                providerMessageId: providerMessageId,
                threadId: "thread-\(providerMessageId)",
                internalDate: Date(),
                fromEmail: "alerts@example.com",
                fromDomain: "example.com",
                subject: title,
                snippet: title,
                bodyText: title,
                labelIds: "inbox"
            )
            try message.insert(db)
            guard let messagePk = message.pk else {
                throw NSError(domain: "ObligationProjectionRepositoryTests", code: 1)
            }

            var obligation = ObligationRecord(
                mailboxAccountId: "acct",
                messagePk: messagePk,
                status: status,
                category: .request,
                title: title,
                deadlineAt: deadlineAt,
                risk: .medium,
                whoOwes: .me,
                confidence: confidence,
                evidenceQuote: "evidence",
                obligationKey: "acct|example.com|\(providerMessageId)",
                score: confidence,
                matchedRuleIds: "userActionRequired",
                matchedSignalTypes: "keyword",
                matchedReasons: "Direct request without a deadline",
                primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
                reasonCode: ReasonCode.directRequestWithoutDeadline.rawValue,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue
            )
            try obligation.insert(db)
            try repository.upsert(obligation: obligation, in: db)
            return obligation
        }
    }
}
