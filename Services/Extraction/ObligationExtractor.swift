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

            // High-precision suppression to avoid promo/marketing noise.
            if isSuppressed(message: message) { continue }
            
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
        
        // Balanced rules: allow softer requests but keep promo suppression.
        let strongDeadlinePatterns = [
            "due by", "due on", "due date", "deadline", "expires on", "by end of day", "by eod",
            "submit by", "respond by", "reply by", "complete by", "deliver by", "payment due"
        ]
        let strongRequestPatterns = [
            "please send", "please review", "please sign", "please complete", "please confirm",
            "need you to", "can you", "could you", "would you", "action required", "your action is required",
            "required action", "urgent response"
        ]
        let softRequestPatterns = [
            "please take a look", "please advise", "please follow up", "can you take a look",
            "could you take a look", "would you mind", "would you be able", "let me know",
            "kindly review", "kindly confirm", "kindly send", "when you have a chance"
        ]
        let appointmentPatterns = [
            "meeting scheduled", "calendar invite", "appointment", "call scheduled", "call at",
            "meeting at", "interview scheduled", "session at", "sync", "invite"
        ]
        
        var category: ObligationCategory?
        var risk: ObligationRisk = .medium
        
        // Require a strong signal + (deadline or request). Appointments are only accepted
        // if the subject/snippet has explicit scheduling language.
        if strongDeadlinePatterns.contains(where: { lowercased.contains($0) }) {
            category = .deadline
            risk = .high
        } else if strongRequestPatterns.contains(where: { lowercased.contains($0) }) {
            category = .request
        } else if softRequestPatterns.contains(where: { lowercased.contains($0) }) {
            category = .request
            risk = .medium
        } else if appointmentPatterns.contains(where: { lowercased.contains($0) }) {
            category = .appointment
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

    private func isSuppressed(message: MessageRecord) -> Bool {
        let subject = message.subject.lowercased()
        let snippet = (message.snippet ?? "").lowercased()
        let fromEmail = message.fromEmail.lowercased()
        let labels = (message.labelIds ?? "").lowercased()
        let text = "\(subject) \(snippet)"
        
        // Gmail labels
        let labelBlocklist = ["category_promotions", "category_social", "category_updates", "category_forums"]
        if labelBlocklist.contains(where: { labels.contains($0) }) {
            return true
        }
        
        // Sender suppression
        if fromEmail.contains("noreply") || fromEmail.contains("no-reply") || fromEmail.contains("donotreply") {
            return true
        }
        
        // Promo/marketing suppression keywords
        let promoKeywords = [
            "unsubscribe", "sale", "deal", "offer", "promo", "promotion", "discount",
            "newsletter", "marketing", "limited time", "new arrivals", "shop now",
            "special offer", "save now", "percent off", "coupon", "free shipping"
        ]
        if promoKeywords.contains(where: { text.contains($0) }) {
            return true
        }
        
        return false
    }
}
