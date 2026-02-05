import Foundation

protocol GmailSyncServicing: Sendable {
    func initialSync(mailboxAccountId: String, daysBack: Int) async throws -> GmailSyncResult
    func initialSync(mailboxAccountId: String, startDate: Date, endDate: Date) async throws -> GmailSyncResult
    func incrementalSync(mailboxAccountId: String, startHistoryId: String) async throws -> GmailIncrementalSyncResult
    func fetchCurrentHistoryId() async throws -> String
}

protocol GmailSyncCoordinating: Sendable {
    func sync(mailboxAccountId: String, daysBack: Int, forceFullSync: Bool) async throws -> SyncReport
    func backfill(mailboxAccountId: String, startDate: Date, endDate: Date, daysBackForExtraction: Int) async throws -> SyncReport
    func resetLocalCache(mailboxAccountId: String) async throws -> Int
}

final class GmailSyncService: GmailSyncServicing, @unchecked Sendable {
    private let database: Database
    private let client: GmailClienting
    private let messageRepository: MessageRepositorying
    private let candidateSelector: CandidateSelecting
    
    init(
        database: Database,
        client: GmailClienting = GmailClient(),
        candidateSelector: CandidateSelecting = CandidateSelector(preferences: FilterPreferencesStore())
    ) {
        self.database = database
        self.client = client
        self.messageRepository = MessageRepository(database: database)
        self.candidateSelector = candidateSelector
    }
    
    func initialSync(mailboxAccountId: String, daysBack: Int) async throws -> GmailSyncResult {
        let result = try await client.fetchMessages(daysBack: daysBack)
        let messages = result.summaries.map {
            Self.makeMessageRecord(
                from: $0,
                mailboxAccountId: mailboxAccountId,
                bodyText: nil,
                bodyHtml: nil,
                attachmentTypes: nil,
                hasPdf: false,
                hasCalendar: false
            )
        }
        try await messageRepository.save(messages)
        try await hydrateBodiesIfNeeded(summaries: result.summaries, mailboxAccountId: mailboxAccountId)
        return GmailSyncResult(messageIDsCount: result.messageIDsCount, messagesSavedCount: messages.count)
    }
    
    func initialSync(mailboxAccountId: String, startDate: Date, endDate: Date) async throws -> GmailSyncResult {
        let result = try await client.fetchMessages(startDate: startDate, endDate: endDate)
        let messages = result.summaries.map {
            Self.makeMessageRecord(
                from: $0,
                mailboxAccountId: mailboxAccountId,
                bodyText: nil,
                bodyHtml: nil,
                attachmentTypes: nil,
                hasPdf: false,
                hasCalendar: false
            )
        }
        try await messageRepository.save(messages)
        try await hydrateBodiesIfNeeded(summaries: result.summaries, mailboxAccountId: mailboxAccountId)
        return GmailSyncResult(messageIDsCount: result.messageIDsCount, messagesSavedCount: messages.count)
    }
    
    func incrementalSync(mailboxAccountId: String, startHistoryId: String) async throws -> GmailIncrementalSyncResult {
        let result = try await client.fetchChangedMessageIDs(startHistoryId: startHistoryId)
        let summariesResult = try await client.fetchMessages(messageIDs: result.messageIDs)

        let messages = summariesResult.summaries.map {
            Self.makeMessageRecord(
                from: $0,
                mailboxAccountId: mailboxAccountId,
                bodyText: nil,
                bodyHtml: nil,
                attachmentTypes: nil,
                hasPdf: false,
                hasCalendar: false
            )
        }
        try await messageRepository.save(messages)
        try await hydrateBodiesIfNeeded(summaries: summariesResult.summaries, mailboxAccountId: mailboxAccountId)
        return GmailIncrementalSyncResult(
            messageIDsCount: result.messageIDs.count,
            messagesSavedCount: messages.count,
            latestHistoryId: result.latestHistoryId
        )
    }

    func fetchCurrentHistoryId() async throws -> String {
        try await client.fetchCurrentHistoryId()
    }

