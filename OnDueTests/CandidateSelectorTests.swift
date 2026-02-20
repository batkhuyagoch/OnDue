import XCTest
@testable import OnDue

final class CandidateSelectorTests: XCTestCase {
    func testShippingDisabledStillAllowsDeliveryActionMessages() async {
        let prefs = CandidatePrefs(includeShipping: false)
        let selector = CandidateSelector(preferences: prefs, suppressionRepository: nil)
        let message = MessageRecord(
            mailboxAccountId: "acct",
            providerMessageId: "m1",
            internalDate: Date(),
            fromEmail: "alerts@carrier.com",
            fromDomain: "carrier.com",
            subject: "Delivery attempt failed",
            snippet: "Please reschedule delivery and pick up your package."
        )
        let isCandidate = await selector.isCandidate(message)
        XCTAssertTrue(isCandidate)
    }

    func testShippingDisabledBlocksPassiveShippingUpdates() async {
        let prefs = CandidatePrefs(includeShipping: false)
        let selector = CandidateSelector(preferences: prefs, suppressionRepository: nil)
        let message = MessageRecord(
            mailboxAccountId: "acct",
            providerMessageId: "m2",
            internalDate: Date(),
            fromEmail: "alerts@carrier.com",
            fromDomain: "carrier.com",
            subject: "Your package was delivered",
            snippet: "Track your shipment in the app."
        )
        let isCandidate = await selector.isCandidate(message)
        XCTAssertFalse(isCandidate)
    }
}

private final class CandidatePrefs: FilterPreferencesStoring {
    var includeSecurityAlerts: Bool = false
    var includeStatements: Bool = false
    var includeMarketing: Bool = false
    var includeNewsletters: Bool = false
    var includeShipping: Bool

    init(includeShipping: Bool) {
        self.includeShipping = includeShipping
    }
}
