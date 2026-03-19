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
    func deleteAllAccountData(mailboxAccountId: String) async throws
}

/// Deduplicates inflight body fetches by providerMessageId so concurrent requests for the same ID share a single API call.
private actor InflightBodyFetchDeduplicator {
    private var inflightByMessageId: [String: Task<[GmailMessageBody], Error>] = [:]
    
    func fetchBodies(
        messageIDs: [String],
        via fetch: @escaping @Sendable ([String]) async throws -> [GmailMessageBody]
    ) async throws -> [GmailMessageBody] {
        let uniqueIds = Array(Set(messageIDs))
        var toFetch: [String] = []
        var tasksToAwait: [Task<[GmailMessageBody], Error>] = []
        
        for id in uniqueIds {
            if let task = inflightByMessageId[id] {
                tasksToAwait.append(task)
            } else {
                toFetch.append(id)
            }
        }
        
        var results: [GmailMessageBody] = []
        let resultIds = Set(uniqueIds)
        
        if !toFetch.isEmpty {
            let task = Task { try await fetch(toFetch) }
            for id in toFetch {
                inflightByMessageId[id] = task
            }
            defer {
                for id in toFetch {
                    inflightByMessageId.removeValue(forKey: id)
                }
            }
            let bodies = try await task.value
            results = bodies.filter { resultIds.contains($0.messageID) }
        }
        
        for t in tasksToAwait {
            let bodies = try await t.value
            results.append(contentsOf: bodies.filter { resultIds.contains($0.messageID) })
        }
        
        // Deduplicate by message ID in case multiple IDs point to the same inflight task.
        var dedupedById: [String: GmailMessageBody] = [:]
        for body in results {
            dedupedById[body.messageID] = body
        }
        return Array(dedupedById.values)
    }
}

final class GmailSyncService: GmailSyncServicing, @unchecked Sendable {
    private let database: Database
    private let client: GmailClienting
    private let messageRepository: MessageRepositorying
    private let candidateSelector: CandidateSelecting
    private let inflightBodyDeduplicator = InflightBodyFetchDeduplicator()
    
