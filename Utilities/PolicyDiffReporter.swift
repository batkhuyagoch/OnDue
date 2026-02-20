import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct PolicyDiffRow: Hashable {
    let sampleId: String
    let beforeOutcome: ObligationDecision
    let afterOutcome: ObligationDecision
    let beforeHypothesis: String?
    let afterHypothesis: String?
    let beforeReasonCode: ReasonCode
    let afterReasonCode: ReasonCode
    let mutation: MutationAnnotation?

    var changed: Bool {
        beforeOutcome != afterOutcome
            || beforeHypothesis != afterHypothesis
            || beforeReasonCode != afterReasonCode
    }
}

struct PolicyDiffReport {
    let rows: [PolicyDiffRow]

    var total: Int { rows.count }
    var changedCount: Int { rows.filter(\.changed).count }
    var unchangedCount: Int { total - changedCount }

    func markdownSummary(maxRows: Int = 20) -> String {
        var lines: [String] = []
        lines.append("Policy Diff Summary")
        lines.append("- total: \(total)")
        lines.append("- changed: \(changedCount)")
        lines.append("- unchanged: \(unchangedCount)")
        lines.append("")
        lines.append("| sample | outcome (before->after) | hypothesis (before->after) | reason (before->after) |")
        lines.append("|---|---|---|---|")
        for row in rows.filter(\.changed).prefix(maxRows) {
            let beforeHyp = row.beforeHypothesis ?? "-"
            let afterHyp = row.afterHypothesis ?? "-"
            lines.append(
                "| \(row.sampleId) | \(row.beforeOutcome.rawValue) -> \(row.afterOutcome.rawValue) | \(beforeHyp) -> \(afterHyp) | \(row.beforeReasonCode.rawValue) -> \(row.afterReasonCode.rawValue) |"
            )
        }
        if changedCount > maxRows {
            lines.append("| ... | ... | ... | ... |")
        }
        return lines.joined(separator: "\n")
    }
}

enum PolicyDiffReporter {
    struct InputSample: Hashable {
        let id: String
        let email: ParsedEmail
        let mutation: MutationAnnotation?

        init(id: String, email: ParsedEmail, mutation: MutationAnnotation? = nil) {
            self.id = id
            self.email = email
            self.mutation = mutation
        }
    }

    struct SeedSample: Hashable {
        let id: String
        let email: ParsedEmail
        let expectedOutcome: ObligationDecision?
        let expectedHypothesis: String?
    }

    static func compare(
        samples: [InputSample],
        baselineEngine: RuleEngine,
        candidateEngine: RuleEngine
    ) -> PolicyDiffReport {
        let rows = samples.map { sample in
            let before = baselineEngine.assess(email: sample.email)
            let after = candidateEngine.assess(email: sample.email)
            return PolicyDiffRow(
                sampleId: sample.id,
                beforeOutcome: before.decision,
                afterOutcome: after.decision,
                beforeHypothesis: before.decisionContract.primaryHypothesisId,
                afterHypothesis: after.decisionContract.primaryHypothesisId,
                beforeReasonCode: before.decisionContract.reasonCode,
                afterReasonCode: after.decisionContract.reasonCode,
                mutation: sample.mutation
            )
        }
        return PolicyDiffReport(rows: rows)
    }

    static func seedSamples(from exportItems: [GoldDatasetExportItem]) -> [SeedSample] {
        exportItems.map { item in
            SeedSample(
                id: item.obligationId.isEmpty ? "message_\(item.messagePk)" : item.obligationId,
                email: ParsedEmail(
                    subject: item.subject,
                    snippet: item.snippet ?? "",
                    bodyText: item.bodyText ?? "",
                    sender: item.sender,
                    senderDomain: item.senderDomain,
                    hasAttachments: false,
                    labelIds: item.labelIds,
                    normalizedText: item.normalizedText
                ),
                expectedOutcome: item.expectedOutcome.flatMap { ObligationDecision(rawValue: $0) },
                expectedHypothesis: item.expectedHypothesis
            )
        }
    }

    static func seedSamples(from inputSamples: [InputSample]) -> [SeedSample] {
        inputSamples.map {
            SeedSample(
                id: $0.id,
                email: $0.email,
                expectedOutcome: nil,
                expectedHypothesis: nil
            )
        }
    }
}

protocol EmailInputSource: Sendable {
    func fetchMessages() async throws -> [PolicyDiffReporter.InputSample]
}

struct GmailInputSource: EmailInputSource {
    let mailboxAccountId: String
    let daysBack: Int
    let limit: Int
    let messageRepository: MessageRepositorying
    let parser: EmailParser

    init(
        mailboxAccountId: String,
        daysBack: Int = 90,
        limit: Int = 500,
        messageRepository: MessageRepositorying,
        parser: EmailParser = EmailParser()
    ) {
        self.mailboxAccountId = mailboxAccountId
        self.daysBack = daysBack
        self.limit = limit
        self.messageRepository = messageRepository
        self.parser = parser
    }

    func fetchMessages() async throws -> [PolicyDiffReporter.InputSample] {
        let messages = try await messageRepository.fetchRecent(
            mailboxAccountId: mailboxAccountId,
            daysBack: daysBack,
            limit: limit
        )
        return messages.compactMap { message in
            guard let pk = message.pk else { return nil }
            let parsed = parser.parse(message: message)
            return PolicyDiffReporter.InputSample(id: "message_\(pk)", email: parsed)
        }
    }
}

struct SyntheticInputSource: EmailInputSource {
    private let samples: [PolicyDiffReporter.InputSample]

    init(samples: [PolicyDiffReporter.InputSample]) {
        self.samples = samples
    }

    init(datasetItems: [GoldDatasetExportItem]) {
        self.samples = datasetItems.map { item in
            PolicyDiffReporter.InputSample(
                id: item.obligationId.isEmpty ? "message_\(item.messagePk)" : item.obligationId,
                email: ParsedEmail(
                    subject: item.subject,
                    snippet: item.snippet ?? "",
                    bodyText: item.bodyText ?? "",
                    sender: item.sender,
                    senderDomain: item.senderDomain,
                    hasAttachments: false,
                    labelIds: item.labelIds,
                    normalizedText: item.normalizedText
                )
            )
        }
    }

