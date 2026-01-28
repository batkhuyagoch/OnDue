import Foundation

struct GmailMessageSummary: Hashable {
    let messageID: String
    let threadID: String?
    let sender: String
    let senderName: String?
    let subject: String
    let snippet: String
    let receivedAt: Date
    let labelIDs: [String]
    let hasAttachments: Bool
}

protocol GmailClienting: Sendable {
    func fetchMessages(daysBack: Int) async throws -> [GmailMessageSummary]
}

enum GmailClientError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case apiError(Int, String)
    case networkError(Error)
    
    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Gmail"
        case .invalidResponse:
            return "Invalid response from Gmail API"
        case .apiError(let code, let message):
            return "Gmail API error (\(code)): \(message)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

final class GmailClient: GmailClienting, @unchecked Sendable {
    
    private let baseURL = "https://gmail.googleapis.com/gmail/v1"
    private let authService: GmailAuthServicing
    
    init(authService: GmailAuthServicing = GmailAuthService.shared) {
        self.authService = authService
    }
    
    func fetchMessages(daysBack: Int) async throws -> [GmailMessageSummary] {
        guard let accessToken = authService.accessToken else {
            throw GmailClientError.notAuthenticated
        }
        
        // Calculate date for query
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let timestamp = Int(cutoffDate.timeIntervalSince1970)
        
        // List messages with query
        let messageIDs = try await listMessageIDs(accessToken: accessToken, afterTimestamp: timestamp)
        
        // Fetch full details for each message (batch in groups)
        var summaries: [GmailMessageSummary] = []
        
        // Process in batches of 10 to avoid rate limits
        for batch in messageIDs.chunked(into: 10) {
            let batchSummaries = try await withThrowingTaskGroup(of: GmailMessageSummary?.self) { group in
                for messageID in batch {
                    group.addTask {
                        try await self.fetchMessageDetails(messageID: messageID, accessToken: accessToken)
                    }
                }
                
                var results: [GmailMessageSummary] = []
                for try await summary in group {
                    if let summary = summary {
                        results.append(summary)
                    }
                }
                return results
            }
            summaries.append(contentsOf: batchSummaries)
        }
        
        return summaries.sorted { $0.receivedAt > $1.receivedAt }
    }
    
    // MARK: - Private Methods
    
    private func listMessageIDs(accessToken: String, afterTimestamp: Int, maxResults: Int = 100) async throws -> [String] {
        let query = "after:\(afterTimestamp)"
        var urlComponents = URLComponents(string: "\(baseURL)/users/me/messages")!
        urlComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailClientError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw GmailClientError.apiError(httpResponse.statusCode, errorMessage)
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let messages = json?["messages"] as? [[String: Any]] ?? []
        
        return messages.compactMap { $0["id"] as? String }
    }
    
    private func fetchMessageDetails(messageID: String, accessToken: String) async throws -> GmailMessageSummary? {
        var urlComponents = URLComponents(string: "\(baseURL)/users/me/messages/\(messageID)")!
        urlComponents.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "Date")
        ]
        
        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GmailClientError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            // Skip messages that fail (might be deleted)
            return nil
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        
        return parseMessage(json)
    }
    
    private func parseMessage(_ json: [String: Any]) -> GmailMessageSummary? {
        guard let id = json["id"] as? String else { return nil }
        
        let threadID = json["threadId"] as? String
        let snippet = json["snippet"] as? String ?? ""
        let labelIDs = json["labelIds"] as? [String] ?? []
        
        // Parse internal date (milliseconds since epoch)
        let internalDateStr = json["internalDate"] as? String ?? "0"
        let internalDateMs = Double(internalDateStr) ?? 0
        let receivedAt = Date(timeIntervalSince1970: internalDateMs / 1000)
        
        // Parse headers
        let payload = json["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        
        var fromEmail = ""
        var fromName: String?
        var subject = "(No Subject)"
        
        for header in headers {
            let name = header["name"] as? String ?? ""
            let value = header["value"] as? String ?? ""
            
            switch name.lowercased() {
            case "from":
                (fromEmail, fromName) = parseFromHeader(value)
            case "subject":
                subject = value.isEmpty ? "(No Subject)" : value
            default:
                break
            }
        }
        
        // Check for attachments
        let parts = payload["parts"] as? [[String: Any]] ?? []
        let hasAttachments = parts.contains { part in
            let filename = part["filename"] as? String ?? ""
            return !filename.isEmpty
        }
        
        return GmailMessageSummary(
            messageID: id,
            threadID: threadID,
            sender: fromEmail,
            senderName: fromName,
            subject: subject,
            snippet: snippet,
            receivedAt: receivedAt,
            labelIDs: labelIDs,
            hasAttachments: hasAttachments
        )
    }
    
    private func parseFromHeader(_ from: String) -> (email: String, name: String?) {
        // Parse "Name <email@example.com>" or "email@example.com"
        let pattern = #"^(?:(.+?)\s*<)?([^<>]+@[^<>]+)>?$"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: from, range: NSRange(from.startIndex..., in: from)) else {
            return (from.trimmingCharacters(in: .whitespaces), nil)
        }
        
        var name: String?
        var email = from
        
        if let nameRange = Range(match.range(at: 1), in: from) {
            name = String(from[nameRange]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        
        if let emailRange = Range(match.range(at: 2), in: from) {
            email = String(from[emailRange]).trimmingCharacters(in: .whitespaces)
        }
        
        return (email, name?.isEmpty == true ? nil : name)
    }
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
