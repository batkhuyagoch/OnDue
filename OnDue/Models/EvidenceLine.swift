import Foundation

struct EvidenceLine: Identifiable, Hashable {
    let id: UUID
    let text: String
    let sourceMessageID: String
}
