import SwiftUI
import Combine

struct AppEnvironment {
    let database: Database
    let gmailAuthService: GmailAuthServicing
    let gmailSyncService: GmailSyncServicing
    let gmailSyncCoordinator: GmailSyncCoordinating
    let syncPolicyStore: SyncPolicyStore
    let filterPreferencesStore: FilterPreferencesStore
    let obligationExtractor: ObligationExtracting
    let obligationRepository: ObligationRepositorying
    let obligationProjectionRepository: ObligationProjectionRepositorying
    let messageRepository: MessageRepositorying
    let mailboxAccountRepository: MailboxAccountRepositorying
    let feedbackRepository: FeedbackRepositorying
    let hypothesisReviewCalibrationRepository: HypothesisReviewCalibrationRepositorying
    let hypothesisMetricsRepository: HypothesisMetricsRepositorying
    let userExposureEventRepository: UserExposureEventRepositorying
    let policyDiffArtifactRepository: PolicyDiffArtifactRepositorying
    let ruleWeightRepository: RuleWeightRepositorying
    let candidateScoreRepository: CandidateScoreRepositorying
    let yearScanRepository: YearScanRepositorying
    let suppressionRepository: SuppressionRepositorying
    let messageStateManager: MessageStateManager

    static func live() -> AppEnvironment {
        let database = Database.shared
        let filterPreferencesStore = FilterPreferencesStore()
        let suppressionRepository = SuppressionRepository(database: database)
        let messageStateManager = MessageStateManager(database: database)
        let gmailSyncService = GmailSyncService(
            database: database,
            candidateSelector: CandidateSelector(
                preferences: filterPreferencesStore,
                suppressionRepository: suppressionRepository
            )
        )
        let messageRepository = MessageRepository(database: database)
        let obligationProjectionRepository = ObligationProjectionRepository(database: database)
        let obligationRepository = ObligationRepository(
            database: database,
            projectionRepository: obligationProjectionRepository
        )
        let mailboxAccountRepository = MailboxAccountRepository(database: database)
        let hypothesisReviewCalibrationRepository = HypothesisReviewCalibrationRepository(database: database)
        let userExposureEventRepository = UserExposureEventRepository(database: database)
        let policyDiffArtifactRepository = PolicyDiffArtifactRepository(database: database)
        let feedbackRepository = FeedbackRepository(
            database: database,
            hypothesisReviewCalibrationRepository: hypothesisReviewCalibrationRepository,
            userExposureEventRepository: userExposureEventRepository
        )
        let hypothesisMetricsRepository = HypothesisMetricsRepository(database: database)
        let ruleWeightRepository = RuleWeightRepository(database: database)
        let candidateScoreRepository = CandidateScoreRepository(database: database)
        let yearScanRepository = YearScanRepository(database: database)
        let syncPolicyStore = SyncPolicyStore()
        return AppEnvironment(
            database: database,
            gmailAuthService: GmailAuthService.shared,
            gmailSyncService: gmailSyncService,
            gmailSyncCoordinator: GmailSyncCoordinator(
                gmailSyncService: gmailSyncService,
                messageRepository: messageRepository,
                obligationExtractor: ObligationExtractor(
                    preferences: filterPreferencesStore,
                    ruleWeightRepository: ruleWeightRepository,
                    hypothesisReviewCalibrationRepository: hypothesisReviewCalibrationRepository,
                    hypothesisMetricsRepository: hypothesisMetricsRepository,
                    candidateScoreRepository: candidateScoreRepository,
                    suppressionRepository: suppressionRepository
                ),
                obligationRepository: obligationRepository,
                mailboxAccountRepository: mailboxAccountRepository,
                yearScanRepository: yearScanRepository
            ),
            syncPolicyStore: syncPolicyStore,
            filterPreferencesStore: filterPreferencesStore,
            obligationExtractor: ObligationExtractor(
                preferences: filterPreferencesStore,
                ruleWeightRepository: ruleWeightRepository,
                hypothesisReviewCalibrationRepository: hypothesisReviewCalibrationRepository,
                hypothesisMetricsRepository: hypothesisMetricsRepository,
                candidateScoreRepository: candidateScoreRepository,
                suppressionRepository: suppressionRepository
            ),
            obligationRepository: obligationRepository,
            obligationProjectionRepository: obligationProjectionRepository,
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

final class AppEnvironmentStore: ObservableObject {
    let value: AppEnvironment

    init(_ value: AppEnvironment) {
        self.value = value
    }
}

private struct AppEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppEnvironment.live()
}

extension EnvironmentValues {
    var appEnvironment: AppEnvironment {
        get { self[AppEnvironmentKey.self] }
        set { self[AppEnvironmentKey.self] = newValue }
    }
}
