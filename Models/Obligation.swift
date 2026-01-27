import Foundation

struct Obligation: Identifiable, Hashable {
    let id: UUID
    let title: String
    let deadline: Date?
    let status: ObligationStatus
    let evidenceLines: [EvidenceLine]
}

enum ObligationStatus: String, CaseIterable {
    case thisWeek
    case upcoming
    case waitingOn
    case snoozed
    case ignored
}