    func fetchMessages() async throws -> [PolicyDiffReporter.InputSample] {
        samples
    }
}

struct PolicySimulationReport {
    let diffReport: PolicyDiffReport
    let perHypothesisPrecision: [String: Double]
    let reviewRatio: Double
    let blockerLeakCount: Int
    let decisionDeltaIndex: Double
}

struct AssessmentSnapshot: Codable, Hashable {
    let sampleId: String
    let matchedSignalIds: [String]
    let hypothesisResults: [HypothesisResultSnapshot]
    let primaryHypothesisId: String?
    let outcome: String
    let confidence: Double
    let reasonCode: String
    let policyVersion: String
    let deadline: Date?
    let riskCategory: String

    init(
        sampleId: String,
        matchedSignalIds: [String],
        hypothesisResults: [HypothesisResultSnapshot],
        primaryHypothesisId: String?,
        outcome: String,
        confidence: Double,
        reasonCode: String,
        policyVersion: String,
        deadline: Date?,
        riskCategory: String
    ) {
        self.sampleId = sampleId
        self.matchedSignalIds = matchedSignalIds
        self.hypothesisResults = hypothesisResults
        self.primaryHypothesisId = primaryHypothesisId
        self.outcome = outcome
        self.confidence = confidence
        self.reasonCode = reasonCode
        self.policyVersion = policyVersion
        self.deadline = deadline
        self.riskCategory = riskCategory
    }

    init(sampleId: String, assessment: RuleAssessment) {
        self.init(
            sampleId: sampleId,
            matchedSignalIds: assessment.matchedSignalIds.sorted(),
            hypothesisResults: assessment.hypothesisResults.sorted { $0.hypothesisId < $1.hypothesisId },
            primaryHypothesisId: assessment.decisionContract.primaryHypothesisId,
            outcome: assessment.decision.rawValue,
            confidence: assessment.confidence,
            reasonCode: assessment.decisionContract.reasonCode.rawValue,
            policyVersion: assessment.decisionContract.policyVersion,
            deadline: assessment.deadline,
            riskCategory: assessment.risk.rawValue
        )
    }

    func missingCanonicalFields() -> [String] {
        var missing: [String] = []
        if outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("outcome")
        }
        if reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("reasonCode")
        }
        if policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("policyVersion")
        }
        if riskCategory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("riskCategory")
        }
        if outcome != ObligationDecision.reject.rawValue,
           (primaryHypothesisId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            missing.append("primaryHypothesisId")
        }
        return missing
    }
}

struct FrozenReplaySample: Hashable {
    let id: String
    let message: MessageRecord
    let expectedSnapshot: AssessmentSnapshot?

    init(id: String, message: MessageRecord, expectedSnapshot: AssessmentSnapshot? = nil) {
        self.id = id
        self.message = message
        self.expectedSnapshot = expectedSnapshot
    }
}

struct ReplayHarness {
    let parser: EmailParser
    let engine: RuleEngine

    init(parser: EmailParser = EmailParser(), engine: RuleEngine) {
        self.parser = parser
        self.engine = engine
    }

    func run(samples: [FrozenReplaySample]) -> [AssessmentSnapshot] {
        samples.map { sample in
            let parsed = parser.parse(message: sample.message)
            let assessment = engine.assess(email: parsed)
            return AssessmentSnapshot(sampleId: sample.id, assessment: assessment)
        }
    }
}

enum SnapshotIssueSeverity: String {
    case fail
    case warn
}

struct SnapshotComparisonIssue: Hashable {
    let sampleId: String
    let field: String
    let severity: SnapshotIssueSeverity
    let message: String
}

struct SnapshotComparatorConfig {
    let confidenceShiftWarnThreshold: Double
    let deadlineDriftWarnHours: Double

    static let `default` = SnapshotComparatorConfig(
        confidenceShiftWarnThreshold: 0.10,
        deadlineDriftWarnHours: 12
    )
}

struct SnapshotComparisonReport {
    let issues: [SnapshotComparisonIssue]

    var failures: [SnapshotComparisonIssue] {
        issues.filter { $0.severity == .fail }
    }

    var warnings: [SnapshotComparisonIssue] {
        issues.filter { $0.severity == .warn }
    }

    var status: String {
        if !failures.isEmpty { return "fail" }
        if !warnings.isEmpty { return "warn" }
        return "pass"
    }
}