    private func hydrateBodiesIfNeeded(summaries: [GmailMessageSummary], mailboxAccountId: String) async throws {
        let messages = summaries.map {
            Self.makeMessageRecord(from: $0, mailboxAccountId: mailboxAccountId, bodyText: nil, bodyHtml: nil, attachmentTypes: nil, hasPdf: false, hasCalendar: false)
        }
        let candidates = messages.filter { candidateSelector.isCandidate($0) }
        guard !candidates.isEmpty else { return }

        let candidateIds = candidates.map { $0.providerMessageId }
        let existingWithBody = try await messageRepository.fetchProviderMessageIdsWithBodyText(
            mailboxAccountId: mailboxAccountId,
            providerMessageIds: candidateIds
        )
        let idsToFetch = candidateIds.filter { !existingWithBody.contains($0) }
        guard !idsToFetch.isEmpty else { return }

        let bodies = try await client.fetchMessageBodies(messageIDs: idsToFetch)
        guard !bodies.isEmpty else { return }

        let summaryById = Dictionary(uniqueKeysWithValues: summaries.map { ($0.messageID, $0) })
        let updated = bodies.compactMap { body -> MessageRecord? in
            guard let summary = summaryById[body.messageID] else { return nil }
            return Self.makeMessageRecord(
                from: summary,
                mailboxAccountId: mailboxAccountId,
                bodyText: body.bodyText,
                bodyHtml: body.bodyHtml,
                attachmentTypes: body.attachmentTypes.joined(separator: ","),
                hasPdf: body.hasPdf,
                hasCalendar: body.hasCalendar
            )
        }
        try await messageRepository.save(updated)
    }

    private static func makeMessageRecord(
        from summary: GmailMessageSummary,
        mailboxAccountId: String,
        bodyText: String?,
        bodyHtml: String?,
        attachmentTypes: String?,
        hasPdf: Bool,
        hasCalendar: Bool
    ) -> MessageRecord {
        MessageRecord(
            mailboxAccountId: mailboxAccountId,
            providerMessageId: summary.messageID,
            threadId: summary.threadID,
            internalDate: summary.receivedAt,
            fromEmail: summary.sender,
            fromName: summary.senderName,
            subject: summary.subject,
            snippet: summary.snippet,
            bodyText: bodyText,
            bodyHtml: bodyHtml,
            hasAttachments: summary.hasAttachments,
            attachmentTypes: attachmentTypes,
            hasPdf: hasPdf,
            hasCalendar: hasCalendar,
            labelIds: summary.labelIDs.joined(separator: ",")
        )
    }
}

final class GmailSyncCoordinator: GmailSyncCoordinating, @unchecked Sendable {
    private let gmailSyncService: GmailSyncServicing
    private let messageRepository: MessageRepositorying
    private let obligationExtractor: ObligationExtracting
    private let obligationRepository: ObligationRepositorying
    private let mailboxAccountRepository: MailboxAccountRepositorying

    init(
        gmailSyncService: GmailSyncServicing,
        messageRepository: MessageRepositorying,
        obligationExtractor: ObligationExtracting,
        obligationRepository: ObligationRepositorying,
        mailboxAccountRepository: MailboxAccountRepositorying
    ) {
        self.gmailSyncService = gmailSyncService
        self.messageRepository = messageRepository
        self.obligationExtractor = obligationExtractor
        self.obligationRepository = obligationRepository
        self.mailboxAccountRepository = mailboxAccountRepository
    }

