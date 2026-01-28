import Foundation
import GoogleSignIn

protocol GmailAuthServicing: Sendable {
    func authorize() async throws
    func restorePreviousSignIn() async throws -> Bool
    func signOut()
    var isSignedIn: Bool { get }
    var userEmail: String? { get }
    var accessToken: String? { get }
}

enum GmailAuthError: LocalizedError {
    case notSignedIn
    case missingAccessToken
    case signInFailed(Error)
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Google"
        case .missingAccessToken:
            return "Missing access token"
        case .signInFailed(let error):
            return "Sign in failed: \(error.localizedDescription)"
        case .cancelled:
            return "Sign in was cancelled"
        }
    }
}

final class GmailAuthService: GmailAuthServicing, @unchecked Sendable {
    
    static let shared = GmailAuthService()
    
    private init() {
        // Configure GoogleSignIn
        let config = GIDConfiguration(clientID: GmailConfiguration.clientID)
        GIDSignIn.sharedInstance.configuration = config
    }
    
    var isSignedIn: Bool {
        GIDSignIn.sharedInstance.currentUser != nil
    }
    
    var userEmail: String? {
        GIDSignIn.sharedInstance.currentUser?.profile?.email
    }
    
    var accessToken: String? {
        GIDSignIn.sharedInstance.currentUser?.accessToken.tokenString
    }
    
    /// Attempt to restore a previous sign-in session
    func restorePreviousSignIn() async throws -> Bool {
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            
            // Check if we have the required scopes
            let grantedScopes = user.grantedScopes ?? []
            let hasRequiredScopes = GmailConfiguration.scopes.allSatisfy { scope in
                grantedScopes.contains(scope)
            }
            
            if hasRequiredScopes {
                // Refresh token if needed
                try await refreshTokenIfNeeded()
                return true
            } else {
                // Need to request additional scopes
                return false
            }
        } catch {
            return false
        }
    }
    
    /// Sign in with Google and request Gmail read-only scope
    @MainActor
    func authorize() async throws {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            throw GmailAuthError.signInFailed(NSError(domain: "GmailAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "No root view controller"]))
        }
        
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: rootViewController,
                hint: nil,
                additionalScopes: GmailConfiguration.scopes
            )
            
            // Verify we got the scopes we need
            let grantedScopes = result.user.grantedScopes ?? []
            let hasRequiredScopes = GmailConfiguration.scopes.allSatisfy { scope in
                grantedScopes.contains(scope)
            }
            
            guard hasRequiredScopes else {
                throw GmailAuthError.signInFailed(NSError(domain: "GmailAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "Gmail scope not granted"]))
            }
            
        } catch let error as GIDSignInError {
            if error.code == .canceled {
                throw GmailAuthError.cancelled
            }
            throw GmailAuthError.signInFailed(error)
        } catch {
            throw GmailAuthError.signInFailed(error)
        }
    }
    
    /// Sign out and clear tokens
    func signOut() {
        GIDSignIn.sharedInstance.signOut()
    }
    
    /// Refresh the access token if it's expired
    private func refreshTokenIfNeeded() async throws {
        guard let user = GIDSignIn.sharedInstance.currentUser else {
            throw GmailAuthError.notSignedIn
        }
        
        try await user.refreshTokensIfNeeded()
    }
}