enum SnapshotComparator {
    static func compare(
        expected: [AssessmentSnapshot],
        actual: [AssessmentSnapshot],
        config: SnapshotComparatorConfig = .default
    ) -> SnapshotComparisonReport {
        var issues: [SnapshotComparisonIssue] = []
        let expectedById = Dictionary(uniqueKeysWithValues: expected.map { ($0.sampleId, $0) })
        let actualById = Dictionary(uniqueKeysWithValues: actual.map { ($0.sampleId, $0) })

        for sampleId in expectedById.keys.sorted() {
            guard let expectedSnapshot = expectedById[sampleId] else { continue }
            guard let actualSnapshot = actualById[sampleId] else {
                issues.append(
                    SnapshotComparisonIssue(
                        sampleId: sampleId,
                        field: "sample",
                        severity: .fail,
                        message: "Missing replay output for expected sample."
                    )
                )
                continue
            }
            issues.append(
                contentsOf: compareSample(
                    expected: expectedSnapshot,
                    actual: actualSnapshot,
                    config: config
                )
            )
        }

        for sampleId in actualById.keys.sorted() where expectedById[sampleId] == nil {
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: sampleId,
                    field: "sample",
                    severity: .warn,
                    message: "Unexpected replay output sample not present in expected set."
                )
            )
        }

        return SnapshotComparisonReport(issues: issues)
    }

    private static func compareSample(
        expected: AssessmentSnapshot,
        actual: AssessmentSnapshot,
        config: SnapshotComparatorConfig
    ) -> [SnapshotComparisonIssue] {
        var issues: [SnapshotComparisonIssue] = []

        let missingFields = actual.missingCanonicalFields()
        if !missingFields.isEmpty {
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: expected.sampleId,
                    field: "canonical",
                    severity: .fail,
                    message: "Missing canonical fields: \(missingFields.joined(separator: ", "))."
                )
            )
        }

        if expected.outcome != actual.outcome {
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: expected.sampleId,
                    field: "outcome",
                    severity: .fail,
                    message: "Outcome changed from \(expected.outcome) to \(actual.outcome)."
                )
            )
        }

        if expected.primaryHypothesisId != actual.primaryHypothesisId {
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: expected.sampleId,
                    field: "primaryHypothesisId",
                    severity: .fail,
                    message: "Primary hypothesis changed from \(expected.primaryHypothesisId ?? "-") to \(actual.primaryHypothesisId ?? "-")."
                )
            )
        }

        if expected.policyVersion != actual.policyVersion {
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: expected.sampleId,
                    field: "policyVersion",
                    severity: .fail,
                    message: "Policy version changed from \(expected.policyVersion) to \(actual.policyVersion)."
                )
            )
        }

        if expected.outcome == actual.outcome, expected.matchedSignalIds != actual.matchedSignalIds {
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: expected.sampleId,
                    field: "matchedSignalIds",
                    severity: .warn,
                    message: "Signal set changed while keeping same outcome."
                )
            )
        }

        if abs(expected.confidence - actual.confidence) >= config.confidenceShiftWarnThreshold {
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: expected.sampleId,
                    field: "confidence",
                    severity: .warn,
                    message: "Confidence shifted from \(String(format: "%.3f", expected.confidence)) to \(String(format: "%.3f", actual.confidence))."
                )
            )
        }

        switch (expected.deadline, actual.deadline) {
        case let (lhs?, rhs?):
            let hours = abs(rhs.timeIntervalSince(lhs)) / 3600.0
            if hours > 0 && hours <= config.deadlineDriftWarnHours {
                issues.append(
                    SnapshotComparisonIssue(
                        sampleId: expected.sampleId,
                        field: "deadline",
                        severity: .warn,
                        message: "Deadline drifted by \(String(format: "%.1f", hours))h."
                    )
                )
            }
        case (.none, .some), (.some, .none):
            issues.append(
                SnapshotComparisonIssue(
                    sampleId: expected.sampleId,
                    field: "deadline",
                    severity: .warn,
                    message: "Deadline presence changed between expected and actual."
                )
            )
        default:
            break
        }

        return issues
    }
}

enum GoldRegressionGate {
    static func evaluate(
        samples: [FrozenReplaySample],
        harness: ReplayHarness,
        comparatorConfig: SnapshotComparatorConfig = .default
    ) -> SnapshotComparisonReport {
        var preflightIssues: [SnapshotComparisonIssue] = []
        let expected = samples.compactMap { sample -> AssessmentSnapshot? in
            guard let expectedSnapshot = sample.expectedSnapshot else {
                preflightIssues.append(
                    SnapshotComparisonIssue(
                        sampleId: sample.id,
                        field: "expectedSnapshot",
                        severity: .fail,
                        message: "Gold sample is missing expected snapshot JSON."
                    )
                )
                return nil
            }
            return expectedSnapshot
        }

        let actual = harness.run(samples: samples)
        let comparison = SnapshotComparator.compare(
            expected: expected,
            actual: actual,
            config: comparatorConfig
        )
        return SnapshotComparisonReport(issues: preflightIssues + comparison.issues)
    }
}

enum MutationExpectedImpact: String, Codable {
    case stable
    case uncertain
}

struct MutationAnnotation: Hashable, Codable {
    let sourceSampleId: String
    let operatorId: String
    let seed: UInt64
    let variantIndex: Int
}

struct MutationRunConfig {
    let seed: UInt64
    let perSampleCount: Int
    let operators: [any MutationOperator]
    let version: String

    init(
        seed: UInt64,
        perSampleCount: Int,
        operators: [any MutationOperator],
        version: String = "v0.1"
    ) {
        self.seed = seed
        self.perSampleCount = perSampleCount
        self.operators = operators
        self.version = version
    }

    static let v01 = MutationRunConfig(
        seed: 42,
        perSampleCount: 1,
        operators: [
            FooterNoiseInjectionOperator(),
            CTAClutterOperator(),
            HarmlessBlockShuffleOperator(),
            CasingWhitespacePerturbationOperator(),
            LegalBoilerplateAppendOperator()
        ],
        version: "v0.2"
    )
}

struct MutationVariant: Hashable {
    let sourceSampleId: String
    let operatorId: String
    let seed: UInt64
    let variantIndex: Int
    let expectedImpact: MutationExpectedImpact
    let isInvariant: Bool
    let sample: PolicyDiffReporter.InputSample
    let expectedOutcome: ObligationDecision?
    let expectedHypothesis: String?
}

protocol MutationOperator {
    var id: String { get }
    var isInvariant: Bool { get }
    var expectedImpact: MutationExpectedImpact { get }
    func mutate(sample: PolicyDiffReporter.SeedSample, rng: inout DeterministicRNG) -> PolicyDiffReporter.SeedSample
}

struct MutationGenerator {
    func generateVariants(
        seedSamples: [PolicyDiffReporter.SeedSample],
        config: MutationRunConfig
    ) -> [MutationVariant] {
        var rng = DeterministicRNG(seed: config.seed)
        var variants: [MutationVariant] = []
        for seedSample in seedSamples {
            for op in config.operators {
                for variantIndex in 0..<max(config.perSampleCount, 1) {
                    let mutated = op.mutate(sample: seedSample, rng: &rng)
                    variants.append(
                        MutationVariant(
                            sourceSampleId: seedSample.id,
                            operatorId: op.id,
                            seed: config.seed,
                            variantIndex: variantIndex,
                            expectedImpact: op.expectedImpact,
                            isInvariant: op.isInvariant,
                            sample: .init(
                                id: "\(seedSample.id)::\(op.id)::\(variantIndex)",
                                email: mutated.email,
                                mutation: MutationAnnotation(
                                    sourceSampleId: seedSample.id,
                                    operatorId: op.id,
                                    seed: config.seed,
                                    variantIndex: variantIndex
                                )
                            ),
                            expectedOutcome: seedSample.expectedOutcome,
                            expectedHypothesis: seedSample.expectedHypothesis
                        )
                    )
                }
            }
        }
        return variants
    }
}

