import Foundation

protocol ObligationExtracting {
    func extract(from snippets: [EmailSnippet]) -> [Obligation]
}

final class ObligationExtractor: ObligationExtracting {
    func extract(from snippets: [EmailSnippet]) -> [Obligation] {
        // TODO: Implement simple high-precision rules:
        // - explicit dates
        // - request phrases ("please send", "need you to")
        // - appointments ("scheduled for")
        return []
    }
}
