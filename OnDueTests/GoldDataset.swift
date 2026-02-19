import Foundation
@testable import OnDue

struct GoldDatasetSample {
    let id: String
    let email: ParsedEmail
    let expectedOutcome: ObligationDecision
    let expectedHypothesis: ObligationHypothesis?
    let expectedReason: String
}

enum GoldDataset {
    static let samples: [GoldDatasetSample] = buildSamples()

    private static func buildSamples() -> [GoldDatasetSample] {
        var samples: [GoldDatasetSample] = []

        for index in 1...10 {
            samples.append(
                GoldDatasetSample(
                    id: "payment_due_\(index)",
                    email: makeEmail(
                        subject: "Invoice due March \(10 + index)",
                        snippet: "Payment due by March \(10 + index) to avoid late fees.",
                        body: "Please pay your invoice by March \(10 + index).",
                        senderDomain: "billing.example.com"
                    ),
                    expectedOutcome: .accept,
                    expectedHypothesis: .userActionRequired,
                    expectedReason: "Direct request with a clear deadline"
                )
            )
        }

        for index in 1...10 {
            samples.append(
                GoldDatasetSample(
                    id: "document_request_\(index)",
                    email: makeEmail(
                        subject: "Please sign and return document \(index)",
                        snippet: "Signature required for your document.",
                        body: "Please sign the attached document and return it by Friday.",
                        hasAttachments: true,
                        senderDomain: "forms.example.com"
                    ),
                    expectedOutcome: .accept,
                    expectedHypothesis: .userActionRequired,
                    expectedReason: "Direct request with a clear deadline"
                )
            )
        }

        for index in 1...10 {
            samples.append(
                GoldDatasetSample(
                    id: "marketing_promo_\(index)",
                    email: makeEmail(
                        subject: "Limited time offer \(index)",
                        snippet: "Save now. Unsubscribe anytime.",
                        body: "Special promotion just for you. Unsubscribe here.",
                        labelIds: ["category_promotions"]
                    ),
                    expectedOutcome: .reject,
                    expectedHypothesis: nil,
                    expectedReason: "Marketing email with unsubscribe footer"
                )
            )
        }

        for index in 1...10 {
            samples.append(
                GoldDatasetSample(
                    id: "marketing_with_deadline_\(index)",
                    email: makeEmail(
                        subject: "Sale ends March \(5 + index)",
                        snippet: "Limited time offer until March \(5 + index). Unsubscribe anytime.",
                        body: "Offer ends March \(5 + index). Unsubscribe here.",
                        labelIds: ["category_promotions"]
                    ),
                    expectedOutcome: .reject,
                    expectedHypothesis: nil,
                    expectedReason: "Marketing email with deadline mention"
                )
            )
        }

        for index in 1...10 {
            samples.append(
                GoldDatasetSample(
                    id: "receipt_edge_\(index)",
                    email: makeEmail(
                        subject: "Receipt for your purchase \(index)",
                        snippet: "Thanks for your purchase. Contact us if anything is wrong.",
                        body: "Receipt included. If there is an issue, contact support.",
                        senderDomain: "receipts.example.com"
                    ),
                    expectedOutcome: .reject,
                    expectedHypothesis: nil,
                    expectedReason: "Receipt-only email should be blocked"
                )
            )
        }

        for index in 1...10 {
            samples.append(
                GoldDatasetSample(
                    id: "waiting_on_\(index)",
                    email: makeEmail(
                        subject: "Waiting on approval \(index)",
                        snippet: "We are waiting on approval and will update you.",
                        body: "We are waiting on approval. We'll get back to you soon.",
                        senderDomain: "ops.example.com"
                    ),
                    expectedOutcome: .accept,
                    expectedHypothesis: .waitingOnThirdParty,
                    expectedReason: "Waiting on someone else to respond"
                )
            )
        }

        for index in 1...5 {
            samples.append(
                GoldDatasetSample(
                    id: "date_only_info_\(index)",
                    email: makeEmail(
                        subject: "Calendar update for April \(index)",
                        snippet: "Schedule update for April \(index).",
                        body: "FYI schedule update only. April \(index) is available.",
                        senderDomain: "calendar.example.com"
                    ),
                    expectedOutcome: .reject,
                    expectedHypothesis: nil,
                    expectedReason: "Date-only informational emails should not trigger obligations"
                )
            )
        }

        for index in 1...5 {
            samples.append(
                GoldDatasetSample(
                    id: "urgency_only_promo_\(index)",
                    email: makeEmail(
                        subject: "Urgent: final hours for offer \(index)",
                        snippet: "Act now, limited time offer. Unsubscribe anytime.",
                        body: "Final hours. Act now and save big. Unsubscribe here.",
                        labelIds: ["category_promotions"]
                    ),
                    expectedOutcome: .reject,
                    expectedHypothesis: nil,
                    expectedReason: "Urgency-only promo should remain blocked"
                )
            )
        }

        return samples
    }

    private static func makeEmail(
        subject: String,
        snippet: String,
        body: String,
        hasAttachments: Bool = false,
        labelIds: [String] = ["inbox"],
        senderDomain: String? = "example.com"
    ) -> ParsedEmail {
        let normalizedText = "\(subject)\n\(snippet)\n\(body)"
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedEmail(
            subject: subject,
            snippet: snippet,
            bodyText: body,
            sender: "user@\(senderDomain ?? "example.com")",
            senderDomain: senderDomain,
            hasAttachments: hasAttachments,
            labelIds: labelIds.map { $0.lowercased() },
            normalizedText: normalizedText
        )
    }
}
