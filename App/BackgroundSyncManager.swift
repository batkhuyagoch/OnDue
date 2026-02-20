import Foundation
import BackgroundTasks
import os

enum BackgroundSyncManager {
    static let taskIdentifier = "com.ondue.refresh"
    static let defaultEarliestInterval: TimeInterval = 60 * 60 * 6

    static func register(environmentProvider: @escaping () -> AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask, environment: environmentProvider())
        }
    }

    static func schedule(earliestInterval: TimeInterval = defaultEarliestInterval) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NotificationCenter.default.post(
                name: .syncLog,
                object: "⚠️ Background sync schedule failed: \(error.localizedDescription)"
            )
        }
    }

    private static func handle(_ task: BGAppRefreshTask, environment: AppEnvironment) {
        scheduleIfEnabled(environment: environment)

        let work = Task {
            let restored = (try? await environment.gmailAuthService.restorePreviousSignIn()) ?? false
            guard restored else {
                task.setTaskCompleted(success: false)
                AppLog.debug("BackgroundSync.restoreFailed")
                return
            }

            guard let account = try? await environment.mailboxAccountRepository.fetchFirst(provider: .gmail) else {
                task.setTaskCompleted(success: false)
                AppLog.debug("BackgroundSync.noAccount")
                return
            }

            do {
                let report = try await environment.gmailSyncCoordinator.sync(
                    mailboxAccountId: account.id,
                    daysBack: environment.syncPolicyStore.defaultSyncRange.days,
                    forceFullSync: false
                )
                AppLog.info(
                    "BackgroundSync.complete",
                    fields: [
                        "mailboxAccountId": account.id,
                        "messageIDs": report.messageIDsCount,
                        "messagesSaved": report.messagesSavedCount,
                        "obligations": report.obligationsCount
                    ]
                )
                task.setTaskCompleted(success: true)
            } catch {
                AppLog.error(
                    "BackgroundSync.failed",
                    fields: ["error": error.localizedDescription]
                )
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

    static func scheduleIfEnabled(environment: AppEnvironment) {
        guard environment.syncPolicyStore.backgroundSyncEnabled else { return }
        let interval = TimeInterval(environment.syncPolicyStore.backgroundIntervalHours * 60 * 60)
        schedule(earliestInterval: max(interval, 60 * 30))
    }

    static func cancelAllPendingTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: YearScanBackgroundManager.taskIdentifier)
    }
}

enum AppLog {
    private static let subsystem = "com.ondue.app"
    private static let syncLogger = OSLog(subsystem: subsystem, category: "sync")

    static func info(_ message: String, fields: [String: CustomStringConvertible] = [:]) {
        log(.info, message, fields: fields)
    }

    static func debug(_ message: String, fields: [String: CustomStringConvertible] = [:]) {
        log(.debug, message, fields: fields)
    }

    static func error(_ message: String, fields: [String: CustomStringConvertible] = [:]) {
        log(.error, message, fields: fields)
    }

    private static func log(_ level: OSLogType, _ message: String, fields: [String: CustomStringConvertible]) {
        let payload = format(message: message, fields: fields)
        os_log("%{public}@", log: syncLogger, type: level, payload)
        print("🧾", payload)
        NotificationCenter.default.post(name: .syncLog, object: payload)
    }

    private static func format(message: String, fields: [String: CustomStringConvertible]) -> String {
        guard !fields.isEmpty else { return message }
        let sorted = fields.sorted { $0.key < $1.key }
        let suffix = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(message) | \(suffix)"
    }
}
