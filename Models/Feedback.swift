import Foundation
import GRDB

struct FeedbackRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "feedback"
    
    var id: String
    var mailboxAccountId: String
    var messagePk: Int64?
    var obligationId: String?
    var action: FeedbackAction
    var reason: String?
    var matchedRuleIds: String?
    var primaryHypothesisId: String?
    var senderDomainClass: String?
    var labelCluster: String?
    var threadPattern: String?
    var exposureTimestamp: Date?
    var actionTimestamp: Date?
    var createdAt: Date
    
    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        messagePk: Int64? = nil,
        obligationId: String? = nil,
        action: FeedbackAction,
        reason: String? = nil,
        matchedRuleIds: String? = nil,
        primaryHypothesisId: String? = nil,
        senderDomainClass: String? = nil,
        labelCluster: String? = nil,
        threadPattern: String? = nil,
        exposureTimestamp: Date? = nil,
        actionTimestamp: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.messagePk = messagePk
        self.obligationId = obligationId
        self.action = action
        self.reason = reason
        self.matchedRuleIds = matchedRuleIds
        self.primaryHypothesisId = primaryHypothesisId
        self.senderDomainClass = senderDomainClass
        self.labelCluster = labelCluster
        self.threadPattern = threadPattern
        self.exposureTimestamp = exposureTimestamp
        self.actionTimestamp = actionTimestamp
        self.createdAt = createdAt
    }
    
    enum FeedbackAction: String, Codable, DatabaseValueConvertible {
        case accepted
        case dismissed
        case snoozed
        case ignoreSender = "ignore_sender"
        case ignoreThread = "ignore_thread"
    }
}

struct HypothesisReviewCalibrationRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "hypothesis_review_calibration"

    var id: String
    var mailboxAccountId: String
    var hypothesisId: String
    var senderDomainClass: String
    var labelCluster: String
    var threadPattern: String
    var acceptedCount: Int
    var dismissedCount: Int
    var snoozedCount: Int
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        hypothesisId: String,
        senderDomainClass: String,
        labelCluster: String,
        threadPattern: String,
        acceptedCount: Int = 0,
        dismissedCount: Int = 0,
        snoozedCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.hypothesisId = hypothesisId
        self.senderDomainClass = senderDomainClass
        self.labelCluster = labelCluster
        self.threadPattern = threadPattern
        self.acceptedCount = acceptedCount
        self.dismissedCount = dismissedCount
        self.snoozedCount = snoozedCount
        self.updatedAt = updatedAt
    }
}

struct HypothesisMetricCounterRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "hypothesis_metric_counter"

    var id: String
    var mailboxAccountId: String
    var profile: String
    var hypothesisId: String
    var counter: String
    var count: Int
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        profile: String,
        hypothesisId: String,
        counter: String,
        count: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.profile = profile
        self.hypothesisId = hypothesisId
        self.counter = counter
        self.count = count
        self.updatedAt = updatedAt
    }
}

struct UserExposureEventRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "user_exposure_event"

    var id: String
    var mailboxAccountId: String
    var obligationId: String
    var digestRenderId: String
    var hypothesisClass: String
    var projectionState: String
    var digestPosition: Int
    var exposedAt: Date
    var policyVersion: String

    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        obligationId: String,
        digestRenderId: String,
        hypothesisClass: String,
        projectionState: String,
        digestPosition: Int,
        exposedAt: Date = Date(),
        policyVersion: String
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.obligationId = obligationId
        self.digestRenderId = digestRenderId
        self.hypothesisClass = hypothesisClass
        self.projectionState = projectionState
        self.digestPosition = digestPosition
        self.exposedAt = exposedAt
        self.policyVersion = policyVersion
    }
}

struct PolicyDiffArtifactRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "policy_diff_artifact"

    var id: String
    var datasetId: String
    var baselineVersion: String
    var candidateVersion: String
    var decisionDeltaPercent: Double
    var generatedAt: Date

    init(
        id: String = UUID().uuidString,
        datasetId: String,
        baselineVersion: String,
        candidateVersion: String,
        decisionDeltaPercent: Double,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.datasetId = datasetId
        self.baselineVersion = baselineVersion
        self.candidateVersion = candidateVersion
        self.decisionDeltaPercent = decisionDeltaPercent
        self.generatedAt = generatedAt
    }
}
