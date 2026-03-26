import XCTest
@testable import OnDue

final class PolicyReplayHarnessTests: XCTestCase {
    private var engine: RuleEngine!
    private var baselineEngine: RuleEngine!

    override func setUp() {
        super.setUp()
        engine = RuleEngine(preferences: TestPreferencesReplay())
        baselineEngine = RuleEngine(preferences: TestPreferencesReplay(), policyVersion: .v1StaticBridge)
    }

    func testDecisionContractIsAlwaysPopulated() {
        for sample in GoldDataset.samples {
            let assessment = engine.assess(email: sample.email)
            XCTAssertFalse(assessment.decisionContract.policyVersion.isEmpty, sample.id)
            XCTAssertFalse(assessment.decisionContract.reasonText.isEmpty, sample.id)
            XCTAssertEqual(assessment.decisionContract.outcome, assessment.decision, sample.id)
            if assessment.decision != .reject {
                XCTAssertNotNil(assessment.decisionContract.primaryHypothesisId, sample.id)
            }
        }
    }

    func testDeliveryActionMapsToDeliveryReasonCode() {
        let email = ParsedEmail(
            subject: "Delivery attempt failed",
            snippet: "Please reschedule delivery by Friday",
            bodyText: "Delivery attempt failed. Please reschedule delivery before Friday.",
            sender: "alerts@carrier.com",
            senderDomain: "carrier.com",
            hasAttachments: false,
            labelIds: ["inbox"],
            normalizedText: "delivery attempt failed please reschedule delivery before friday",
            actionableWindowText: nil,
            bodyHtml: nil
        )
        let assessment = engine.assess(email: email)
        if assessment.matchedRuleIds.contains(ObligationHypothesis.deliveryRequired.rawValue) {
            XCTAssertEqual(assessment.decisionContract.reasonCode, .deliveryActionRequired)
        }
    }

    func testPolicyDiffReportIsGenerated() {
        let inputs = GoldDataset.samples.map { sample in
            PolicyDiffReporter.InputSample(id: sample.id, email: sample.email)
        }
        let report = PolicyDiffReporter.compare(
            samples: inputs,
            baselineEngine: baselineEngine,
            candidateEngine: engine
        )
        XCTAssertEqual(report.total, GoldDataset.samples.count)
        let summary = report.markdownSummary(maxRows: 10)
        XCTAssertTrue(summary.contains("Policy Diff Summary"))
        Logger.info(summary)
    }

    func testSimulationRunnerPersistsDiffArtifact() async throws {
        let source = SyntheticInputSource(
            samples: GoldDataset.samples.map { .init(id: $0.id, email: $0.email) }
        )
        let repo = MockPolicyDiffArtifactRepository()
        let runner = PolicySimulationRunner(policyDiffArtifactRepository: repo)

        let report = try await runner.run(
            source: source,
            baselineEngine: baselineEngine,
            candidateEngine: engine,
            datasetId: "gold_dataset",
            baselineVersion: .v1StaticBridge,
            candidateVersion: .v2PolicyDriven
        )

        XCTAssertGreaterThanOrEqual(report.decisionDeltaIndex, 0)
        XCTAssertEqual(repo.saved.count, 1)
        XCTAssertEqual(repo.saved.first?.datasetId, "gold_dataset")
    }

    func testMutationStressRunIsDeterministicBySeed() async throws {
        let seedSamples = GoldDataset.samples.prefix(5).map {
            PolicyDiffReporter.SeedSample(
                id: $0.id,
                email: $0.email,
                expectedOutcome: $0.expectedOutcome,
                expectedHypothesis: $0.expectedHypothesis?.rawValue
            )
        }
        let repo = MockPolicyDiffArtifactRepository()
        let runner = PolicySimulationRunner(policyDiffArtifactRepository: repo)
        let config = MutationRunConfig(seed: 42, perSampleCount: 1, operators: MutationRunConfig.v01.operators)

        let reportA = try await runner.runMutationStress(
            seedSamples: seedSamples,
            config: config,
            baselineEngine: baselineEngine,
            candidateEngine: engine,
            datasetId: "mutation_gold"
        )
        let reportB = try await runner.runMutationStress(
            seedSamples: seedSamples,
            config: config,
            baselineEngine: baselineEngine,
            candidateEngine: engine,
            datasetId: "mutation_gold"
        )

        let expectedOperatorIds = [
            "footer_noise_injection",
            "cta_clutter",
            "harmless_block_shuffle",
            "casing_whitespace_perturbation",
            "legal_boilerplate_append"
        ]
        XCTAssertEqual(config.operators.map(\.id), expectedOperatorIds)
        XCTAssertEqual(reportA.mutationVariants.count, seedSamples.count * MutationRunConfig.v01.operators.count)
        XCTAssertEqual(
            reportA.mutationVariants.map(\.sample.id),
            reportB.mutationVariants.map(\.sample.id)
        )
        XCTAssertEqual(
            reportA.mutationVariants.map(\.operatorId),
            reportB.mutationVariants.map(\.operatorId)
        )
        XCTAssertTrue(reportA.mutationVariants.allSatisfy { $0.sample.mutation != nil })
        XCTAssertTrue(reportA.diffReport.rows.allSatisfy { $0.mutation != nil })
        XCTAssertEqual(reportA.metrics.decisionDeltaIndex, reportB.metrics.decisionDeltaIndex, accuracy: 0.0001)
        XCTAssertTrue(reportA.markdownSummary().contains("Weekly Mutation Reliability Report"))
        XCTAssertTrue(reportA.markdownSummary().contains("## Operator Failure Rates"))
        XCTAssertTrue(reportA.markdownSummary().contains("## Outcome Distribution Drift"))
        XCTAssertTrue(reportA.markdownSummary().contains("reviewRatioShift"))
        XCTAssertEqual(reportA.outcomeDistributionDrift.threshold, 0.05, accuracy: 0.0001)
        XCTAssertEqual(repo.saved.count, 2)
        XCTAssertEqual(repo.saved.last?.datasetId, "mutation_gold_mutation_v0.2_seed_42")
        XCTAssertEqual(reportA.datasetId, "mutation_gold_mutation_v0.2_seed_42")
    }