struct MutationMetrics {
    let precisionAtAccept: Double
    let reviewBurden: Double
    let reviewRatioShift: Double
    let hypothesisAgreement: Double
    let reasonCoherenceRate: Double
    let decisionDeltaIndex: Double
    let invariantBreakRate: Double
    let blockerLeakCount: Int
    let protectedClassSuppressionCount: Int
    let peakMemoryMB: Double
    let replayP95LatencyMs: Double
    let exposureLoggingErrorCount: Int
}

struct MutationGateThresholds {
    let failInvariantBreakRate: Double
    let warnDecisionDeltaIndex: Double
    let warnReviewBurdenIncrease: Double
    let warnPeakMemoryIncreaseRatio: Double
    let warnOutcomeDistributionDrift: Double

    init(
        failInvariantBreakRate: Double,
        warnDecisionDeltaIndex: Double,
        warnReviewBurdenIncrease: Double,
        warnPeakMemoryIncreaseRatio: Double,
        warnOutcomeDistributionDrift: Double = OutcomeDistributionDriftGate.defaultThreshold
    ) {
        self.failInvariantBreakRate = failInvariantBreakRate
        self.warnDecisionDeltaIndex = warnDecisionDeltaIndex
        self.warnReviewBurdenIncrease = warnReviewBurdenIncrease
        self.warnPeakMemoryIncreaseRatio = warnPeakMemoryIncreaseRatio
        self.warnOutcomeDistributionDrift = warnOutcomeDistributionDrift
    }

    static let v01 = MutationGateThresholds(
        failInvariantBreakRate: 0.03,
        warnDecisionDeltaIndex: 0.15,
        warnReviewBurdenIncrease: 0.10,
        warnPeakMemoryIncreaseRatio: 0.20,
        warnOutcomeDistributionDrift: OutcomeDistributionDriftGate.defaultThreshold
    )
}

struct MutationGateResult {
    let failures: [String]
    let warnings: [String]
}

struct OutcomeDistributionBucketDrift: Hashable {
    let decision: ObligationDecision
    let baselineCount: Int
    let candidateCount: Int
    let baselineRate: Double
    let candidateRate: Double

    var absoluteDrift: Double {
        abs(candidateRate - baselineRate)
    }
}

struct OutcomeDistributionDriftReport {
    let threshold: Double
    let buckets: [OutcomeDistributionBucketDrift]
    let warnings: [String]
}

enum OutcomeDistributionDriftGate {
    static let defaultThreshold: Double = 0.05

    static func evaluate(
        baselineCounts: [ObligationDecision: Int],
        candidateCounts: [ObligationDecision: Int],
        threshold: Double = defaultThreshold
    ) -> OutcomeDistributionDriftReport {
        let baselineTotal = max(baselineCounts.values.reduce(0, +), 1)
        let candidateTotal = max(candidateCounts.values.reduce(0, +), 1)
        let decisions: [ObligationDecision] = [.accept, .needsReview, .reject]

        let buckets = decisions.map { decision -> OutcomeDistributionBucketDrift in
            let baselineCount = baselineCounts[decision, default: 0]
            let candidateCount = candidateCounts[decision, default: 0]
            return OutcomeDistributionBucketDrift(
                decision: decision,
                baselineCount: baselineCount,
                candidateCount: candidateCount,
                baselineRate: Double(baselineCount) / Double(baselineTotal),
                candidateRate: Double(candidateCount) / Double(candidateTotal)
            )
        }

        let warnings = buckets.compactMap { bucket -> String? in
            guard bucket.absoluteDrift > threshold else { return nil }
            let deltaPercent = bucket.absoluteDrift * 100.0
            let baselinePercent = bucket.baselineRate * 100.0
            let candidatePercent = bucket.candidateRate * 100.0
            return "outcomeDistributionDrift[\(bucket.decision.rawValue)] baseline=\(bucket.baselineCount) (\(String(format: "%.2f", baselinePercent))%) candidate=\(bucket.candidateCount) (\(String(format: "%.2f", candidatePercent))%) delta=\(String(format: "%.2f", deltaPercent))% exceeds warning \(String(format: "%.2f", threshold * 100.0))%"
        }

        return OutcomeDistributionDriftReport(
            threshold: threshold,
            buckets: buckets,
            warnings: warnings
        )
    }
}

enum MutationMeasurementContract {
    static let qualityFormulas: [String: String] = [
        "precisionAtAccept": "trueAccept / predictedAccept",
        "reviewBurden": "needsReview / total",
        "hypothesisAgreement": "matchedExpectedHypothesis / labeledTotal",
        "reasonCoherenceRate": "coherentOutcomeHypothesisReason / nonRejectTotal"
    ]

    static let reliabilityFormulas: [String: String] = [
        "decisionDeltaIndex": "changedDecisions / total",
        "invariantBreakRate": "invariantViolations / invariantVariants",
        "reviewRatioShift": "candidateReviewRatio - baselineReviewRatio",
        "blockerLeakCount": "count(nonReject with blocker signals)",
        "protectedClassSuppressionCount": "count(protected expected class predicted reject)"
    ]

    static let runtimeFormulas: [String: String] = [
        "peakMemoryMB": "max(residentMemoryMB before run, after run)",
        "replayP95LatencyMs": "95th percentile of per-sample evaluation latency",
        "exposureLoggingErrorCount": "telemetry insert/read errors during run"
    ]
}

struct MutationStressReport {
    let mutationVariants: [MutationVariant]
    let diffReport: PolicyDiffReport
    let metrics: MutationMetrics
    let gateResult: MutationGateResult
    let outcomeDistributionDrift: OutcomeDistributionDriftReport
    let baselineVersion: String
    let candidateVersion: String
    let datasetId: String
    let seed: UInt64

