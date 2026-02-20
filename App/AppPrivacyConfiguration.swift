import Foundation

enum AppPrivacyConfiguration {
    static let privacyPolicyURLString = "https://batkhuyagoch/ondue/privacy-policy"

    static var privacyPolicyURL: URL? {
        URL(string: privacyPolicyURLString)
    }
}