    func testMutationStressRunEvaluatesTrustGates() async throws {
        let seedSamples = GoldDataset.samples.prefix(3).map {
            PolicyDiffReporter.SeedSample(
                id: $0.id,
                email: $0.email,
                expectedOutcome: $0.expectedOutcome,
                expectedHypothesis: $0.expectedHypothesis?.rawValue
            )
        }
        let runner = PolicySimulationRunner()
        let thresholds = MutationGateThresholds(
            failInvariantBreakRate: -1,
            warnDecisionDeltaIndex: -1,
            warnReviewBurdenIncrease: -1,
            warnPeakMemoryIncreaseRatio: -1
        )

        let report = try await runner.runMutationStress(
            seedSamples: seedSamples,
            baselineEngine: baselineEngine,
            candidateEngine: engine,
            datasetId: "mutation_gate_test",
            thresholds: thresholds
        )

        XCTAssertFalse(report.gateResult.failures.isEmpty)
        XCTAssertTrue(report.gateResult.failures.contains { $0.contains("invariantBreakRate") })
        XCTAssertFalse(report.gateResult.warnings.isEmpty)
        XCTAssertTrue(report.gateResult.warnings.contains { $0.contains("decisionDeltaIndex") })
    }

    func testOutcomeDistributionDrift_NoWarning_WhenDriftWithinThreshold() {
        let report = OutcomeDistributionDriftGate.evaluate(
            baselineCounts: [.accept: 40, .needsReview: 30, .reject: 30],
            candidateCounts: [.accept: 44, .needsReview: 27, .reject: 29],
            threshold: 0.05
        )

        XCTAssertTrue(report.warnings.isEmpty)
    }

    func testOutcomeDistributionDrift_WarnsPerBucket_WhenAbsoluteDriftExceedsThreshold() {
        let report = OutcomeDistributionDriftGate.evaluate(
            baselineCounts: [.accept: 40, .needsReview: 30, .reject: 30],
            candidateCounts: [.accept: 48, .needsReview: 24, .reject: 28],
            threshold: 0.05
        )

        XCTAssertFalse(report.warnings.isEmpty)
        XCTAssertTrue(report.warnings.contains { $0.contains("outcomeDistributionDrift[accept]") })
        XCTAssertTrue(report.warnings.contains { $0.contains("outcomeDistributionDrift[needsReview]") })
    }

    func testOutcomeDistributionDrift_IsWarningOnly_DoesNotCreateHardFailure() {
        let report = OutcomeDistributionDriftGate.evaluate(
            baselineCounts: [.accept: 70, .needsReview: 15, .reject: 15],
            candidateCounts: [.accept: 40, .needsReview: 35, .reject: 25],
            threshold: 0.05
        )

        XCTAssertFalse(report.warnings.isEmpty)
        XCTAssertEqual(report.buckets.count, 3)
    }

    func testOutcomeDistributionDrift_DefaultThresholdIsFivePercent() {
        XCTAssertEqual(OutcomeDistributionDriftGate.defaultThreshold, 0.05, accuracy: 0.0001)
    }