    func markdownSummary() -> String {
        var lines: [String] = []
        lines.append("# Weekly Mutation Reliability Report")
        lines.append("- datasetId: \(datasetId)")
        lines.append("- seed: \(seed)")
        lines.append("- baseline: \(baselineVersion)")
        lines.append("- candidate: \(candidateVersion)")
        lines.append("- totalVariants: \(mutationVariants.count)")
        lines.append("- decisionDeltaIndex: \(String(format: "%.4f", metrics.decisionDeltaIndex))")
        lines.append("- invariantBreakRate: \(String(format: "%.4f", metrics.invariantBreakRate))")
        lines.append("- blockerLeakCount: \(metrics.blockerLeakCount)")
        lines.append("- protectedClassSuppressionCount: \(metrics.protectedClassSuppressionCount)")
        lines.append("- precisionAtAccept: \(String(format: "%.4f", metrics.precisionAtAccept))")
        lines.append("- reviewBurden: \(String(format: "%.4f", metrics.reviewBurden))")
        lines.append("- reviewRatioShift: \(String(format: "%.4f", metrics.reviewRatioShift))")
        lines.append("- hypothesisAgreement: \(String(format: "%.4f", metrics.hypothesisAgreement))")
        lines.append("- reasonCoherenceRate: \(String(format: "%.4f", metrics.reasonCoherenceRate))")
        lines.append("- replayP95LatencyMs: \(String(format: "%.2f", metrics.replayP95LatencyMs))")
        lines.append("- peakMemoryMB: \(String(format: "%.2f", metrics.peakMemoryMB))")
        lines.append("- outcomeDriftThreshold: \(String(format: "%.2f", outcomeDistributionDrift.threshold * 100.0))%")
        lines.append("")
        lines.append("## Operator Failure Rates")
        let failureRates = operatorFailureRates()
        if failureRates.isEmpty {
            lines.append("- none")
        } else {
            for failureRate in failureRates {
                lines.append(
                    "- \(failureRate.operatorId): \(failureRate.failures)/\(failureRate.total) (\(String(format: "%.2f", failureRate.rate * 100))%)"
                )
            }
        }
        lines.append("")
        if gateResult.failures.isEmpty {
            lines.append("## Failures")
            lines.append("- none")
        } else {
            lines.append("## Failures")
            gateResult.failures.forEach { lines.append("- \($0)") }
        }
        if gateResult.warnings.isEmpty {
            lines.append("## Warnings")
            lines.append("- none")
        } else {
            lines.append("## Warnings")
            gateResult.warnings.forEach { lines.append("- \($0)") }
        }
        lines.append("")
        lines.append("## Outcome Distribution Drift")
        for bucket in outcomeDistributionDrift.buckets {
            lines.append(
                "- \(bucket.decision.rawValue): baseline=\(bucket.baselineCount) (\(String(format: "%.2f", bucket.baselineRate * 100.0))%), candidate=\(bucket.candidateCount) (\(String(format: "%.2f", bucket.candidateRate * 100.0))%), delta=\(String(format: "%.2f", bucket.absoluteDrift * 100.0))%"
            )
        }
        lines.append("")
        lines.append("## Top Hypothesis Deltas")
        let hypothesisDeltas = topTransitionCounts { row in
            "\(row.beforeHypothesis ?? "-") -> \(row.afterHypothesis ?? "-")"
        }
        if hypothesisDeltas.isEmpty {
            lines.append("- none")
        } else {
            hypothesisDeltas.forEach { lines.append("- \($0.key): \($0.value)") }
        }
        lines.append("")
        lines.append("## Top Reason-Code Shifts")
        let reasonDeltas = topTransitionCounts { row in
            "\(row.beforeReasonCode.rawValue) -> \(row.afterReasonCode.rawValue)"
        }
        if reasonDeltas.isEmpty {
            lines.append("- none")
        } else {
            reasonDeltas.forEach { lines.append("- \($0.key): \($0.value)") }
        }
        lines.append("")
        lines.append("## Policy Diff")
        lines.append(diffReport.markdownSummary(maxRows: 20))
        return lines.joined(separator: "\n")
    }

    func writeMarkdown(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try markdownSummary().write(to: url, atomically: true, encoding: .utf8)
    }

    private func topTransitionCounts(key: (PolicyDiffRow) -> String) -> [(key: String, value: Int)] {
        var counts: [String: Int] = [:]
        for row in diffReport.rows where row.changed {
            counts[key(row), default: 0] += 1
        }
        return counts.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }.prefix(5).map { ($0.key, $0.value) }
    }

    private func operatorFailureRates() -> [(operatorId: String, failures: Int, total: Int, rate: Double)] {
        guard !mutationVariants.isEmpty else { return [] }
        var variantsBySampleId: [String: MutationVariant] = [:]
        variantsBySampleId.reserveCapacity(mutationVariants.count)
        for variant in mutationVariants {
            variantsBySampleId[variant.sample.id] = variant
        }

        var totals: [String: Int] = [:]
        var failures: [String: Int] = [:]
        for row in diffReport.rows {
            guard let variant = variantsBySampleId[row.sampleId] else { continue }
            totals[variant.operatorId, default: 0] += 1

            let didFail: Bool
            if variant.isInvariant, let expectedOutcome = variant.expectedOutcome {
                let outcomeMismatch = row.afterOutcome != expectedOutcome
                let hypothesisMismatch = variant.expectedHypothesis != nil && row.afterHypothesis != variant.expectedHypothesis
                didFail = outcomeMismatch || hypothesisMismatch
            } else {
                didFail = row.changed
            }

            if didFail {
                failures[variant.operatorId, default: 0] += 1
            }
        }

        return totals.map { operatorId, total in
            let failureCount = failures[operatorId, default: 0]
            let rate = total == 0 ? 0 : Double(failureCount) / Double(total)
            return (operatorId: operatorId, failures: failureCount, total: total, rate: rate)
        }.sorted { lhs, rhs in
            if lhs.rate == rhs.rate { return lhs.operatorId < rhs.operatorId }
            return lhs.rate > rhs.rate
        }
    }
}

