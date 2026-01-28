import SwiftUI
import Combine

struct AppEnvironment {
    let gmailAuthService: GmailAuthServicing
    let gmailSyncService: GmailSyncServicing
    let obligationExtractor: ObligationExtracting
    let obligationRepository: ObligationRepositorying
    let messageRepository: MessageRepositorying
    let mailboxAccountRepository: MailboxAccountRepositorying

    static func live() -> AppEnvironment {
        let database = Database.shared
        return AppEnvironment(
            gmailAuthService: GmailAuthService.shared,
            gmailSyncService: GmailSyncService(database: database),
            obligationExtractor: ObligationExtractor(),
            obligationRepository: ObligationRepository(database: database),
            messageRepository: MessageRepository(database: database),
            mailboxAccountRepository: MailboxAccountRepository(database: database)
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
