import Foundation
import Combine

protocol FilterPreferencesStoring: AnyObject {
    var includeSecurityAlerts: Bool { get set }
    var includeStatements: Bool { get set }
    var includeMarketing: Bool { get set }
    var includeNewsletters: Bool { get set }
    var includeShipping: Bool { get set }
}

final class FilterPreferencesStore: ObservableObject, FilterPreferencesStoring {
    @Published var includeSecurityAlerts: Bool {
        didSet { UserDefaults.standard.set(includeSecurityAlerts, forKey: Keys.securityAlerts) }
    }
    @Published var includeStatements: Bool {
        didSet { UserDefaults.standard.set(includeStatements, forKey: Keys.statements) }
    }
    @Published var includeMarketing: Bool {
        didSet { UserDefaults.standard.set(includeMarketing, forKey: Keys.marketing) }
    }
    @Published var includeNewsletters: Bool {
        didSet { UserDefaults.standard.set(includeNewsletters, forKey: Keys.newsletters) }
    }
    @Published var includeShipping: Bool {
        didSet { UserDefaults.standard.set(includeShipping, forKey: Keys.shipping) }
    }

    init() {
        self.includeSecurityAlerts = UserDefaults.standard.object(forKey: Keys.securityAlerts) as? Bool ?? false
        self.includeStatements = UserDefaults.standard.object(forKey: Keys.statements) as? Bool ?? false
        self.includeMarketing = UserDefaults.standard.object(forKey: Keys.marketing) as? Bool ?? false
        self.includeNewsletters = UserDefaults.standard.object(forKey: Keys.newsletters) as? Bool ?? false
        self.includeShipping = UserDefaults.standard.object(forKey: Keys.shipping) as? Bool ?? false
    }

    private enum Keys {
        static let securityAlerts = "filters.include.securityAlerts"
        static let statements = "filters.include.statements"
        static let marketing = "filters.include.marketing"
        static let newsletters = "filters.include.newsletters"
        static let shipping = "filters.include.shipping"
    }
}
