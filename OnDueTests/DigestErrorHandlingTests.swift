import XCTest
import GRDB
@testable import OnDue

@MainActor
final class DigestErrorHandlingTests: XCTestCase {
    func testPresentErrorSuppressesSwiftCancellationNSError() {
        let viewModel = DigestViewModel()
        let cancellation = NSError(domain: "Swift.CancellationError", code: 1)

        viewModel.presentError(cancellation)

        XCTAssertNil(viewModel.error)
    }

    func testPresentErrorStoresRealError() {
        let viewModel = DigestViewModel()
        let realError = NSError(domain: "OnDue.Tests", code: 42, userInfo: [NSLocalizedDescriptionKey: "Real failure"])

        viewModel.presentError(realError)

        XCTAssertNotNil(viewModel.error)
        XCTAssertEqual((viewModel.error as NSError?)?.domain, "OnDue.Tests")
        XCTAssertEqual((viewModel.error as NSError?)?.code, 42)
    }

    func testLoadDigestSuppressesCancellationFromProjectionRepository() async throws {
        let db = try Database(inMemory: true)
        let cancellation = NSError(domain: "Swift.CancellationError", code: 1)
        let projection = ProjectionRepoCancellationStub(errorToThrow: cancellation)
        let environment = try makeTestEnvironment(database: db, projectionRepository: projection)
        let viewModel = DigestViewModel()

        await viewModel.loadDigest(using: environment)

        XCTAssertNil(viewModel.error)
        XCTAssertTrue(viewModel.sections.isEmpty)
        XCTAssertFalse(viewModel.isLoading)
    }

    private func makeTestEnvironment(
        database: Database,
        projectionRepository: ObligationProjectionRepositorying
    ) throws -> AppEnvironment {
        let filterPreferencesStore = FilterPreferencesStore()
        let suppressionRepository = SuppressionRepository(database: database)
        let messageStateManager = MessageStateManager(database: database)
        let ruleWeightRepository = RuleWeightRepository(database: database)
        let hypothesisReviewCalibrationRepository = HypothesisReviewCalibrationRepository(database: database)
        let hypothesisMetricsRepository = HypothesisMetricsRepository(database: database)
        let candidateScoreRepository = CandidateScoreRepository(database: database)
        let userExposureEventRepository = UserExposureEventRepository(database: database)
        let policyDiffArtifactRepository = PolicyDiffArtifactRepository(database: database)
        let feedbackRepository = FeedbackRepository(
            database: database,
            hypothesisReviewCalibrationRepository: hypothesisReviewCalibrationRepository,
            userExposureEventRepository: userExposureEventRepository
        )
        let messageRepository = MessageRepository(database: database)
        let mailboxAccountRepository = MailboxAccountRepository(database: database)
        let obligationRepository = ObligationRepository(database: database, projectionRepository: projectionRepository)
        let yearScanRepository = YearScanRepository(database: database)
        let syncPolicyStore = SyncPolicyStore()
        let gmailSyncService = GmailSyncServiceStub()
        let gmailSyncCoordinator = GmailSyncCoordinatorStub()
        let gmailAuthService = GmailAuthServiceStub()
        let obligationExtractor = ObligationExtractorStub()

        return AppEnvironment(
            database: database,
            gmailAuthService: gmailAuthService,
            gmailSyncService: gmailSyncService,
            gmailSyncCoordinator: gmailSyncCoordinator,
            syncPolicyStore: syncPolicyStore,
            filterPreferencesStore: filterPreferencesStore,
            obligationExtractor: obligationExtractor,
            obligationRepository: obligationRepository,
            obligationProjectionRepository: projectionRepository,
            messageRepository: messageRepository,
            mailboxAccountRepository: mailboxAccountRepository,
            feedbackRepository: feedbackRepository,
            hypothesisReviewCalibrationRepository: hypothesisReviewCalibrationRepository,
            hypothesisMetricsRepository: hypothesisMetricsRepository,
            userExposureEventRepository: userExposureEventRepository,
            policyDiffArtifactRepository: policyDiffArtifactRepository,
            ruleWeightRepository: ruleWeightRepository,
            candidateScoreRepository: candidateScoreRepository,
            yearScanRepository: yearScanRepository,
            suppressionRepository: suppressionRepository,
            messageStateManager: messageStateManager
        )
    }
}

