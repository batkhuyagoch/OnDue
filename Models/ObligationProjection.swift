import Foundation
import GRDB

enum ObligationLifecycleState: String, Codable, CaseIterable, DatabaseValueConvertible {
    case needsReview
    case active
    case overdue
    case snoozed
    case resolved
    case suppressed
}

enum ObligationDueBucket: String, Codable, CaseIterable, DatabaseValueConvertible {
    case overdue
    case today
    case next3Days
    case next7Days
    case later
    case noDueDate

    var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .next3Days: "Next 3 Days"
        case .next7Days: "Next 7 Days"
        case .later: "Later"
        case .noDueDate: "No Due Date"
        }
    }
}

struct ObligationProjectionRecord: Identifiable, Hashable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "obligation_projection"

    var obligationId: String
    var state: ObligationLifecycleState
    var confidence: Double
    var dueDate: Date?
    var dueBucket: ObligationDueBucket
    var primaryThreadId: String?
    var lastActionAt: Date?
    var reasonCode: String?
    var policyVersion: String?
    var surfacingIntent: SurfacingIntent?
    var updatedAt: Date

    var id: String { obligationId }
}

struct ObligationListItem: Identifiable, Hashable {
    let obligation: ObligationItem
    let state: ObligationLifecycleState
    let dueBucket: ObligationDueBucket
    let primaryThreadId: String?
    let lastActionAt: Date?
    let senderEmail: String?
    let senderDomain: String?
    let surfacingIntent: SurfacingIntent?

    var id: String { obligation.id }
}
