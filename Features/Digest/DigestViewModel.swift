import Combine
import Foundation

@MainActor
final class DigestViewModel: ObservableObject {
    
    // MARK: - Dependencies
    
    private var environment: AppEnvironment?
    
    // MARK: - Published State
    
    @Published private(set) var sections: [DigestSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?
    
    var isEmpty: Bool {
        sections.allSatisfy { $0.items.isEmpty }
    }
    
    // MARK: - Actions
    
    func loadDigest(using environment: AppEnvironment) async {
        self.environment = environment
        isLoading = true
        error = nil
        
        do {
            let obligations = try await environment.obligationRepository.fetchTopDigest(limit: 10)
            sections = Self.buildSections(from: obligations)
        } catch {
            self.error = error
            sections = []
        }
        
        isLoading = false
    }
    
    func snooze(_ obligation: ObligationItem) async {
        guard let environment else { return }
        
        // Default snooze: 1 day from now
        let snoozeUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        
        do {
            try await environment.obligationRepository.snooze(id: obligation.id, until: snoozeUntil)
            removeFromSections(obligation)
        } catch {
            self.error = error
        }
    }
    
    func dismiss(_ obligation: ObligationItem) async {
        guard let environment else { return }
        
        do {
            try await environment.obligationRepository.dismiss(id: obligation.id)
            removeFromSections(obligation)
        } catch {
            self.error = error
        }
    }
    
    // MARK: - Private Helpers
    
    private func removeFromSections(_ obligation: ObligationItem) {
        sections = sections.compactMap { section in
            let filtered = section.items.filter { $0.id != obligation.id }
            guard !filtered.isEmpty else { return nil }
            return DigestSection(kind: section.kind, items: filtered)
        }
    }
    
    private static func buildSections(from obligations: [ObligationItem]) -> [DigestSection] {
        // Group by digestSection computed property
        let grouped = Dictionary(grouping: obligations) { $0.digestSection }
        
        return DigestSection.Kind.allCases.compactMap { kind in
            guard let items = grouped[kind.sectionType], !items.isEmpty else { return nil }
            
            let sorted = items.sorted {
                ($0.deadline ?? .distantFuture) < ($1.deadline ?? .distantFuture)
            }
            return DigestSection(kind: kind, items: sorted)
        }
    }
}

// MARK: - Section Model

struct DigestSection: Identifiable {
    let kind: Kind
    let items: [ObligationItem]
    
    var id: Kind { kind }
    
    enum Kind: CaseIterable, Identifiable {
        case thisWeek
        case upcoming
        case waitingOn
        
        var id: Self { self }
        
        var title: String {
            switch self {
            case .thisWeek: "This Week"
            case .upcoming: "Upcoming"
            case .waitingOn: "Waiting On"
            }
        }
        
        var icon: String {
            switch self {
            case .thisWeek: "flame.fill"
            case .upcoming: "calendar"
            case .waitingOn: "hourglass"
            }
        }
        
        var color: ColorToken {
            switch self {
            case .thisWeek: .orange
            case .upcoming: .blue
            case .waitingOn: .purple
            }
        }
        
        var sectionType: ObligationItem.DigestSectionType {
            switch self {
            case .thisWeek: .thisWeek
            case .upcoming: .upcoming
            case .waitingOn: .waitingOn
            }
        }
    }
    
    enum ColorToken {
        case orange, blue, purple
    }
}
