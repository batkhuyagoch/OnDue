import Foundation

protocol ObligationExtracting: Sendable {
    func extract(from messages: [MessageRecord], mailboxAccountId: String) -> [ObligationRecord]
}

final class ObligationExtractor: ObligationExtracting, @unchecked Sendable {
    
    func extract(from messages: [MessageRecord], mailboxAccountId: String) -> [ObligationRecord] {
        // TODO: Implement high-precision rules:
        // - explicit dates ("by Friday", "due March 15")
        // - request phrases ("please send", "need you to", "can you")
        // - appointments ("scheduled for", "meeting at")
        // - payment terms ("payment due", "invoice")
        
        var obligations: [ObligationRecord] = []
        
        for message in messages {
            guard let pk = message.pk else { continue }
            
            // Simple placeholder extraction - detect obvious deadline keywords
            let text = "\(message.subject) \(message.snippet ?? "")"
            
            if let extracted = extractObligation(from: text, message: message, mailboxAccountId: mailboxAccountId, messagePk: pk) {
                obligations.append(extracted)
            }
        }
        
        return obligations
    }
    
    private func extractObligation(
        from text: String,
        message: MessageRecord,
        mailboxAccountId: String,
        messagePk: Int64
    ) -> ObligationRecord? {
        let lowercased = text.lowercased()
        
        // Deadline patterns
        let deadlinePatterns = ["deadline", "due by", "by friday", "by monday", "due date", "expires"]
        let requestPatterns = ["please send", "need you to", "can you", "could you", "would you"]
        let appointmentPatterns = ["meeting", "scheduled for", "appointment", "call at", "sync at"]
        
        var category: ObligationCategory?
        var risk: ObligationRisk = .medium
        
        for pattern in deadlinePatterns where lowercased.contains(pattern) {
            category = .deadline
            risk = .high
            break
        }
        
        if category == nil {
            for pattern in requestPatterns where lowercased.contains(pattern) {
                category = .request
                break
            }
        }
        
        if category == nil {
            for pattern in appointmentPatterns where lowercased.contains(pattern) {
                category = .appointment
                break
            }
        }
        
        guard let detectedCategory = category else { return nil }
        
        // Generate a unique key for deduplication
        let obligationKey = "\(message.providerMessageId)_\(detectedCategory.rawValue)"
        
        return ObligationRecord(
            mailboxAccountId: mailboxAccountId,
            messagePk: messagePk,
            category: detectedCategory,
            title: message.subject,
            deadlineAt: nil, // TODO: Parse actual dates
            risk: risk,
            whoOwes: .me,
            confidence: 0.7,
            evidenceQuote: message.snippet ?? message.subject,
            obligationKey: obligationKey
        )
    }
}
