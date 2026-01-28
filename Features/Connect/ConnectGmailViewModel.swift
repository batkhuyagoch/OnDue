import Foundation
import Combine

@MainActor
final class ConnectGmailViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isConnected = false
    @Published private(set) var userEmail: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    
    // MARK: - Private
    
    private var mailboxAccountId: String?
    
    // MARK: - Actions

    func checkConnection(using environment: AppEnvironment) {
        isConnected = environment.gmailAuthService.isSignedIn
        userEmail = environment.gmailAuthService.userEmail
    }
    
    func connect(using environment: AppEnvironment) async {
        do {
            statusMessage = "Connecting..."
            try await environment.gmailAuthService.authorize()
            
            guard let email = environment.gmailAuthService.userEmail else {
                statusMessage = "Failed to get user info"
                return
            }
            
            isConnected = true
            userEmail = email
            
            // Create or get mailbox account via repository
            let account = try await environment.mailboxAccountRepository.getOrCreate(
                email: email,
                provider: .gmail
            )
            mailboxAccountId = account.id
            
            await syncEmails(using: environment)
            
        } catch GmailAuthError.cancelled {
            statusMessage = nil
        } catch {
            isSyncing = false
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
    
    func disconnect(using environment: AppEnvironment) {
        environment.gmailAuthService.signOut()
        isConnected = false
        userEmail = nil
        mailboxAccountId = nil
        statusMessage = nil
        lastSyncDate = nil
    }
    
    func resync(using environment: AppEnvironment) async {
        guard mailboxAccountId != nil else {
            statusMessage = "Not connected"
            return
        }
        await syncEmails(using: environment)
    }
    
    // MARK: - Private Helpers
    
    private func syncEmails(using environment: AppEnvironment) async {
        guard let accountId = mailboxAccountId else { return }
        
        do {
            statusMessage = "Syncing emails..."
            isSyncing = true
            
            try await environment.gmailSyncService.initialSync(
                mailboxAccountId: accountId,
                daysBack: 21
            )
            
            lastSyncDate = Date()
            isSyncing = false
            statusMessage = "Sync complete!"
            
        } catch {
            isSyncing = false
            statusMessage = "Sync failed: \(error.localizedDescription)"
        }
    }
}