    func testOutcomeDistributionDrift_ReportIncludesCountsAndPercentages() {
        let report = OutcomeDistributionDriftGate.evaluate(
            baselineCounts: [.accept: 10, .needsReview: 10, .reject: 10],
            candidateCounts: [.accept: 2, .needsReview: 14, .reject: 14],
            threshold: 0.05
        )

        guard let firstWarning = report.warnings.first else {
            return XCTFail("Expected at least one drift warning")
        }
        XCTAssertTrue(firstWarning.contains("baseline="))
        XCTAssertTrue(firstWarning.contains("candidate="))
        XCTAssertTrue(firstWarning.contains("%"))
    }

    func testReplayHarnessUsesProductionParserAndEngine() {
        let message = MessageRecord(
            pk: 7,
            mailboxAccountId: "acct",
            providerMessageId: "provider_7",
            internalDate: Date(),
            fromEmail: "billing@example.com",
            fromDomain: "example.com",
            subject: "Invoice due tomorrow",
            snippet: "Please pay by tomorrow.",
            bodyText: "Please pay your invoice by tomorrow to avoid late fees.",
            labelIds: "inbox"
        )
        let sample = FrozenReplaySample(id: "sample_7", message: message)
        let harness = ReplayHarness(engine: engine)

        let snapshots = harness.run(samples: [sample])
        XCTAssertEqual(snapshots.count, 1)
        guard let snapshot = snapshots.first else { return }
        XCTAssertEqual(snapshot.sampleId, "sample_7")
        XCTAssertFalse(snapshot.policyVersion.isEmpty)
        XCTAssertFalse(snapshot.reasonCode.isEmpty)
        XCTAssertFalse(snapshot.riskCategory.isEmpty)
        XCTAssertEqual(snapshot.matchedSignalIds, snapshot.matchedSignalIds.sorted())
    }

    func testSnapshotComparatorHardFailSignals() {
        let now = Date()
        let expected = AssessmentSnapshot(
            sampleId: "s1",
            matchedSignalIds: ["deadline_keyword", "request_keyword"],
            hypothesisResults: [],
            primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
            outcome: ObligationDecision.accept.rawValue,
            confidence: 0.82,
            reasonCode: ReasonCode.directRequestWithDeadline.rawValue,
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
            deadline: now,
            riskCategory: ObligationRisk.medium.rawValue
        )
        let actual = AssessmentSnapshot(
            sampleId: "s1",
            matchedSignalIds: ["deadline_keyword"],
            hypothesisResults: [],
            primaryHypothesisId: nil,
            outcome: ObligationDecision.reject.rawValue,
            confidence: 0.82,
            reasonCode: "",
            policyVersion: "",
            deadline: now,
            riskCategory: ObligationRisk.medium.rawValue
        )

        let report = SnapshotComparator.compare(expected: [expected], actual: [actual])
        XCTAssertEqual(report.status, "fail")
        XCTAssertTrue(report.failures.contains { $0.field == "outcome" })
        XCTAssertTrue(report.failures.contains { $0.field == "primaryHypothesisId" })
        XCTAssertTrue(report.failures.contains { $0.field == "policyVersion" })
        XCTAssertTrue(report.failures.contains { $0.field == "canonical" })
    }

    func testSnapshotComparatorWarnSignals() {
        let now = Date()
        let expected = AssessmentSnapshot(
            sampleId: "s2",
            matchedSignalIds: ["deadline_keyword", "request_keyword"],
            hypothesisResults: [],
            primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
            outcome: ObligationDecision.accept.rawValue,
            confidence: 0.80,
            reasonCode: ReasonCode.directRequestWithDeadline.rawValue,
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
            deadline: now,
            riskCategory: ObligationRisk.medium.rawValue
        )
        let actual = AssessmentSnapshot(
            sampleId: "s2",
            matchedSignalIds: ["deadline_keyword"],
            hypothesisResults: [],
            primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
            outcome: ObligationDecision.accept.rawValue,
            confidence: 0.63,
            reasonCode: ReasonCode.directRequestWithDeadline.rawValue,
            policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
            deadline: now.addingTimeInterval(3 * 3600),
            riskCategory: ObligationRisk.medium.rawValue
        )

        let report = SnapshotComparator.compare(expected: [expected], actual: [actual])
        XCTAssertEqual(report.status, "warn")
        XCTAssertTrue(report.warnings.contains { $0.field == "matchedSignalIds" })
        XCTAssertTrue(report.warnings.contains { $0.field == "confidence" })
        XCTAssertTrue(report.warnings.contains { $0.field == "deadline" })
    }

