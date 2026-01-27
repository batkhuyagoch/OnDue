import Foundation

struct SenderRule: Identifiable, Hashable {
    let id: UUID
    let sender: String
    let isSuppressed: Bool
}
