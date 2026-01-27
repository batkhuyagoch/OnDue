import Foundation
import Combine

@MainActor
final class ConnectGmailViewModel: ObservableObject {
    @Published var statusMessage: String?

    func connect(using environment: AppEnvironment) async {
        do {
            statusMessage = "Connecting..."
            try await environment.gmailAuthService.authorize()
            try await environment.gmailSyncService.initialSync(daysBack: 21)
            statusMessage = "Connected. Sync complete."
        } catch {
            statusMessage = "Failed to connect. Try again."
        }
    }
}