final class PolicySimulationRunner {
    private let policyDiffArtifactRepository: PolicyDiffArtifactRepositorying?

    init(policyDiffArtifactRepository: PolicyDiffArtifactRepositorying? = nil) {
        self.policyDiffArtifactRepository = policyDiffArtifactRepository
    }

    func run(
        source: EmailInputSource,
        baselineEngine: RuleEngine,
        candidateEngine: RuleEngine,
        datasetId: String = "synthetic",
        baselineVersion: DecisionPolicyVersion = .v1StaticBridge,
        candidateVersion: DecisionPolicyVersion = .v2PolicyDriven
    ) async throws -> PolicySimulationReport {
        let samples = try await source.fetchMessages()
        let diff = PolicyDiffReporter.compare(
            samples: samples,
            baselineEngine: baselineEngine,
            candidateEngine: candidateEngine
        )

        var hypothesisTotals: [String: (matched: Int, total: Int)] = [:]
        var reviewCount = 0
        var blockerLeakCount = 0

        for sample in samples {
            let result = candidateEngine.assess(email: sample.email)
            if result.decision == .needsReview {
                reviewCount += 1
            }
            if result.decision != .reject,
               result.matchedReasons.contains(where: { $0.lowercased().contains("unsubscribe") || $0.lowercased().contains("promo") }) {
                blockerLeakCount += 1
            }
            if let hypothesis = result.decisionContract.primaryHypothesisId {
                let prior = hypothesisTotals[hypothesis] ?? (0, 0)
                let matched = result.decision == .accept ? prior.matched + 1 : prior.matched
                hypothesisTotals[hypothesis] = (matched, prior.total + 1)
            }
        }

        let precision = Dictionary(uniqueKeysWithValues: hypothesisTotals.map { key, value in
            let p = value.total == 0 ? 0 : Double(value.matched) / Double(value.total)
            return (key, p)
        })

        let total = max(samples.count, 1)
        let reviewRatio = Double(reviewCount) / Double(total)
        let decisionDeltaIndex = Double(diff.changedCount) / Double(total)

        if let policyDiffArtifactRepository {
            let artifact = PolicyDiffArtifactRecord(
                datasetId: datasetId,
                baselineVersion: baselineVersion.rawValue,
                candidateVersion: candidateVersion.rawValue,
                decisionDeltaPercent: decisionDeltaIndex * 100.0
            )
            try await policyDiffArtifactRepository.save(artifact)
        }

        return PolicySimulationReport(
            diffReport: diff,
            perHypothesisPrecision: precision,
            reviewRatio: reviewRatio,
            blockerLeakCount: blockerLeakCount,
            decisionDeltaIndex: decisionDeltaIndex
        )
    }

