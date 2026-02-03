import SwiftUI
import Combine

struct AppEnvironment {
    let gmailAuthService: GmailAuthServicing
    let gmailSyncService: GmailSyncServicing
    let gmailSyncCoordinator: GmailSyncCoordinating
    let syncPolicyStore: SyncPolicyStore
    let obligationExtractor: ObligationExtracting
    let obligationRepository: ObligationRepositorying
    let messageRepository: MessageRepositorying
    let mailboxAccountRepository: MailboxAccountRepositorying

    static func live() -> AppEnvironment {
        let database = Database.shared
        let gmailSyncService = GmailSyncService(database: database)
        let messageRepository = MessageRepository(database: database)
        let obligationRepository = ObligationRepository(database: database)
        let mailboxAccountRepository = MailboxAccountRepository(database: database)
        let syncPolicyStore = SyncPolicyStore()
        return AppEnvironment(
            gmailAuthService: GmailAuthService.shared,
            gmailSyncService: gmailSyncService,
            gmailSyncCoordinator: GmailSyncCoordinator(
                gmailSyncService: gmailSyncService,
                messageRepository: messageRepository,
                obligationExtractor: ObligationExtractor(),
                obligationRepository: obligationRepository,
                mailboxAccountRepository: mailboxAccountRepository
            ),
            syncPolicyStore: syncPolicyStore,
            obligationExtractor: ObligationExtractor(),
            obligationRepository: obligationRepository,
            messageRepository: messageRepository,
            mailboxAccountRepository: mailboxAccountRepository
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
