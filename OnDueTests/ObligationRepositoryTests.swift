import XCTest
import GRDB
@testable import OnDue

final class ObligationRepositoryTests: XCTestCase {
    private var database: OnDue.Database!
    private var repository: ObligationRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        database = try Database(inMemory: true)
        repository = ObligationRepository(database: database)
        try seedMailbox()
    }

    func testSaveRecords_DoesNotInsertDuplicateForSameObligationKey() async throws {
        let key = "acct|example.com|useractionrequired"
        let firstPk = try seedMessage(providerMessageId: "provider_1")
        let secondPk = try seedMessage(providerMessageId: "provider_2")
        let records = [
            makeRecord(messagePk: firstPk, obligationKey: key, score: 0.62),
            makeRecord(messagePk: secondPk, obligationKey: key, score: 0.91)
        ]

        try await repository.save(records)

        let stored = try fetchRecords(for: key)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.repeatCount, 2)
    }

    func testSaveRecords_SameObligationKeyAcrossReruns_IncrementsRepeatCount() async throws {
        let key = "acct|example.com|repeat"
        let firstPk = try seedMessage(providerMessageId: "repeat_1")
        try await repository.save([makeRecord(messagePk: firstPk, obligationKey: key)])

        let secondPk = try seedMessage(providerMessageId: "repeat_2")
        try await repository.save([makeRecord(messagePk: secondPk, obligationKey: key)])
        XCTAssertEqual(try fetchSingle(for: key)?.repeatCount, 2)

        let thirdPk = try seedMessage(providerMessageId: "repeat_3")
        let fourthPk = try seedMessage(providerMessageId: "repeat_4")
        try await repository.save([
            makeRecord(messagePk: thirdPk, obligationKey: key),
            makeRecord(messagePk: fourthPk, obligationKey: key)
        ])
        XCTAssertEqual(try fetchSingle(for: key)?.repeatCount, 4)
    }

    func testSaveRecords_PreservesCreatedAt_WhenMergingExistingKey() async throws {
        let key = "acct|example.com|createdAt"
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = oldDate.addingTimeInterval(7_200)

        let firstPk = try seedMessage(providerMessageId: "created_1")
        try await repository.save([
            makeRecord(messagePk: firstPk, obligationKey: key, createdAt: oldDate, updatedAt: oldDate)
        ])

        let secondPk = try seedMessage(providerMessageId: "created_2")
        try await repository.save([
            makeRecord(messagePk: secondPk, obligationKey: key, createdAt: newerDate, updatedAt: newerDate)
        ])

        let merged = try fetchSingle(for: key)
        XCTAssertEqual(merged?.createdAt, oldDate)
        XCTAssertNotEqual(merged?.updatedAt, oldDate)
    }

    func testSaveRecords_MergesLastSeenAt_WithMaxTimestamp() async throws {
        let key = "acct|example.com|lastSeen"
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_300)
        let t3 = Date(timeIntervalSince1970: 1_700_000_500)

        let firstPk = try seedMessage(providerMessageId: "seen_1", internalDate: t1)
        try await repository.save([
            makeRecord(messagePk: firstPk, obligationKey: key, lastSeenAt: t1)
        ])

        let secondPk = try seedMessage(providerMessageId: "seen_2", internalDate: t2)
        let thirdPk = try seedMessage(providerMessageId: "seen_3", internalDate: t3)
        try await repository.save([
            makeRecord(messagePk: secondPk, obligationKey: key, lastSeenAt: t2),
            makeRecord(messagePk: thirdPk, obligationKey: key, lastSeenAt: t3)
        ])

        XCTAssertEqual(try fetchSingle(for: key)?.lastSeenAt, t3)
    }

    func testSaveRecords_SameBatchSameKey_UsesBestRecordAndAggregatesRepeatCount() async throws {
        let key = "acct|example.com|bestRecord"
        let baseDate = Date(timeIntervalSince1970: 1_700_010_000)

        let lowPk = try seedMessage(providerMessageId: "best_low")
        let earlyPk = try seedMessage(providerMessageId: "best_early")
        let latePk = try seedMessage(providerMessageId: "best_late")

        let low = makeRecord(
            messagePk: lowPk,
            obligationKey: key,
            score: 0.40,
            deadlineAt: baseDate.addingTimeInterval(86_400)
        )
        let earlyBest = makeRecord(
            messagePk: earlyPk,
            obligationKey: key,
            score: 0.95,
            deadlineAt: baseDate.addingTimeInterval(3_600)
        )
        let lateBestTie = makeRecord(
            messagePk: latePk,
            obligationKey: key,
            score: 0.95,
            deadlineAt: baseDate.addingTimeInterval(172_800)
        )

        try await repository.save([low, lateBestTie, earlyBest])

        guard let merged = try fetchSingle(for: key) else {
            return XCTFail("Expected merged obligation for key \(key)")
        }
        XCTAssertEqual(merged.messagePk, earlyPk)
        XCTAssertEqual(merged.repeatCount, 3)
    }

    func testSaveRecords_PreservesUserDismissedStatusOnRerun() async throws {
        let key = "acct|example.com|preserve-dismissed"
        let firstPk = try seedMessage(providerMessageId: "dismiss_keep_1")
        try await repository.save([makeRecord(messagePk: firstPk, obligationKey: key)])

        guard let existing = try fetchSingle(for: key) else {
            return XCTFail("Expected existing obligation")
        }
        try await repository.updateStatus(id: existing.id, status: .dismissed)

        let secondPk = try seedMessage(providerMessageId: "dismiss_keep_2")
        try await repository.save([makeRecord(messagePk: secondPk, obligationKey: key, score: 0.99)])

        let merged = try fetchSingle(for: key)
        XCTAssertEqual(merged?.status, .dismissed)
        XCTAssertEqual(merged?.repeatCount, 2)
    }

    // MARK: - Helpers

    private func seedMailbox(mailboxAccountId: String = "acct") throws {
        try database.write { db in
            let mailbox = MailboxAccountRecord(
                id: mailboxAccountId,
                provider: .gmail,
                emailAddress: "acct@example.com",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try mailbox.insert(db)
        }
    }

    private func seedMessage(
        mailboxAccountId: String = "acct",
        providerMessageId: String,
        internalDate: Date = Date(),
        threadId: String? = nil
    ) throws -> Int64 {
        try database.write { db in
            var message = MessageRecord(
                mailboxAccountId: mailboxAccountId,
                providerMessageId: providerMessageId,
                threadId: threadId,
                internalDate: internalDate,
                fromEmail: "billing@example.com",
                fromDomain: "example.com",
                subject: "Invoice due tomorrow",
                snippet: "Please pay by tomorrow.",
                bodyText: "Please pay your invoice by tomorrow.",
                labelIds: "inbox"
            )
            try message.insert(db)
            guard let pk = message.pk else {
                throw NSError(
                    domain: "ObligationRepositoryTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected auto-generated message PK"]
                )
            }
            return pk
        }
    }

    private func makeRecord(
        messagePk: Int64,
        obligationKey: String,
        score: Double = 0.7,
        deadlineAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastSeenAt: Date? = nil
    ) -> ObligationRecord {
        ObligationRecord(
            mailboxAccountId: "acct",
            messagePk: messagePk,
            category: .request,
            title: "Please complete payment",
            deadlineAt: deadlineAt,
            risk: .medium,
            whoOwes: .me,
            confidence: 0.85,
            evidenceQuote: "Please complete payment by tomorrow.",
            obligationKey: obligationKey,
            score: score,
            matchedRuleIds: "userActionRequired",
            matchedSignalTypes: "keyword,date",
            matchedReasons: "Direct request with a clear deadline",
            primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
            reasonCode: ReasonCode.directRequestWithDeadline.rawValue,
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
            repeatCount: 1,
            lastSeenAt: lastSeenAt,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private func fetchSingle(for obligationKey: String) throws -> ObligationRecord? {
        try database.read { db in
            try ObligationRecord
                .filter(Column("mailboxAccountId") == "acct")
                .filter(Column("obligationKey") == obligationKey)
                .fetchOne(db)
        }
    }

    private func fetchRecords(for obligationKey: String) throws -> [ObligationRecord] {
        try database.read { db in
            try ObligationRecord
                .filter(Column("mailboxAccountId") == "acct")
                .filter(Column("obligationKey") == obligationKey)
                .fetchAll(db)
        }
    }
}
