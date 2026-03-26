import Foundation
import Combine

enum Logger {
    static func info(_ message: String) {
        print("[OnDue] ℹ️  \(message)")
    }
    
    static func warn(_ message: String) {
        print("[OnDue] ⚠️  \(message)")
    }
    
    static func error(_ message: String) {
        print("[OnDue] ❌ \(message)")
    }
}

enum PerfMetrics {
    struct ScanRunSummary {
        let elapsedSeconds: Double
        let peakMemoryMB: UInt64
        let pagesScanned: Int
        let monthsBackfilled: Int
        let messagesClassified: Int
        let throttleEvents: Int
        let averageBatchSize: Int
    }

    static func logScanRun(_ summary: ScanRunSummary) {
        Logger.info(
            "PerfMetrics.ScanRun | elapsed=\(String(format: "%.1f", summary.elapsedSeconds))s peak=\(summary.peakMemoryMB)MB pages=\(summary.pagesScanned) months=\(summary.monthsBackfilled) classified=\(summary.messagesClassified) throttleEvents=\(summary.throttleEvents) avgBatch=\(summary.averageBatchSize)"
        )
    }

    static func logStageTime(_ stage: String, elapsedMs: Double, detail: String? = nil) {
        let suffix = detail.map { " \($0)" } ?? ""
        Logger.info("PerfMetrics.\(stage) | \(String(format: "%.1f", elapsedMs))ms\(suffix)")
    }
}
