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

    static func scheduleBackfill() {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLog.info("YearScanBackground.scheduleFailed", fields: ["error": error.localizedDescription])
        }
    }

    private static func handle(_ task: BGProcessingTask, environment: AppEnvironment) {
        guard environment.syncPolicyStore.longScanAndBackgroundOptIn else {
            AppLog.debug("YearScanBackground.skippedNotOptedIn")
            task.setTaskCompleted(success: true)
            return
        }
        scheduleBackfill()

        let work = Task {
            let restored = (try? await environment.gmailAuthService.restorePreviousSignIn()) ?? false
            guard restored else {
                AppLog.debug("YearScanBackground.restoreFailed")
                task.setTaskCompleted(success: false)
                return
            }

            guard let account = try? await environment.mailboxAccountRepository.fetchFirst(provider: .gmail) else {
                AppLog.debug("YearScanBackground.noAccount")
                task.setTaskCompleted(success: false)
                return
            }

            do {
                AppLog.info("YearScanBackground.start", fields: ["account": account.emailAddress])
                try await environment.yearScanRepository.markInProgress(
                    scannedMessageCount: 0,
                    coverageSummary: YearScanRunner.coverageSummary,
                    statusMessage: "Running in background..."
                )
                let runResult = try await YearScanRunner.run(environment: environment)
                try await environment.yearScanRepository.saveRun(
                    items: runResult.items,
                    scannedMessageCount: runResult.scannedMessageCount,
                    lastChecked: Date(),
                    coverageSummary: YearScanRunner.coverageSummary
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
            } catch {
                AppLog.error("YearScanBackground.failed", fields: ["error": error.localizedDescription])
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

}
