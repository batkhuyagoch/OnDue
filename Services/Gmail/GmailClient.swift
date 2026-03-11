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

struct GmailMessageBody: Hashable {
    let messageID: String
    let bodyText: String
    let bodyHtml: String?
    let attachmentTypes: [String]
    let hasPdf: Bool
    let hasCalendar: Bool
}

protocol GmailClienting: Sendable {
    func fetchMessages(daysBack: Int) async throws -> GmailMessageFetchResult
    func fetchMessages(startDate: Date, endDate: Date) async throws -> GmailMessageFetchResult
    func fetchMessages(messageIDs: [String]) async throws -> GmailMessageFetchResult
    func fetchMessageBodies(messageIDs: [String]) async throws -> [GmailMessageBody]
    func fetchCurrentHistoryId() async throws -> String
    func fetchChangedMessageIDs(startHistoryId: String) async throws -> (messageIDs: [String], latestHistoryId: String?)
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
    private let stateManager: MessageStateManager
    static var maxTotalMessagesPerSlice: Int = 100_000

    // MARK: - Quota protection
    private static let maxRetries = 5
    private static let baseBackoffSeconds: Double = 1.0
    private static let maxBackoffSeconds: Double = 60.0
    private static let pacingDelayBetweenBatches: UInt64 = 100_000_000  // 100ms
    private static let pacingDelayBetweenSlices: UInt64 = 200_000_000   // 200ms

    init(authService: GmailAuthServicing = GmailAuthService.shared,
         stateManager: MessageStateManager = MessageStateManager()) {
        self.authService = authService
        self.stateManager = stateManager
    }

    private func log(_ message: String, fields: [String: CustomStringConvertible] = [:]) {
        AppLog.debug(message, fields: fields)
    }

    /// Performs a Gmail API request with bounded retries, exponential backoff + jitter,
    /// and honoring Retry-After for 429/5xx and transient network errors.
    private func performGmailRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var lastError: Error?
        for attempt in 0...Self.maxRetries {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw GmailClientError.invalidResponse
                }
                if httpResponse.statusCode == 200 {
                    return (data, httpResponse)
                }
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                if Self.isRetryableStatusCode(httpResponse.statusCode) {
                    lastError = GmailClientError.apiError(httpResponse.statusCode, errorMessage)
                    if attempt < Self.maxRetries {
                        let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                        let delay = Self.computeBackoffDelay(attempt: attempt, retryAfter: retryAfter)
                        AppLog.debug(
                            "GmailClient.retry",
                            fields: ["attempt": attempt + 1, "statusCode": httpResponse.statusCode, "delaySeconds": delay]
                        )
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                }
                throw GmailClientError.apiError(httpResponse.statusCode, errorMessage)
            } catch let error as GmailClientError {
                throw error
            } catch {
                lastError = error
                if attempt < Self.maxRetries && Self.isTransientNetworkError(error) {
                    let delay = Self.computeBackoffDelay(attempt: attempt, retryAfter: nil)
                    AppLog.debug(
                        "GmailClient.retry.network",
                        fields: ["attempt": attempt + 1, "delaySeconds": delay]
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw GmailClientError.networkError(error)
            }
        }
        throw lastError ?? GmailClientError.invalidResponse
    }

    private static func isRetryableStatusCode(_ code: Int) -> Bool {
        code == 429 || (code >= 500 && code < 600)
    }

