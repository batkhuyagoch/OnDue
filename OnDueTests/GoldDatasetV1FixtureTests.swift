import XCTest

final class GoldDatasetV1FixtureTests: XCTestCase {
    func testFixtureDecodesAndContainsExpectedSnapshots() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("gold_dataset_v1.json")

        let data = try Data(contentsOf: fixtureURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(GoldDatasetV1Fixture.self, from: data)

        XCTAssertEqual(fixture.schemaVersion, "gold_dataset_v1")
        XCTAssertTrue(fixture.metadata.manualValidated)
        XCTAssertFalse(fixture.items.isEmpty)

        for item in fixture.items {
            XCTAssertEqual(item.expectedSnapshot.sampleId, item.id)
            XCTAssertFalse(item.expectedSnapshot.outcome.isEmpty)
            XCTAssertFalse(item.expectedSnapshot.reasonCode.isEmpty)
            XCTAssertFalse(item.expectedSnapshot.policyVersion.isEmpty)
            XCTAssertFalse(item.expectedSnapshot.riskCategory.isEmpty)
            XCTAssertFalse(item.expectedSnapshot.hypothesisResults.isEmpty)
        }
    }
}

private struct GoldDatasetV1Fixture: Decodable {
    let schemaVersion: String
    let generatedAt: Date
    let metadata: Metadata
    let items: [Item]

    struct Metadata: Decodable {
        let notes: String
        let manualValidated: Bool
    }

    struct Item: Decodable {
        let id: String
        let rawMessage: RawMessage
        let expectedSnapshot: ExpectedSnapshot
    }

    struct RawMessage: Decodable {
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

    struct ExpectedSnapshot: Decodable {
        let sampleId: String
        let matchedSignalIds: [String]
        let hypothesisResults: [HypothesisResult]
        let primaryHypothesisId: String?
        let outcome: String
        let confidence: Double
        let reasonCode: String
        let policyVersion: String
        let deadline: Date?
        let riskCategory: String
    }

    struct HypothesisResult: Decodable {
        let hypothesisId: String
        let confidence: String
        let reasons: [String]
        let matchedSignalIds: [String]
    }
}
