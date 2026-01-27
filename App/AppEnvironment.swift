import SwiftUI
import Combine

struct AppEnvironment {
    let gmailAuthService: GmailAuthServicing
    let gmailSyncService: GmailSyncServicing
    let obligationExtractor: ObligationExtracting
    let obligationRepository: ObligationRepositorying
    let emailSnippetRepository: EmailSnippetRepositorying
    let backgroundRefreshService: BackgroundRefreshServicing

    static func live() -> AppEnvironment {
        let database = Database()
        return AppEnvironment(
            gmailAuthService: GmailAuthService(),
            gmailSyncService: GmailSyncService(database: database),
            obligationExtractor: ObligationExtractor(),
            obligationRepository: ObligationRepository(database: database),
            emailSnippetRepository: EmailSnippetRepository(database: database),
            backgroundRefreshService: BackgroundRefreshService()
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
