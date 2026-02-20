import Foundation

enum AppPrivacyConfiguration {
    static let privacyPolicyURLString = "https://batkhuyagoch.github.io/OnDue/privacy-policy.html"

    static var privacyPolicyURL: URL? {
        URL(string: privacyPolicyURLString)
    }
}