    private static func isTransientNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && (
            nsError.code == NSURLErrorTimedOut ||
            nsError.code == NSURLErrorNetworkConnectionLost ||
            nsError.code == NSURLErrorNotConnectedToInternet ||
            nsError.code == NSURLErrorInternationalRoamingOff
        )
    }

    private static func computeBackoffDelay(attempt: Int, retryAfter: String?) -> Double {
        if let raw = retryAfter?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
           let seconds = Double(raw) {
            return min(max(seconds, 1), maxBackoffSeconds)
        }
        let exponential = baseBackoffSeconds * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0...(0.3 * exponential))
        return min(exponential + jitter, maxBackoffSeconds)
    }
    
    func fetchMessages(daysBack: Int) async throws -> GmailMessageFetchResult {
        guard let accessToken = authService.accessToken else {
            throw GmailClientError.notAuthenticated
        }
        
        // Calculate date for query
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        let endDate = Date()
        
        // List messages by day slices to guarantee coverage
        let messageIDs = try await listMessageIDsSliced(
            accessToken: accessToken,
            startDate: cutoffDate,
            endDate: endDate,
            sliceDays: 1,
            maxResults: 500,
            maxTotalMessagesPerSlice: Self.maxTotalMessagesPerSlice
        )
        
        // Fetch full details for each message (batch in groups)
        let summaries = try await fetchMessageSummaries(messageIDs: messageIDs, accessToken: accessToken)
        return GmailMessageFetchResult(
            messageIDsCount: messageIDs.count,
            summaries: summaries.sorted { $0.receivedAt > $1.receivedAt }
        )
    }

    func fetchMessages(startDate: Date, endDate: Date) async throws -> GmailMessageFetchResult {
        guard let accessToken = authService.accessToken else {
            throw GmailClientError.notAuthenticated
        }
        
        // Use week slices for large ranges to ensure coverage without excessive requests
        let messageIDs = try await listMessageIDsSliced(
            accessToken: accessToken,
            startDate: startDate,
            endDate: endDate,
            sliceDays: 7,
            maxResults: 500,
            maxTotalMessagesPerSlice: Self.maxTotalMessagesPerSlice
        )

        let summaries = try await fetchMessageSummaries(messageIDs: messageIDs, accessToken: accessToken)
        return GmailMessageFetchResult(
            messageIDsCount: messageIDs.count,
            summaries: summaries.sorted { $0.receivedAt > $1.receivedAt }
        )
    }

    func fetchMessages(messageIDs: [String]) async throws -> GmailMessageFetchResult {
        guard let accessToken = authService.accessToken else {
            throw GmailClientError.notAuthenticated
        }
        let uniqueIds = Array(Set(messageIDs))
        let summaries = try await fetchMessageSummaries(messageIDs: uniqueIds, accessToken: accessToken)
        return GmailMessageFetchResult(
            messageIDsCount: uniqueIds.count,
            summaries: summaries.sorted { $0.receivedAt > $1.receivedAt }
        )
    }

    func fetchMessageBodies(messageIDs: [String]) async throws -> [GmailMessageBody] {
        guard let accessToken = authService.accessToken else {
            throw GmailClientError.notAuthenticated
        }
        let uniqueIds = Array(Set(messageIDs))
        guard !uniqueIds.isEmpty else { return [] }
        var bodies: [GmailMessageBody] = []

        for (idx, batch) in uniqueIds.chunked(into: 10).enumerated() {
            if idx > 0 {
                try await Task.sleep(nanoseconds: Self.pacingDelayBetweenBatches)
            }
            let batchBodies = try await withThrowingTaskGroup(of: GmailMessageBody?.self) { group in
                for messageID in batch {
                    group.addTask {
                        try await self.fetchMessageBodyDetails(messageID: messageID, accessToken: accessToken)
                    }
                }

                var results: [GmailMessageBody] = []
                for try await body in group {
                    if let body {
                        results.append(body)
                    }
                }
                return results
            }
            bodies.append(contentsOf: batchBodies)
        }

        return bodies
    }

    func fetchCurrentHistoryId() async throws -> String {
        guard let accessToken = authService.accessToken else {
            throw GmailClientError.notAuthenticated
        }

        var request = URLRequest(url: URL(string: "\(baseURL)/users/me/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await performGmailRequest(request)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let historyId = json?["historyId"] as? String else {
            throw GmailClientError.invalidResponse
        }
        return historyId
    }

    func fetchChangedMessageIDs(startHistoryId: String) async throws -> (messageIDs: [String], latestHistoryId: String?) {
        guard let accessToken = authService.accessToken else {
            throw GmailClientError.notAuthenticated
        }

        var collected: Set<String> = []
        var pageToken: String?
        var latestHistoryId: String?

        repeat {
            var urlComponents = URLComponents(string: "\(baseURL)/users/me/history")!
            var queryItems = [
                URLQueryItem(name: "startHistoryId", value: startHistoryId),
                URLQueryItem(name: "historyTypes", value: "messageAdded"),
                URLQueryItem(name: "historyTypes", value: "messageDeleted"),
                URLQueryItem(name: "historyTypes", value: "labelAdded"),
                URLQueryItem(name: "historyTypes", value: "labelRemoved")
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            urlComponents.queryItems = queryItems

            var request = URLRequest(url: urlComponents.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await performGmailRequest(request)

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let history = json?["history"] as? [[String: Any]] ?? []
            latestHistoryId = (json?["historyId"] as? String) ?? latestHistoryId

            for entry in history {
                if let messages = entry["messages"] as? [[String: Any]] {
                    for message in messages {
                        if let id = message["id"] as? String { collected.insert(id) }
                    }
                }
                if let messagesAdded = entry["messagesAdded"] as? [[String: Any]] {
                    for item in messagesAdded {
                        if let message = item["message"] as? [String: Any],
                           let id = message["id"] as? String {
                            collected.insert(id)
                        }
                    }
                }
                if let messagesDeleted = entry["messagesDeleted"] as? [[String: Any]] {
                    for item in messagesDeleted {
                        if let message = item["message"] as? [String: Any],
                           let id = message["id"] as? String {
                            collected.insert(id)
                        }
                    }
                }
                if let labelsAdded = entry["labelsAdded"] as? [[String: Any]] {
                    for item in labelsAdded {
                        if let message = item["message"] as? [String: Any],
                           let id = message["id"] as? String {
                            collected.insert(id)
                        }
                    }
                }
                if let labelsRemoved = entry["labelsRemoved"] as? [[String: Any]] {
                    for item in labelsRemoved {
                        if let message = item["message"] as? [String: Any],
                           let id = message["id"] as? String {
                            collected.insert(id)
                        }
                    }
                }
            }

            pageToken = json?["nextPageToken"] as? String
        } while pageToken != nil

        return (Array(collected), latestHistoryId)
    }
    
    // MARK: - Private Methods
    
    private func listMessageIDs(
        accessToken: String,
        afterTimestamp: Int,
        beforeTimestamp: Int? = nil,
        maxResults: Int = 500,
        maxTotalMessages: Int = 100_000
    ) async throws -> [String] {
        var query = "after:\(afterTimestamp)"
        if let beforeTimestamp {
            query += " before:\(beforeTimestamp)"
        }
        var collected: [String] = []
        var pageToken: String?
        var pageIndex = 0
        
        repeat {
            var urlComponents = URLComponents(string: "\(baseURL)/users/me/messages")!
            var queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "maxResults", value: String(maxResults))
            ]
            if let pageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            urlComponents.queryItems = queryItems
            
            var request = URLRequest(url: urlComponents.url!)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

            let (data, _) = try await performGmailRequest(request)

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let messages = json?["messages"] as? [[String: Any]] ?? []
            let estimate = json?["resultSizeEstimate"] as? Int ?? -1
            collected.append(contentsOf: messages.compactMap { $0["id"] as? String })
            
            pageToken = json?["nextPageToken"] as? String
            pageIndex += 1
            if pageToken != nil {
                try await Task.sleep(nanoseconds: Self.pacingDelayBetweenBatches)
            }
            log(
                "GmailClient.page",
                fields: [
                    "page": pageIndex,
                    "added": messages.count,
                    "total": collected.count,
                    "nextToken": pageToken != nil,
                    "estimate": estimate
                ]
            )
        } while pageToken != nil && collected.count < maxTotalMessages
        
        if pageToken != nil {
            AppLog.info(
                "GmailClient.maxTotalReached",
                fields: ["maxTotalMessages": maxTotalMessages]
            )
        }
        log(
            "GmailClient.listMessageIDs",
            fields: ["count": collected.count, "query": query]
        )
        return Array(collected.prefix(maxTotalMessages))
    }

    private func listMessageIDsSliced(
        accessToken: String,
        startDate: Date,
        endDate: Date,
        sliceDays: Int,
        maxResults: Int = 500,
        maxTotalMessagesPerSlice: Int = 100_000
    ) async throws -> [String] {
        var collected: Set<String> = []
        var sliceStart = startDate
        let calendar = Calendar.current
        
        while sliceStart < endDate {
            let sliceEnd = calendar.date(byAdding: .day, value: sliceDays, to: sliceStart) ?? endDate
            let afterTimestamp = Int(sliceStart.timeIntervalSince1970)
            let beforeTimestamp = Int(min(sliceEnd, endDate).timeIntervalSince1970)
            
            let sliceIDs = try await listMessageIDs(
                accessToken: accessToken,
                afterTimestamp: afterTimestamp,
                beforeTimestamp: beforeTimestamp,
                maxResults: maxResults,
                maxTotalMessages: maxTotalMessagesPerSlice
            )
            
            log(
                "GmailClient.slice",
                fields: [
                    "start": sliceStart,
                    "end": min(sliceEnd, endDate),
                    "count": sliceIDs.count
                ]
            )
            for id in sliceIDs { collected.insert(id) }

            sliceStart = sliceEnd
            if sliceStart < endDate {
                try await Task.sleep(nanoseconds: Self.pacingDelayBetweenSlices)
            }
        }
        
        return Array(collected)
    }

    private func fetchMessageSummaries(messageIDs: [String], accessToken: String) async throws -> [GmailMessageSummary] {
        guard !messageIDs.isEmpty else { return [] }
        var summaries: [GmailMessageSummary] = []

        // Process in batches of 10 to avoid rate limits
        for (idx, batch) in messageIDs.chunked(into: 10).enumerated() {
            if idx > 0 {
                try await Task.sleep(nanoseconds: Self.pacingDelayBetweenBatches)
            }
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

        return summaries
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

        do {
            let (data, _) = try await performGmailRequest(request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return parseMessage(json)
        } catch GmailClientError.apiError(let code, _) where code >= 400 && code < 500 {
            return nil
        }
    }

    private func fetchMessageBodyDetails(messageID: String, accessToken: String) async throws -> GmailMessageBody? {
        var urlComponents = URLComponents(string: "\(baseURL)/users/me/messages/\(messageID)")!
        urlComponents.queryItems = [
            URLQueryItem(name: "format", value: "full")
        ]

        var request = URLRequest(url: urlComponents.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await performGmailRequest(request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            guard let id = json["id"] as? String else { return nil }
            let payload = json["payload"] as? [String: Any] ?? [:]
            let extracted = extractBodyParts(from: payload)
            guard let bodyText = extracted.bodyText, !bodyText.isEmpty else { return nil }

            return GmailMessageBody(
                messageID: id,
                bodyText: bodyText,
                bodyHtml: extracted.bodyHtml,
                attachmentTypes: extracted.attachmentTypes,
                hasPdf: extracted.hasPdf,
                hasCalendar: extracted.hasCalendar
            )
        } catch GmailClientError.apiError(let code, _) where code >= 400 && code < 500 {
            return nil
        }
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

    private func extractBodyParts(from payload: [String: Any]) -> (bodyText: String?, bodyHtml: String?, attachmentTypes: [String], hasPdf: Bool, hasCalendar: Bool) {
        let mimeType = payload["mimeType"] as? String
        if let bodyText = decodeBody(payload["body"] as? [String: Any]),
           mimeType == "text/plain" || mimeType == "text/html" {
            let boundedBody = String(bodyText.prefix(EmailContentBudget.htmlPrecleanCharsMax))
            let cleanedHTML = mimeType == "text/html" ? precleanHTML(boundedBody) : boundedBody
            let normalizedText = mimeType == "text/html" ? stripHTML(cleanedHTML) : boundedBody
            let bodyHtml = mimeType == "text/html" ? cleanedHTML : nil
            return (normalizedText, bodyHtml, [], false, false)
        }

        let parts = payload["parts"] as? [[String: Any]] ?? []
        var plainText: String?
        var htmlText: String?
        var attachmentTypes: [String] = []

        for part in parts {
            collectAttachmentTypes(from: part, into: &attachmentTypes)
            let partType = part["mimeType"] as? String
            if partType == "text/plain", let decoded = decodeBody(part["body"] as? [String: Any]) {
                plainText = decoded
                break
            }
        }

        if plainText == nil {
            for part in parts {
                collectAttachmentTypes(from: part, into: &attachmentTypes)
                let partType = part["mimeType"] as? String
                if partType == "text/html", let decoded = decodeBody(part["body"] as? [String: Any]) {
                    htmlText = precleanHTML(String(decoded.prefix(EmailContentBudget.htmlPrecleanCharsMax)))
                    break
                }
                if let nestedParts = part["parts"] as? [[String: Any]] {
                    for nested in nestedParts {
                        collectAttachmentTypes(from: nested, into: &attachmentTypes)
                        let nestedType = nested["mimeType"] as? String
                        if nestedType == "text/plain", let decoded = decodeBody(nested["body"] as? [String: Any]) {
                            plainText = decoded
                            break
                        }
                        if nestedType == "text/html", let decoded = decodeBody(nested["body"] as? [String: Any]) {
                            htmlText = precleanHTML(String(decoded.prefix(EmailContentBudget.htmlPrecleanCharsMax)))
                        }
                    }
                }
                if plainText != nil { break }
            }
        }

        let normalizedTypes = attachmentTypes.map { $0.lowercased() }
        let hasPdf = normalizedTypes.contains { $0 == "application/pdf" } || normalizedTypes.contains(where: { $0.contains("pdf") })
        let hasCalendar = normalizedTypes.contains { $0 == "text/calendar" } || normalizedTypes.contains(where: { $0.contains("calendar") })

        if let plainText, !plainText.isEmpty {
            return (plainText, htmlText, attachmentTypes, hasPdf, hasCalendar)
        }
        if let htmlText, !htmlText.isEmpty {
            return (stripHTML(htmlText), htmlText, attachmentTypes, hasPdf, hasCalendar)
        }
        return (nil, htmlText, attachmentTypes, hasPdf, hasCalendar)
    }

    private func collectAttachmentTypes(from part: [String: Any], into types: inout [String]) {
        let filename = part["filename"] as? String ?? ""
        guard !filename.isEmpty else { return }
        if let mimeType = part["mimeType"] as? String {
            types.append(mimeType)
        }
    }

    private func decodeBody(_ body: [String: Any]?) -> String? {
        guard let body,
              let dataString = body["data"] as? String,
              let decoded = decodeBase64URL(dataString) else {
            return nil
        }
        return decoded
    }

    private func decodeBase64URL(_ input: String) -> String? {
        var base64 = input.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        let bounded = data.prefix(EmailContentBudget.decodeBytesMax)
        return String(data: bounded, encoding: .utf8)
    }

    private func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let normalized = withoutTags.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func precleanHTML(_ html: String) -> String {
        var cleaned = html
        let patterns = [
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<noscript[^>]*>.*?</noscript>",
            "(?is)<svg[^>]*>.*?</svg>"
        ]
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return cleaned
    }
}

struct GmailMessageFetchResult {
    let messageIDsCount: Int
    let summaries: [GmailMessageSummary]
}

// MARK: - Array Extension

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