    func runMutationStress(
        seedSamples: [PolicyDiffReporter.SeedSample],
        config: MutationRunConfig = .v01,
        baselineEngine: RuleEngine,
        candidateEngine: RuleEngine,
        datasetId: String,
        baselineVersion: DecisionPolicyVersion = .v1StaticBridge,
        candidateVersion: DecisionPolicyVersion = .v2PolicyDriven,
        thresholds: MutationGateThresholds = .v01
    ) async throws -> MutationStressReport {
        let variants = MutationGenerator().generateVariants(seedSamples: seedSamples, config: config)
        let samples = variants.map(\.sample)
        let diff = PolicyDiffReporter.compare(samples: samples, baselineEngine: baselineEngine, candidateEngine: candidateEngine)
        let mutationDatasetId = "\(datasetId)_mutation_\(config.version)_seed_\(config.seed)"

        let memoryBefore = currentMemoryUsageMB()
        var predictedAccept = 0
        var trueAccept = 0
        var reviewCount = 0
        var hypothesisComparable = 0
        var hypothesisMatched = 0
        var coherentCount = 0
        var nonRejectCount = 0
        var invariantComparable = 0
        var invariantViolations = 0
        var blockerLeakCount = 0
        var protectedSuppressionCount = 0
        var latencies: [Double] = []
        latencies.reserveCapacity(samples.count)
        var baselineReviewCount = 0
        var baselineOutcomeCounts: [ObligationDecision: Int] = [.accept: 0, .needsReview: 0, .reject: 0]
        var candidateOutcomeCounts: [ObligationDecision: Int] = [.accept: 0, .needsReview: 0, .reject: 0]

        let protectedHypotheses: Set<String> = [
            ObligationHypothesis.legalOrCompliance.rawValue,
            ObligationHypothesis.legalComplianceResponse.rawValue,
            ObligationHypothesis.paymentFailure.rawValue,
            ObligationHypothesis.identityVerification.rawValue,
            ObligationHypothesis.documentExpiration.rawValue
        ]

        for variant in variants {
            let start = Date()
            let baseline = baselineEngine.assess(email: variant.sample.email)
            let candidate = candidateEngine.assess(email: variant.sample.email)
            latencies.append(Date().timeIntervalSince(start) * 1000.0)
            if baseline.decision == .needsReview { baselineReviewCount += 1 }
            baselineOutcomeCounts[baseline.decision, default: 0] += 1
            candidateOutcomeCounts[candidate.decision, default: 0] += 1

            if candidate.decision == .accept { predictedAccept += 1 }
            if let expected = variant.expectedOutcome, expected == .accept {
                if candidate.decision == .accept { trueAccept += 1 }
            }
            if candidate.decision == .needsReview { reviewCount += 1 }

            if let expectedHypothesis = variant.expectedHypothesis {
                hypothesisComparable += 1
                if candidate.decisionContract.primaryHypothesisId == expectedHypothesis {
                    hypothesisMatched += 1
                }
            }

            if candidate.decision != .reject {
                nonRejectCount += 1
                let coherent = !(candidate.decisionContract.primaryHypothesisId ?? "").isEmpty
                    && candidate.decisionContract.reasonCode != .other
                if coherent { coherentCount += 1 }
            }

            if variant.isInvariant, let expected = variant.expectedOutcome {
                invariantComparable += 1
                if candidate.decision != expected {
                    invariantViolations += 1
                }
            }

            let normalized = variant.sample.email.normalizedText
            if candidate.decision != .reject,
               (normalized.contains("unsubscribe") || normalized.contains("promo") || normalized.contains("promotion")) {
                blockerLeakCount += 1
            }

            if let expectedHypothesis = variant.expectedHypothesis,
               protectedHypotheses.contains(expectedHypothesis),
               candidate.decision == .reject {
                protectedSuppressionCount += 1
            }

            _ = baseline
        }

        let total = max(samples.count, 1)
        let precisionAtAccept = predictedAccept == 0 ? 0 : Double(trueAccept) / Double(predictedAccept)
        let reviewBurden = Double(reviewCount) / Double(total)
        let baselineReviewBurden = Double(baselineReviewCount) / Double(total)
        let reviewRatioShift = reviewBurden - baselineReviewBurden
        let hypothesisAgreement = hypothesisComparable == 0 ? 0 : Double(hypothesisMatched) / Double(hypothesisComparable)
        let reasonCoherenceRate = Double(coherentCount) / Double(max(nonRejectCount, 1))
        let decisionDeltaIndex = Double(diff.changedCount) / Double(total)
        let invariantBreakRate = invariantComparable == 0 ? 0 : Double(invariantViolations) / Double(invariantComparable)
        let memoryAfter = currentMemoryUsageMB()
        let peakMemoryMB = max(memoryBefore, memoryAfter)
        let p95 = percentile(values: latencies, q: 0.95)

        let metrics = MutationMetrics(
            precisionAtAccept: precisionAtAccept,
            reviewBurden: reviewBurden,
            reviewRatioShift: reviewRatioShift,
            hypothesisAgreement: hypothesisAgreement,
            reasonCoherenceRate: reasonCoherenceRate,
            decisionDeltaIndex: decisionDeltaIndex,
            invariantBreakRate: invariantBreakRate,
            blockerLeakCount: blockerLeakCount,
            protectedClassSuppressionCount: protectedSuppressionCount,
            peakMemoryMB: peakMemoryMB,
            replayP95LatencyMs: p95,
            exposureLoggingErrorCount: 0
        )

        let reviewBurdenIncrease = max(0, metrics.reviewRatioShift)
        let peakMemoryIncreaseRatio = 0.0
        let outcomeDistributionDrift = OutcomeDistributionDriftGate.evaluate(
            baselineCounts: baselineOutcomeCounts,
            candidateCounts: candidateOutcomeCounts,
            threshold: thresholds.warnOutcomeDistributionDrift
        )

        let gateResult = evaluateGates(
            metrics: metrics,
            thresholds: thresholds,
            reviewBurdenIncrease: reviewBurdenIncrease,
            peakMemoryIncreaseRatio: peakMemoryIncreaseRatio,
            outcomeDistributionWarnings: outcomeDistributionDrift.warnings
        )

        if let policyDiffArtifactRepository {
            let artifact = PolicyDiffArtifactRecord(
                datasetId: mutationDatasetId,
                baselineVersion: baselineVersion.rawValue,
                candidateVersion: candidateVersion.rawValue,
                decisionDeltaPercent: decisionDeltaIndex * 100.0
            )
            try await policyDiffArtifactRepository.save(artifact)
        }

        return MutationStressReport(
            mutationVariants: variants,
            diffReport: diff,
            metrics: metrics,
            gateResult: gateResult,
            outcomeDistributionDrift: outcomeDistributionDrift,
            baselineVersion: baselineVersion.rawValue,
            candidateVersion: candidateVersion.rawValue,
            datasetId: mutationDatasetId,
            seed: config.seed
        )
    }

    private func evaluateGates(
        metrics: MutationMetrics,
        thresholds: MutationGateThresholds,
        reviewBurdenIncrease: Double,
        peakMemoryIncreaseRatio: Double,
        outcomeDistributionWarnings: [String]
    ) -> MutationGateResult {
        var failures: [String] = []
        var warnings: [String] = []
        if metrics.blockerLeakCount > 0 {
            failures.append("blockerLeakCount=\(metrics.blockerLeakCount) > 0")
        }
        if metrics.protectedClassSuppressionCount > 0 {
            failures.append("protectedClassSuppressionCount=\(metrics.protectedClassSuppressionCount) > 0")
        }
        if metrics.invariantBreakRate > thresholds.failInvariantBreakRate {
            failures.append("invariantBreakRate=\(String(format: "%.4f", metrics.invariantBreakRate)) exceeds \(thresholds.failInvariantBreakRate)")
        }
        if metrics.decisionDeltaIndex > thresholds.warnDecisionDeltaIndex {
            warnings.append("decisionDeltaIndex=\(String(format: "%.4f", metrics.decisionDeltaIndex)) exceeds warning \(thresholds.warnDecisionDeltaIndex)")
        }
        if reviewBurdenIncrease > thresholds.warnReviewBurdenIncrease {
            warnings.append("reviewBurdenIncrease=\(String(format: "%.4f", reviewBurdenIncrease)) exceeds warning \(thresholds.warnReviewBurdenIncrease)")
        }
        if peakMemoryIncreaseRatio > thresholds.warnPeakMemoryIncreaseRatio {
            warnings.append("peakMemoryIncreaseRatio=\(String(format: "%.4f", peakMemoryIncreaseRatio)) exceeds warning \(thresholds.warnPeakMemoryIncreaseRatio)")
        }
        warnings.append(contentsOf: outcomeDistributionWarnings)
        return MutationGateResult(failures: failures, warnings: warnings)
    }

    private func percentile(values: [Double], q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let clamped = min(max(q, 0), 1)
        let idx = Int(Double(sorted.count - 1) * clamped)
        return sorted[idx]
    }

    private func currentMemoryUsageMB() -> Double {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
        #else
        return 0
        #endif
    }
}