    func sync(mailboxAccountId: String, daysBack: Int, forceFullSync: Bool) async throws -> SyncReport {
        let deletedCount = try await messageRepository.softDeleteOlderThan(
            mailboxAccountId: mailboxAccountId,
            daysBack: daysBack
        )

        let account = try await mailboxAccountRepository.fetch(byId: mailboxAccountId)
        var syncResult: GmailSyncResult?
        var incrementalResult: GmailIncrementalSyncResult?

        if let historyId = account?.gmailLastHistoryId, forceFullSync == false {
            do {
                incrementalResult = try await gmailSyncService.incrementalSync(
                    mailboxAccountId: mailboxAccountId,
                    startHistoryId: historyId
                )
                let updatedHistoryId = incrementalResult?.latestHistoryId ?? historyId
                try await mailboxAccountRepository.updateSyncMetadata(
                    id: mailboxAccountId,
                    gmailLastHistoryId: updatedHistoryId,
                    lastFullSyncAt: account?.lastFullSyncAt
                )
            } catch GmailClientError.apiError(let code, _) where code == 404 {
                syncResult = try await gmailSyncService.initialSync(
                    mailboxAccountId: mailboxAccountId,
                    daysBack: daysBack
                )
                let historyId = try await gmailSyncService.fetchCurrentHistoryId()
                try await mailboxAccountRepository.updateSyncMetadata(
                    id: mailboxAccountId,
                    gmailLastHistoryId: historyId,
                    lastFullSyncAt: Date()
                )
            }
        } else {
            syncResult = try await gmailSyncService.initialSync(
                mailboxAccountId: mailboxAccountId,
                daysBack: daysBack
            )
            let historyId = try await gmailSyncService.fetchCurrentHistoryId()
            try await mailboxAccountRepository.updateSyncMetadata(
                id: mailboxAccountId,
                gmailLastHistoryId: historyId,
                lastFullSyncAt: Date()
            )
        }

        let recentMessages = try await messageRepository.fetchRecent(
            mailboxAccountId: mailboxAccountId,
            daysBack: daysBack
        )
        let obligations = try await obligationExtractor.extract(
            from: recentMessages,
            mailboxAccountId: mailboxAccountId
        )
        try await obligationRepository.save(obligations)

        let messageIDsCount = incrementalResult?.messageIDsCount ?? syncResult?.messageIDsCount ?? 0
        let messagesSavedCount = incrementalResult?.messagesSavedCount ?? syncResult?.messagesSavedCount ?? 0
        AppLog.info(
            "SyncCoordinator.sync.complete",
            fields: [
                "mailboxAccountId": mailboxAccountId,
                "daysBack": daysBack,
                "messageIDs": messageIDsCount,
                "messagesSaved": messagesSavedCount,
                "obligations": obligations.count,
                "softDeleted": deletedCount
            ]
        )
        return SyncReport(
            messageIDsCount: messageIDsCount,
            messagesSavedCount: messagesSavedCount,
            obligationsCount: obligations.count,
            deletedOldMessagesCount: deletedCount
        )
    }

    func backfill(mailboxAccountId: String, startDate: Date, endDate: Date, daysBackForExtraction: Int) async throws -> SyncReport {
        let syncResult = try await gmailSyncService.initialSync(
            mailboxAccountId: mailboxAccountId,
            startDate: startDate,
            endDate: endDate
        )
        let historyId = try await gmailSyncService.fetchCurrentHistoryId()
        try await mailboxAccountRepository.updateSyncMetadata(
            id: mailboxAccountId,
            gmailLastHistoryId: historyId,
            lastFullSyncAt: Date()
        )

        let recentMessages = try await messageRepository.fetchRecent(
            mailboxAccountId: mailboxAccountId,
            daysBack: daysBackForExtraction
        )
        let obligations = try await obligationExtractor.extract(
            from: recentMessages,
            mailboxAccountId: mailboxAccountId
        )
        try await obligationRepository.save(obligations)

        AppLog.info(
            "SyncCoordinator.backfill.complete",
            fields: [
                "mailboxAccountId": mailboxAccountId,
                "startDate": startDate,
                "endDate": endDate,
                "messageIDs": syncResult.messageIDsCount,
                "messagesSaved": syncResult.messagesSavedCount,
                "obligations": obligations.count
            ]
        )
        return SyncReport(
            messageIDsCount: syncResult.messageIDsCount,
            messagesSavedCount: syncResult.messagesSavedCount,
            obligationsCount: obligations.count,
            deletedOldMessagesCount: 0
        )
    }

    func resetLocalCache(mailboxAccountId: String) async throws -> Int {
        let deleted = try await messageRepository.deleteAll(for: mailboxAccountId)
        AppLog.info(
            "SyncCoordinator.resetLocalCache",
            fields: ["mailboxAccountId": mailboxAccountId, "deleted": deleted]
        )
        return deleted
    }
}

struct GmailSyncResult {
    let messageIDsCount: Int
    let messagesSavedCount: Int
}

struct GmailIncrementalSyncResult {
    let messageIDsCount: Int
    let messagesSavedCount: Int
    let latestHistoryId: String?
}

struct SyncReport {
    let messageIDsCount: Int
    let messagesSavedCount: Int
    let obligationsCount: Int
    let deletedOldMessagesCount: Int
}
