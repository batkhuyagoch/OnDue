import Foundation

// MARK: - Manual Promotion Extension

extension ObligationRepository {
    
    /// Manually promote a message to an obligation, even if it didn't score high enough
    func promoteManually(
        messageId: String,
        mailboxAccountId: String,
        environment: AppEnvironment
    ) async throws -> ObligationItem {
        // Fetch the message
        guard let messageRecord = try await environment.messageRepository.fetchByProviderMessageId(messageId) else {
            throw ManualPromotionError.messageNotFound
        }
        guard let messagePk = messageRecord.pk else {
            throw ManualPromotionError.messageMissingPk
        }
        
        // Parse and assess the email
        let parser = EmailParser()
        let parsed = parser.parse(message: messageRecord)
        
        let ruleEngine = RuleEngine(preferences: environment.filterPreferencesStore)
        let weightMultipliers = try await environment.ruleWeightRepository.fetchMultipliers(
            mailboxAccountId: mailboxAccountId
        )
        let assessment = ruleEngine.assess(email: parsed, weightMultipliers: weightMultipliers)
        
        // Create obligation with "manually promoted" flag (boosted confidence)
        let domain = (messageRecord.fromDomain ?? "unknown").lowercased()
        let ruleKey = assessment.matchedRuleIds.map { $0.lowercased() }.sorted().joined(separator: "|")
        let obligationKey = "\(mailboxAccountId)|\(domain)|\(ruleKey)"
        
        let record = ObligationRecord(
            mailboxAccountId: mailboxAccountId,
            messagePk: messagePk,
            category: assessment.category,
            title: messageRecord.subject,
            deadlineAt: assessment.deadline,
            risk: assessment.risk,
            whoOwes: .me,
            confidence: min(1.0, assessment.confidence + 0.3), // Boost confidence for manual promotion
            evidenceQuote: assessment.evidenceQuote,
            obligationKey: obligationKey,
            score: max(assessment.score, 2.0), // Ensure it's above threshold
            matchedRuleIds: assessment.matchedRuleIds.joined(separator: ","),
            matchedSignalTypes: assessment.matchedSignalTypes.map { $0.rawValue }.joined(separator: ","),
            matchedReasons: assessment.matchedReasons.joined(separator: ";"),
            repeatCount: 1,
            lastSeenAt: messageRecord.internalDate
        )
        
        try await save(record)
        
        return ObligationItem(record: record)
    }
}

enum ManualPromotionError: LocalizedError {
    case messageNotFound
    case messageMissingPk
    
    var errorDescription: String? {
        switch self {
        case .messageNotFound:
            return "Message not found in database"
        case .messageMissingPk:
            return "Message is missing a database identifier"
        }
    }
}

// MARK: - Manual Promotion UI

import SwiftUI

struct ManualPromotionSheet: View {
    let messageId: String
    let environment: AppEnvironment
    @Binding var isPresented: Bool
    
    @State private var isPromoting = false
    @State private var error: Error?
    @State private var success = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if success {
                    successView
                } else {
                    promptView
                }
            }
            .padding()
            .navigationTitle("Promote to Important")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
            }
            .alert(error: $error)
        }
    }
    
    private var promptView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)
            
            Text("Add this email to your important items?")
                .font(.headline)
            
            Text("This will mark it as an obligation and show it in your timeline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
            
            Button {
                Task {
                    await promote()
                }
            } label: {
                if isPromoting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Promote to Important")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPromoting)
        }
    }
    
    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            
            Text("Added to Important Items")
                .font(.headline)
            
            Text("You can now find this in your Timeline and Important views.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
            
            Button {
                isPresented = false
            } label: {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private func promote() async {
        isPromoting = true
        defer { isPromoting = false }
        
        do {
            // Get mailbox account ID from environment
            // You may need to adjust this based on how you store the current account
            let mailboxAccountId = "default" // TODO: Get from environment
            
            _ = try await environment.obligationRepository.promoteManually(
                messageId: messageId,
                mailboxAccountId: mailboxAccountId,
                environment: environment
            )
            
            success = true
        } catch {
            self.error = error
        }
    }
}