struct DeterministicRNG {
    private(set) var state: UInt64

    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func next() -> UInt64 {
        state = 6364136223846793005 &* state &+ 1
        return state
    }

    mutating func nextInt(upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }

    mutating func nextBool(probability: Double) -> Bool {
        let p = min(max(probability, 0), 1)
        let value = Double(next() % 10_000) / 10_000.0
        return value < p
    }
}

private extension ParsedEmail {
    static func rebuilt(
        from base: ParsedEmail,
        subject: String? = nil,
        snippet: String? = nil,
        bodyText: String? = nil
    ) -> ParsedEmail {
        let newSubject = subject ?? base.subject
        let newSnippet = snippet ?? base.snippet
        let newBody = bodyText ?? base.bodyText
        let normalized = "\(newSubject)\n\(newSnippet)\n\(newBody)"
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedEmail(
            subject: newSubject,
            snippet: newSnippet,
            bodyText: newBody,
            sender: base.sender,
            senderDomain: base.senderDomain,
            hasAttachments: base.hasAttachments,
            labelIds: base.labelIds,
            normalizedText: normalized
        )
    }
}

private struct FooterNoiseInjectionOperator: MutationOperator {
    let id = "footer_noise_injection"
    let isInvariant = false
    let expectedImpact: MutationExpectedImpact = .uncertain

    private let footerNoise = [
        "View this email in your browser. Update your preferences in account settings.",
        "Manage notifications any time from your profile. This is an automated message.",
        "Sent by OnDue Mail Service. Message intended for registered recipient only."
    ]

    func mutate(sample: PolicyDiffReporter.SeedSample, rng: inout DeterministicRNG) -> PolicyDiffReporter.SeedSample {
        let footer = footerNoise[rng.nextInt(upperBound: footerNoise.count)]
        let body = "\(sample.email.bodyText)\n\n\(footer)"
        return .init(
            id: sample.id,
            email: .rebuilt(from: sample.email, bodyText: body),
            expectedOutcome: sample.expectedOutcome,
            expectedHypothesis: sample.expectedHypothesis
        )
    }
}

private struct CTAClutterOperator: MutationOperator {
    let id = "cta_clutter"
    let isInvariant = false
    let expectedImpact: MutationExpectedImpact = .uncertain

    func mutate(sample: PolicyDiffReporter.SeedSample, rng: inout DeterministicRNG) -> PolicyDiffReporter.SeedSample {
        let ctas = [
            "Manage settings",
            "Open dashboard",
            "View details",
            "Confirm preferences"
        ]
        var body = sample.email.bodyText
        for _ in 0..<(2 + rng.nextInt(upperBound: 2)) {
            body += "\n\(ctas[rng.nextInt(upperBound: ctas.count)])"
        }
        return .init(
            id: sample.id,
            email: .rebuilt(from: sample.email, bodyText: body),
            expectedOutcome: sample.expectedOutcome,
            expectedHypothesis: sample.expectedHypothesis
        )
    }
}

private struct HarmlessBlockShuffleOperator: MutationOperator {
    let id = "harmless_block_shuffle"
    let isInvariant = false
    let expectedImpact: MutationExpectedImpact = .uncertain

    func mutate(sample: PolicyDiffReporter.SeedSample, rng: inout DeterministicRNG) -> PolicyDiffReporter.SeedSample {
        var blocks = sample.email.bodyText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
            .chunked(by: 2)
        guard blocks.count > 1 else { return sample }
        for index in stride(from: blocks.count - 1, through: 1, by: -1) {
            let swapIndex = rng.nextInt(upperBound: index + 1)
            blocks.swapAt(index, swapIndex)
        }
        let body = blocks.flatMap { $0 }.joined(separator: "\n")
        return .init(
            id: sample.id,
            email: .rebuilt(from: sample.email, bodyText: body),
            expectedOutcome: sample.expectedOutcome,
            expectedHypothesis: sample.expectedHypothesis
        )
    }
}

private struct CasingWhitespacePerturbationOperator: MutationOperator {
    let id = "casing_whitespace_perturbation"
    let isInvariant = true
    let expectedImpact: MutationExpectedImpact = .stable

    func mutate(sample: PolicyDiffReporter.SeedSample, rng: inout DeterministicRNG) -> PolicyDiffReporter.SeedSample {
        let subject = rng.nextBool(probability: 0.5)
            ? sample.email.subject.uppercased()
            : sample.email.subject.lowercased()
        let body = sample.email.bodyText
            .replacingOccurrences(of: "\n", with: rng.nextBool(probability: 0.5) ? "\n\n" : "\n")
            .replacingOccurrences(of: " ", with: rng.nextBool(probability: 0.5) ? "  " : " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            id: sample.id,
            email: .rebuilt(from: sample.email, subject: subject, bodyText: body),
            expectedOutcome: sample.expectedOutcome,
            expectedHypothesis: sample.expectedHypothesis
        )
    }
}

private struct LegalBoilerplateAppendOperator: MutationOperator {
    let id = "legal_boilerplate_append"
    let isInvariant = false
    let expectedImpact: MutationExpectedImpact = .uncertain

    func mutate(sample: PolicyDiffReporter.SeedSample, rng: inout DeterministicRNG) -> PolicyDiffReporter.SeedSample {
        let clauses = [
            "This communication may contain confidential information intended for the addressed recipient.",
            "If you received this message in error, please notify the sender and delete all copies.",
            "Nothing in this message creates or modifies contractual obligations unless stated explicitly."
        ]
        let chosen = clauses[rng.nextInt(upperBound: clauses.count)]
        let body = "\(sample.email.bodyText)\n\n\(chosen)"
        return .init(
            id: sample.id,
            email: .rebuilt(from: sample.email, bodyText: body),
            expectedOutcome: sample.expectedOutcome,
            expectedHypothesis: sample.expectedHypothesis
        )
    }
}

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)
        var idx = 0
        while idx < count {
            let end = Swift.min(idx + size, count)
            chunks.append(Array(self[idx..<end]))
            idx = end
        }
        return chunks
    }
}