    func testGoldRegressionGateFailsWithoutExpectedSnapshot() {
        let message = MessageRecord(
            pk: 9,
            mailboxAccountId: "acct",
            providerMessageId: "provider_9",
            internalDate: Date(),
            fromEmail: "alerts@carrier.com",
            fromDomain: "carrier.com",
            subject: "Delivery attempt failed",
            snippet: "Please reschedule delivery.",
            bodyText: "Delivery attempt failed. Please reschedule delivery by Friday.",
            labelIds: "inbox"
        )
        let harness = ReplayHarness(engine: engine)
        let report = GoldRegressionGate.evaluate(
            samples: [FrozenReplaySample(id: "s9", message: message, expectedSnapshot: nil)],
            harness: harness
        )

        XCTAssertEqual(report.status, "fail")
        XCTAssertTrue(report.failures.contains { $0.field == "expectedSnapshot" })
    }

    func testGoldDatasetV1ReplayGateHasNoHardFailures() throws {
        let fixture = try loadGoldV1Fixture()
        let samples: [FrozenReplaySample] = fixture.items.map { item in
            let message = MessageRecord(
                mailboxAccountId: item.rawMessage.mailboxAccountId,
                providerMessageId: item.rawMessage.providerMessageId,
                internalDate: item.rawMessage.internalDate,
                fromEmail: item.rawMessage.fromEmail,
                fromDomain: item.rawMessage.fromDomain,
                subject: item.rawMessage.subject,
                snippet: item.rawMessage.snippet,
                bodyText: item.rawMessage.bodyText,
                bodyHtml: item.rawMessage.bodyHtml,
                hasAttachments: item.rawMessage.hasAttachments,
                labelIds: item.rawMessage.labelIds.joined(separator: ",")
            )
            return FrozenReplaySample(
                id: item.id,
                message: message,
                expectedSnapshot: item.expectedSnapshot
            )
        }

        let report = GoldRegressionGate.evaluate(
            samples: samples,
            harness: ReplayHarness(engine: engine)
        )
        XCTAssertTrue(
            report.failures.isEmpty,
            "Hard failures: \(report.failures.map { "[\($0.sampleId)] \($0.field): \($0.message)" }.joined(separator: " | "))"
        )
    }

    private func loadGoldV1Fixture() throws -> ReplayFixtureFile {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("gold_dataset_v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ReplayFixtureFile.self, from: data)
    }

    func testSeedLoaderFromExportItems() {
        let exportItem = GoldDatasetExportItem(
            obligationId: "",
            messagePk: 101,
            subject: "Payment due tomorrow",
            snippet: "Please pay now",
            bodyText: "Please submit payment before tomorrow.",
            bodyHtml: nil,
            sender: "billing@example.com",
            senderDomain: "example.com",
            labelIds: ["inbox"],
            internalDate: Date(),
            normalizedText: "payment due tomorrow please pay now please submit payment before tomorrow",
            currentDecision: .needsReview,
            rawDecision: "needsReview",
            currentConfidence: "high",
            currentHypotheses: [ObligationHypothesis.userActionRequired.rawValue],
            currentReasons: ["Direct request with a clear deadline"],
            currentReasonCode: ReasonCode.directRequestWithDeadline.rawValue,
            currentPolicyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
            expectedOutcome: ObligationDecision.accept.rawValue,
            expectedHypothesis: ObligationHypothesis.userActionRequired.rawValue,
            expectedReason: "Direct request with a clear deadline",
            expectedSnapshot: nil
        )

        let seeds = PolicyDiffReporter.seedSamples(from: [exportItem])
        XCTAssertEqual(seeds.count, 1)
        XCTAssertEqual(seeds.first?.expectedOutcome, .accept)
        XCTAssertEqual(seeds.first?.expectedHypothesis, ObligationHypothesis.userActionRequired.rawValue)
    }
}

private final class TestPreferencesReplay: FilterPreferencesStoring {
    var includeSecurityAlerts: Bool = false
    var includeStatements: Bool = false
    var includeMarketing: Bool = false
    var includeNewsletters: Bool = false
    var includeShipping: Bool = true
}

private struct ReplayFixtureFile: Decodable {
    let schemaVersion: String
    let generatedAt: Date
    let metadata: ReplayFixtureMetadata
    let items: [ReplayFixtureItem]
}

private struct ReplayFixtureMetadata: Decodable {
    let notes: String
    let manualValidated: Bool
}

private struct ReplayFixtureItem: Decodable {
    let id: String
    let rawMessage: ReplayRawMessage
    let expectedSnapshot: AssessmentSnapshot
}

private struct ReplayRawMessage: Decodable {
    let mailboxAccountId: String
    let providerMessageId: String
    let internalDate: Date
    let fromEmail: String
    let fromDomain: String?
    let subject: String
    let snippet: String?
    let bodyText: String?
    let bodyHtml: String?
    let hasAttachments: Bool
    let labelIds: [String]
}

private final class MockPolicyDiffArtifactRepository: PolicyDiffArtifactRepositorying {
    private(set) var saved: [PolicyDiffArtifactRecord] = []

    func save(_ record: PolicyDiffArtifactRecord) async throws {
        saved.append(record)
    }
}