    init(
        database: Database,
        client: GmailClienting = GmailClient(stateManager: MessageStateManager()),
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
        let allIds = Array(Set(result.messageIDs))
        let existingWithBody = try await messageRepository.fetchProviderMessageIdsWithBodyText(
            mailboxAccountId: mailboxAccountId,
            providerMessageIds: allIds
        )
        let idsToFetch = allIds.filter { !existingWithBody.contains($0) }
        let summariesResult: GmailMessageFetchResult
        if idsToFetch.isEmpty {
            summariesResult = GmailMessageFetchResult(messageIDsCount: result.messageIDs.count, summaries: [])
        } else {
            summariesResult = try await client.fetchMessages(messageIDs: idsToFetch)
        }

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
            latestHistoryId: result.latestHistoryId,
            changedMessageIDs: Set(allIds)
        )
    }

    func fetchCurrentHistoryId() async throws -> String {
        try await client.fetchCurrentHistoryId()
    }

    private func hydrateBodiesIfNeeded(summaries: [GmailMessageSummary], mailboxAccountId: String) async throws {
        let messages = summaries.map {
            Self.makeMessageRecord(from: $0, mailboxAccountId: mailboxAccountId, bodyText: nil, bodyHtml: nil, attachmentTypes: nil, hasPdf: false, hasCalendar: false)
        }
        var candidates: [MessageRecord] = []
        for message in messages {
            if await candidateSelector.isCandidate(message) {
                candidates.append(message)
            }
        }
        guard !candidates.isEmpty else { return }

        let candidateIds = candidates.map { $0.providerMessageId }
        let existingWithBody = try await messageRepository.fetchProviderMessageIdsWithBodyText(
            mailboxAccountId: mailboxAccountId,
            providerMessageIds: candidateIds
        )
        let idsToFetch = candidateIds.filter { !existingWithBody.contains($0) }
        guard !idsToFetch.isEmpty else { return }

        let c = client
        let bodies = try await inflightBodyDeduplicator.fetchBodies(messageIDs: idsToFetch) { ids in
            try await c.fetchMessageBodies(messageIDs: ids)
        }
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
    private let yearScanRepository: YearScanRepositorying

    init(
        gmailSyncService: GmailSyncServicing,
        messageRepository: MessageRepositorying,
        obligationExtractor: ObligationExtracting,
        obligationRepository: ObligationRepositorying,
        mailboxAccountRepository: MailboxAccountRepositorying,
        yearScanRepository: YearScanRepositorying
    ) {
        self.gmailSyncService = gmailSyncService
        self.messageRepository = messageRepository
        self.obligationExtractor = obligationExtractor
        self.obligationRepository = obligationRepository
        self.mailboxAccountRepository = mailboxAccountRepository
        self.yearScanRepository = yearScanRepository
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

        let extractionMessages: [MessageRecord]
        if let changedIDs = incrementalResult?.changedMessageIDs, !changedIDs.isEmpty {
            extractionMessages = try await messageRepository.fetchByProviderMessageIds(
                mailboxAccountId: mailboxAccountId,
                providerMessageIds: changedIDs
            )
        } else {
            extractionMessages = try await messageRepository.fetchRecent(
                mailboxAccountId: mailboxAccountId,
                daysBack: daysBack
            )
        }

        let obligations = try await obligationExtractor.extract(
            from: extractionMessages,
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

        var obligationsCount = 0
        if daysBackForExtraction > 0 {
            let recentMessages = try await messageRepository.fetchRecent(
                mailboxAccountId: mailboxAccountId,
                daysBack: daysBackForExtraction
            )
            let obligations = try await obligationExtractor.extract(
                from: recentMessages,
                mailboxAccountId: mailboxAccountId
            )
            try await obligationRepository.save(obligations)
            obligationsCount = obligations.count
        }

        AppLog.info(
            "SyncCoordinator.backfill.complete",
            fields: [
                "mailboxAccountId": mailboxAccountId,
                "startDate": startDate,
                "endDate": endDate,
                "messageIDs": syncResult.messageIDsCount,
                "messagesSaved": syncResult.messagesSavedCount,
                "obligations": obligationsCount
            ]
        )
        return SyncReport(
            messageIDsCount: syncResult.messageIDsCount,
            messagesSavedCount: syncResult.messagesSavedCount,
            obligationsCount: obligationsCount,
            deletedOldMessagesCount: 0
        )
    }

    func resetLocalCache(mailboxAccountId: String) async throws -> Int {
        var deleted = try await messageRepository.deleteAll(for: mailboxAccountId)
        var usedFallback = false

        // If the supplied account id is stale, clear cache across all known accounts.
        if deleted == 0 {
            let allAccounts = try await mailboxAccountRepository.fetchAll()
            for account in allAccounts where account.id != mailboxAccountId {
                deleted += try await messageRepository.deleteAll(for: account.id)
            }
            usedFallback = !allAccounts.isEmpty
        }

        AppLog.info(
            "SyncCoordinator.resetLocalCache",
            fields: [
                "mailboxAccountId": mailboxAccountId,
                "deleted": deleted,
                "usedFallback": usedFallback
            ]
        )
        return deleted
    }

    func deleteAllAccountData(mailboxAccountId: String) async throws {
        try await yearScanRepository.clearState()
        if let _ = try await mailboxAccountRepository.fetch(byId: mailboxAccountId) {
            try await mailboxAccountRepository.delete(id: mailboxAccountId)
            AppLog.info(
                "SyncCoordinator.deleteAllAccountData",
                fields: ["mailboxAccountId": mailboxAccountId, "scope": "single"]
            )
            return
        }

        // Fallback for stale ids: remove every local mailbox account.
        let allAccounts = try await mailboxAccountRepository.fetchAll()
        for account in allAccounts {
            try await mailboxAccountRepository.delete(id: account.id)
        }
        AppLog.info(
            "SyncCoordinator.deleteAllAccountData",
            fields: [
                "mailboxAccountId": mailboxAccountId,
                "scope": "all",
                "deletedAccountCount": allAccounts.count
            ]
        )
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
    let changedMessageIDs: Set<String>
}

struct SyncReport {
    let messageIDsCount: Int
    let messagesSavedCount: Int
    let obligationsCount: Int
    let deletedOldMessagesCount: Int
}
