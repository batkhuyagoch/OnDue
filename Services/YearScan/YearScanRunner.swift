import Foundation

struct YearScanRunResult {
    let items: [YearScanItem]
    let scannedMessageCount: Int
}

struct YearScanQuotaStoppedError: Error {
    let lastCompletedMonthIndex: Int
    let totalMonths: Int
}

enum YearScanRunner {
    static let coverageSummary = "Inbox, excluding promotions & social"
    private static let scanDays = 365
    private static let pageSize = 500

    static func run(
        environment: AppEnvironment,
        statusUpdate: ((String) -> Void)? = nil
    ) async throws -> YearScanRunResult {
        let accounts = try await environment.mailboxAccountRepository.fetchAll()
        var collected: [YearScanItem] = []
        var scannedMessageCount = 0
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .day, value: -scanDays, to: endDate) ?? endDate
        let monthRanges = buildMonthRanges(startDate: startDate, endDate: endDate)

        Logger.info("YearScan: start (\(accounts.count) accounts)")
        for account in accounts {
            Logger.info("YearScan: backfill start account=\(account.emailAddress)")
            var backfillSavedTotal = 0
            let totalMonths = monthRanges.count
            for (index, range) in monthRanges.enumerated() {
                try Task.checkCancellation()
                let monthIndex = index + 1
                statusUpdate?("Backfilling: \(monthLabel(for: range.start)) (\(monthIndex)/\(totalMonths))")
                let backfillReport: SyncReport
                do {
                    backfillReport = try await environment.gmailSyncCoordinator.backfill(
                        mailboxAccountId: account.id,
                        startDate: range.start,
                        endDate: range.end,
                        daysBackForExtraction: 0
                    )
                } catch {
                    if isQuotaRelatedError(error) {
                        throw YearScanQuotaStoppedError(
                            lastCompletedMonthIndex: index - 1,
                            totalMonths: totalMonths
                        )
                    }
                    throw error
                }
                backfillSavedTotal += backfillReport.messagesSavedCount
                Logger.info(
                    "YearScan: backfill slice account=\(account.emailAddress) month=\(monthIndex)/\(totalMonths) saved=\(backfillReport.messagesSavedCount)"
                )
            }
            Logger.info(
                "YearScan: backfill done account=\(account.emailAddress) saved=\(backfillSavedTotal)"
            )

            var beforeDate: Date?
            var beforePk: Int64?
            var page = 0
            var bestByThread: [String: YearScanItem] = [:]

            while true {
                try Task.checkCancellation()
                statusUpdate?("Scanning inbox...")
                let messages = try await environment.messageRepository.fetchRecentPage(
                    mailboxAccountId: account.id,
                    daysBack: scanDays,
                    beforeDate: beforeDate,
                    beforePk: beforePk,
                    limit: pageSize
                )

                guard !messages.isEmpty else {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) done")
                    break
                }

                page += 1
                scannedMessageCount += messages.count
                statusUpdate?("Scanning inbox... \(scannedMessageCount) messages")

                if let oldest = messages.last?.internalDate {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) messages=\(messages.count) oldest=\(oldest)")
                } else {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) messages=\(messages.count)")
                }

                let scanned = try await environment.obligationExtractor.scanYear(
                    messages: messages,
                    mailboxAccountId: account.id
                )

                for item in scanned {
                    let key = item.threadId ?? item.providerMessageId
                    if let existing = bestByThread[key] {
                        if item.score > existing.score {
                            bestByThread[key] = item
                        }
                    } else {
                        bestByThread[key] = item
                    }
                }

                guard let last = messages.last, let lastPk = last.pk else {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) missing cursor, stopping")
                    break
                }

                beforeDate = last.internalDate
                beforePk = lastPk

                if messages.count < pageSize {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) reached end of range")
                    break
                }
            }

            collected.append(contentsOf: bestByThread.values)
        }

        let sorted = collected.sorted { $0.score > $1.score }
        Logger.info("YearScan: done scanned=\(scannedMessageCount) results=\(sorted.count)")
        return YearScanRunResult(items: sorted, scannedMessageCount: scannedMessageCount)
    }

    private static func buildMonthRanges(startDate: Date, endDate: Date) -> [(start: Date, end: Date)] {
        let calendar = Calendar.current
        var ranges: [(start: Date, end: Date)] = []
        var cursor = startDate

        while cursor < endDate {
            let next = calendar.date(byAdding: .month, value: 1, to: cursor) ?? endDate
            let sliceEnd = min(next, endDate)
            ranges.append((start: cursor, end: sliceEnd))
            cursor = sliceEnd
        }

        return ranges
    }

    private static func monthLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private static func isQuotaRelatedError(_ error: Error) -> Bool {
        if case GmailClientError.apiError(let code, _) = error {
            return code == 429 || code == 403
        }
        return false
    }
}