private final class ProjectionRepoCancellationStub: ObligationProjectionRepositorying {
    let errorToThrow: Error

    init(errorToThrow: Error) {
        self.errorToThrow = errorToThrow
    }

    func fetchItems(lens: ObligationLens, query: String, limit: Int) async throws -> [ObligationListItem] {
        throw errorToThrow
    }

    func fetchItems(mode: DigestMode, query: String, limit: Int) async throws -> [ObligationListItem] {
        throw errorToThrow
    }

    func fetchItemsForGlobalSearch(query: String, limit: Int) async throws -> [ObligationListItem] {
        throw errorToThrow
    }

    func upsert(obligation: ObligationRecord, in db: GRDB.Database) throws {}

    func upsert(
        obligation: ObligationRecord,
        in db: GRDB.Database,
        precomputedPrimaryThreadId: String?
    ) throws {}
}

private final class GmailAuthServiceStub: GmailAuthServicing, @unchecked Sendable {
    func authorize() async throws {}
    func restorePreviousSignIn() async throws -> Bool { true }
    func signOut() {}
    var isSignedIn: Bool { true }
    var userEmail: String? { "test@example.com" }
    var accessToken: String? { nil }
}

private final class GmailSyncServiceStub: GmailSyncServicing, @unchecked Sendable {
    func initialSync(mailboxAccountId: String, daysBack: Int) async throws -> GmailSyncResult {
        GmailSyncResult(messageIDsCount: 0, messagesSavedCount: 0)
    }
    func initialSync(mailboxAccountId: String, startDate: Date, endDate: Date) async throws -> GmailSyncResult {
        GmailSyncResult(messageIDsCount: 0, messagesSavedCount: 0)
    }
    func incrementalSync(mailboxAccountId: String, startHistoryId: String) async throws -> GmailIncrementalSyncResult {
        GmailIncrementalSyncResult(messageIDsCount: 0, messagesSavedCount: 0, latestHistoryId: nil, changedMessageIDs: [])
    }
    func fetchCurrentHistoryId() async throws -> String { "0" }
}

private final class GmailSyncCoordinatorStub: GmailSyncCoordinating, @unchecked Sendable {
    func sync(mailboxAccountId: String, daysBack: Int, forceFullSync: Bool) async throws -> SyncReport {
        SyncReport(messageIDsCount: 0, messagesSavedCount: 0, obligationsCount: 0, deletedOldMessagesCount: 0)
    }
    func backfill(mailboxAccountId: String, startDate: Date, endDate: Date, daysBackForExtraction: Int) async throws -> SyncReport {
        SyncReport(messageIDsCount: 0, messagesSavedCount: 0, obligationsCount: 0, deletedOldMessagesCount: 0)
    }
    func resetLocalCache(mailboxAccountId: String) async throws -> Int { 0 }
    func deleteAllAccountData(mailboxAccountId: String) async throws {}
}

private final class ObligationExtractorStub: ObligationExtracting, @unchecked Sendable {
    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord] { [] }
    func assess(message: MessageRecord, mailboxAccountId: String) async throws -> RuleAssessment {
        throw NSError(domain: "OnDue.Tests", code: -1)
    }
    func makeObligation(from assessment: RuleAssessment, message: MessageRecord, mailboxAccountId: String, messagePk: Int64, email: ParsedEmail? = nil) -> ObligationRecord {
        ObligationRecord(
            mailboxAccountId: mailboxAccountId,
            messagePk: messagePk,
            category: .other,
            title: message.subject,
            evidenceQuote: "",
            obligationKey: "\(mailboxAccountId)|test|stub"
        )
    }
    func scanYear(messages: [MessageRecord], mailboxAccountId: String) async throws -> [YearScanItem] { [] }
}
