import Foundation
import Combine

@MainActor
final class DigestViewModel: ObservableObject {
    @Published var items: [Obligation] = []

    func loadDigest(using environment: AppEnvironment) async {
        do {
            let digest = try await environment.obligationRepository.fetchTopDigest(limit: 10)
            items = digest
        } catch {
            items = []
        }
    }
}
