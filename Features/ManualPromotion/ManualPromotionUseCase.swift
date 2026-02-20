import Foundation

protocol ManualPromotionUseCaseing: Sendable {
    func promote(messageId: String, mailboxAccountId: String) async throws -> ObligationItem
}

struct ManualPromotionUseCase: ManualPromotionUseCaseing {
    private let messageRepository: MessageRepositorying
    private let obligationExtractor: ObligationExtracting
    private let obligationRepository: ObligationRepositorying

    init(
        messageRepository: MessageRepositorying,
        obligationExtractor: ObligationExtracting,
        obligationRepository: ObligationRepositorying
    ) {
        self.messageRepository = messageRepository
        self.obligationExtractor = obligationExtractor
        self.obligationRepository = obligationRepository
    }

    func promote(messageId: String, mailboxAccountId: String) async throws -> ObligationItem {
        guard let message = try await messageRepository.fetchByProviderMessageId(messageId) else {
            throw ManualPromotionError.messageNotFound
        }
        guard message.pk != nil else {
            throw ManualPromotionError.messageMissingPk
        }

        let assessment = try await obligationExtractor.assess(
            message: message,
            mailboxAccountId: mailboxAccountId
        )

        return try await obligationRepository.promoteManually(
            message: message,
            mailboxAccountId: mailboxAccountId,
            assessment: assessment
        )
    }
}

extension AppEnvironment {
    var manualPromotionUseCase: ManualPromotionUseCaseing {
        ManualPromotionUseCase(
            messageRepository: messageRepository,
            obligationExtractor: obligationExtractor,
            obligationRepository: obligationRepository
        )
    }
}
