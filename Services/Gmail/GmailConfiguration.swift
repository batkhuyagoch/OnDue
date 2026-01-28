import Foundation

enum GmailConfiguration {
    
    private static var config: [String: Any] {
        let name = "GoogleService-Info"
        let ext = "plist"

        let url = Bundle.main.url(forResource: name, withExtension: ext)
        print("✅ GoogleService plist url:", url?.absoluteString ?? "nil")

        if let url,
           let dict = NSDictionary(contentsOf: url) as? [String: Any] {
            print("✅ Loaded keys:", dict.keys.sorted())
            return dict
        }

        // Fall back to the app's main Info.plist
        print("⚠️ Falling back to Info.plist")
        guard let info = Bundle.main.infoDictionary else {
            fatalError("Info.plist not found in main bundle.")
        }
        return info
    }
    
    /// Google OAuth Client ID from Info.plist (key: CLIENT_ID)
    static var clientID: String {
        guard let clientID = config["CLIENT_ID"] as? String, !clientID.isEmpty else {
            fatalError("CLIENT_ID not found or empty in Info.plist. Add a String key 'CLIENT_ID' with your OAuth client ID.")
        }
        return clientID
    }
    
    /// Reversed client ID for URL scheme from Info.plist (key: REVERSED_CLIENT_ID)
    static var reversedClientID: String {
        guard let reversed = config["REVERSED_CLIENT_ID"] as? String, !reversed.isEmpty else {
            fatalError("REVERSED_CLIENT_ID not found or empty in Info.plist. Add a String key 'REVERSED_CLIENT_ID' with the reversed client ID used in URL Schemes.")
        }
        return reversed
    }
    
    /// Gmail API scopes (not in plist, defined here)
    static let scopes = ["https://www.googleapis.com/auth/gmail.readonly"]
}
