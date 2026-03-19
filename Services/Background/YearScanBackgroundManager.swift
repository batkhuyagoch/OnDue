import Foundation
import BackgroundTasks

enum YearScanBackgroundManager {
    static let taskIdentifier = "com.ondue.yearscan"
    private static let earliestInterval: TimeInterval = 60 * 5
    static func register(environmentProvider: @escaping () -> AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(processingTask, environment: environmentProvider())
        }
    }

    static func scheduleBackfill(requiresCharging: Bool = false) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = requiresCharging
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.info("YearScanBackground.scheduleFailed", fields: ["error": error.localizedDescription])
        }
    }

    static func backgroundStatus(for resumeState: YearScanResumeState?) -> String {
        guard let resumeState else {
            return "Running in background..."
        }
        switch resumeState.phase {
        case .backfill:
            let month = min(resumeState.monthIndex + 1, max(resumeState.totalMonths, 1))
            return "Resuming in background at month \(month) of \(max(resumeState.totalMonths, 1))..."
        case .scanning:
            return "Resuming in background while scanning inbox..."
        }
    }

    static func scannedCount(from status: String) -> Int? {
        let pattern = #"Scanning inbox\.\.\. ([0-9]+) messages"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(status.startIndex..<status.endIndex, in: status)
        guard let match = regex.firstMatch(in: status, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: status) else {
            return nil
        }
        return Int(status[range])
    }

    private static func handle(_ task: BGProcessingTask, environment: AppEnvironment) {
        guard environment.syncPolicyStore.longScanAndBackgroundOptIn else {
            AppLog.debug("YearScanBackground.skippedNotOptedIn")
            task.setTaskCompleted(success: true)
            return
        }
        scheduleBackfill(requiresCharging: environment.syncPolicyStore.coverageBackgroundRequiresCharging)
        var latestCheckpoint: YearScanResumeState?
        var latestScannedCount: Int = 0
        var latestStatusMessage: String?
        let runToken = UUID().uuidString
        var partialSequence = 0

        let work = Task {
            let restored = (try? await environment.gmailAuthService.restorePreviousSignIn()) ?? false
            guard restored else {
                AppLog.debug("YearScanBackground.restoreFailed")
                task.setTaskCompleted(success: false)
                return
            }

            let hydratedAccount: MailboxAccountRecord?
            if let email = environment.gmailAuthService.userEmail, !email.isEmpty {
                hydratedAccount = try? await environment.mailboxAccountRepository.getOrCreate(email: email, provider: .gmail)
            } else {
                hydratedAccount = try? await environment.mailboxAccountRepository.fetchFirst(provider: .gmail)
            }

            guard let account = hydratedAccount else {
                AppLog.debug("YearScanBackground.noAccount")
                task.setTaskCompleted(success: false)
                return
            }

            let runConfiguration = YearScanRunner.RunConfiguration.from(policy: environment.syncPolicyStore)
            do {
                let resumeState = try await environment.yearScanRepository.fetchResumeState()
                latestCheckpoint = resumeState
                latestScannedCount = resumeState?.scannedMessageCount ?? 0
                let initialStatus = backgroundStatus(for: resumeState)
                latestStatusMessage = initialStatus
                let resumed = resumeState != nil

                AppLog.info(
                    "YearScanBackground.start",
                    fields: [
                        "account": account.emailAddress,
                        "resumed": resumed,
                        "rangeMonths": runConfiguration.rangeMonths,
                        "intensity": runConfiguration.intensity.rawValue,
                        "resumePhase": resumeState?.phase.rawValue ?? "none",
                        "resumeMonthIndex": resumeState?.monthIndex ?? -1,
                        "resumeAccountIndex": resumeState?.accountIndex ?? -1
                    ]
                )
                try await environment.yearScanRepository.markInProgress(
                    scannedMessageCount: latestScannedCount,
                    coverageSummary: YearScanRunner.coverageSummary,
                    statusMessage: initialStatus,
                    resumeState: resumeState,
                    scanRangeMonths: runConfiguration.rangeMonths,
                    scanIntensity: runConfiguration.intensity.rawValue
                )
                let runResult = try await YearScanCoordinator.run(
                    environment: environment,
                    resumeState: resumeState,
                    configuration: runConfiguration,
                    statusUpdate: { status in
                        if let count = scannedCount(from: status) {
                            latestScannedCount = count
                        }
                        latestStatusMessage = status
                    },
                    checkpointUpdate: { checkpoint in
                        latestCheckpoint = checkpoint
                        latestScannedCount = checkpoint.scannedMessageCount
                        latestStatusMessage = checkpoint.lastStatusMessage
                        partialSequence += 1
                        let sequence = partialSequence
                        Task {
                            try? await environment.yearScanRepository.upsertPartial(
                                items: [],
                                scannedMessageCount: latestScannedCount,
                                coverageSummary: YearScanRunner.coverageSummary,
                                statusMessage: checkpoint.lastStatusMessage,
                                resumeState: checkpoint,
                                scanRangeMonths: runConfiguration.rangeMonths,
                                scanIntensity: runConfiguration.intensity.rawValue,
                                excludedProviderMessageIds: [],
                                runToken: runToken,
                                sequence: sequence
                            )
                        }
                    },
                    partialUpdate: { update in
                        latestCheckpoint = update.resumeState
                        latestScannedCount = update.scannedMessageCount
                        latestStatusMessage = update.statusMessage
                        partialSequence += 1
                        let sequence = partialSequence
                        Task {
                            let excluded = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 3.0)) ?? []
                            try? await environment.yearScanRepository.upsertPartial(
                                items: update.items,
                                scannedMessageCount: update.scannedMessageCount,
                                coverageSummary: YearScanRunner.coverageSummary,
                                statusMessage: update.statusMessage,
                                resumeState: update.resumeState,
                                scanRangeMonths: runConfiguration.rangeMonths,
                                scanIntensity: runConfiguration.intensity.rawValue,
                                excludedProviderMessageIds: excluded,
                                runToken: runToken,
                                sequence: sequence
                            )
                        }
                    }
                )
                await environment.yearScanRepository.markRunFinalized(runToken: runToken)
                let excluded = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 0)) ?? []
                try await environment.yearScanRepository.saveRun(
                    items: runResult.items,
                    scannedMessageCount: runResult.scannedMessageCount,
                    lastChecked: Date(),
                    coverageSummary: YearScanRunner.coverageSummary,
                    scanRangeMonths: runConfiguration.rangeMonths,
                    scanIntensity: runConfiguration.intensity.rawValue,
                    excludedProviderMessageIds: excluded
                )
                await YearScanCoordinator.bridgePromotedFindingsToObligations(
                    environment: environment,
                    items: runResult.items
                )
                AppLog.info(
                    "YearScanBackground.complete",
                    fields: [
                        "account": account.emailAddress,
                        "messagesScanned": runResult.scannedMessageCount,
                        "results": runResult.items.count
                    ]
                )
                task.setTaskCompleted(success: true)
            } catch let quota as YearScanQuotaStoppedError {
                AppLog.info(
                    "YearScanBackground.pausedQuota",
                    fields: [
                        "monthIndex": quota.resumeState.monthIndex,
                        "totalMonths": quota.resumeState.totalMonths
                    ]
                )
                await YearScanCoordinator.persistPaused(
                    environment: environment,
                    scannedMessageCount: quota.resumeState.scannedMessageCount,
                    statusMessage: "Paused in background due to Gmail API limits.",
                    resumeState: quota.resumeState,
                    configuration: runConfiguration
                )
                scheduleBackfill(requiresCharging: environment.syncPolicyStore.coverageBackgroundRequiresCharging)
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                await YearScanCoordinator.persistPaused(
                    environment: environment,
                    scannedMessageCount: latestScannedCount,
                    statusMessage: latestStatusMessage ?? "Paused in background. Will resume later.",
                    resumeState: latestCheckpoint,
                    configuration: runConfiguration
                )
                scheduleBackfill(requiresCharging: environment.syncPolicyStore.coverageBackgroundRequiresCharging)
                task.setTaskCompleted(success: true)
            } catch {
                AppLog.error("YearScanBackground.failed", fields: ["error": error.localizedDescription])
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            Task {
                await YearScanCoordinator.persistPaused(
                    environment: environment,
                    scannedMessageCount: latestScannedCount,
                    statusMessage: latestStatusMessage ?? "Paused in background due to device constraints. Will resume later.",
                    resumeState: latestCheckpoint,
                    configuration: YearScanRunner.RunConfiguration.from(policy: environment.syncPolicyStore)
                )
            }
            work.cancel()
        }
    }

}
