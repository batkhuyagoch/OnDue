import SwiftUI
import Combine

struct AppEnvironment {
    let gmailAuthService: GmailAuthServicing
    let gmailSyncService: GmailSyncServicing
    let gmailSyncCoordinator: GmailSyncCoordinating
    let syncPolicyStore: SyncPolicyStore
    let filterPreferencesStore: FilterPreferencesStore
    let obligationExtractor: ObligationExtracting
    let obligationRepository: ObligationRepositorying
    let messageRepository: MessageRepositorying
    let mailboxAccountRepository: MailboxAccountRepositorying
    let feedbackRepository: FeedbackRepositorying
    let ruleWeightRepository: RuleWeightRepositorying
    let candidateScoreRepository: CandidateScoreRepositorying

    static func live() -> AppEnvironment {
        let database = Database.shared
        let filterPreferencesStore = FilterPreferencesStore()
        let gmailSyncService = GmailSyncService(
            database: database,
            candidateSelector: CandidateSelector(preferences: filterPreferencesStore)
        )
        let messageRepository = MessageRepository(database: database)
        let obligationRepository = ObligationRepository(database: database)
        let mailboxAccountRepository = MailboxAccountRepository(database: database)
        let feedbackRepository = FeedbackRepository(database: database)
        let ruleWeightRepository = RuleWeightRepository(database: database)
        let candidateScoreRepository = CandidateScoreRepository(database: database)
        let syncPolicyStore = SyncPolicyStore()
        return AppEnvironment(
            gmailAuthService: GmailAuthService.shared,
            gmailSyncService: gmailSyncService,
            gmailSyncCoordinator: GmailSyncCoordinator(
                gmailSyncService: gmailSyncService,
                messageRepository: messageRepository,
                obligationExtractor: ObligationExtractor(
                    preferences: filterPreferencesStore,
                    ruleWeightRepository: ruleWeightRepository,
                    candidateScoreRepository: candidateScoreRepository
                ),
                obligationRepository: obligationRepository,
                mailboxAccountRepository: mailboxAccountRepository
            ),
            syncPolicyStore: syncPolicyStore,
            filterPreferencesStore: filterPreferencesStore,
            obligationExtractor: ObligationExtractor(
                preferences: filterPreferencesStore,
                ruleWeightRepository: ruleWeightRepository,
                candidateScoreRepository: candidateScoreRepository
            ),
            obligationRepository: obligationRepository,
            messageRepository: messageRepository,
            mailboxAccountRepository: mailboxAccountRepository,
            feedbackRepository: feedbackRepository,
            ruleWeightRepository: ruleWeightRepository,
            candidateScoreRepository: candidateScoreRepository
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
