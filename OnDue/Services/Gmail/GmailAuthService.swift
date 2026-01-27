import Foundation

protocol GmailAuthServicing {
    func authorize() async throws
}

final class GmailAuthService: GmailAuthServicing {
    func authorize() async throws {
        // TODO: Implement OAuth with AppAuth.
    }
}
