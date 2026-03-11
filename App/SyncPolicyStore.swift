import Foundation
import Combine

enum CoverageScanIntensity: String, CaseIterable, Identifiable {
    case batterySaver
    case balanced
    case faster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .batterySaver:
            return "Battery Saver"
        case .balanced:
            return "Balanced"
        case .faster:
            return "Faster"
        }
    }
}

protocol SyncPolicyStoring: AnyObject {
    var defaultSyncRange: SyncRange { get set }
    var backgroundSyncEnabled: Bool { get set }
    var backgroundIntervalHours: Int { get set }
    var maxMessagesPerSlice: Int { get set }
    var longScanAndBackgroundOptIn: Bool { get set }
    var coverageScanMonths: Int { get set }
    var coverageScanIntensity: CoverageScanIntensity { get set }
    var coverageBackgroundRequiresCharging: Bool { get set }
    var coveragePreferWiFi: Bool { get set }
}

final class SyncPolicyStore: ObservableObject, SyncPolicyStoring {
    static let minimumCoverageMonths = 1
    static let maximumCoverageMonths = 24
    static let defaultCoverageMonths = 12

    @Published var defaultSyncRange: SyncRange {
        didSet { UserDefaults.standard.set(defaultSyncRange.rawValue, forKey: Keys.defaultSyncRange) }
    }
    @Published var backgroundSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(backgroundSyncEnabled, forKey: Keys.backgroundEnabled)
            AppLog.debug("SyncPolicy.backgroundSyncEnabled", fields: ["enabled": backgroundSyncEnabled])
        }
    }
    @Published var backgroundIntervalHours: Int {
        didSet {
            UserDefaults.standard.set(backgroundIntervalHours, forKey: Keys.backgroundIntervalHours)
            AppLog.debug("SyncPolicy.backgroundIntervalHours", fields: ["hours": backgroundIntervalHours])
        }
    }
    @Published var maxMessagesPerSlice: Int {
        didSet {
            UserDefaults.standard.set(maxMessagesPerSlice, forKey: Keys.maxMessagesPerSlice)
            GmailClient.maxTotalMessagesPerSlice = maxMessagesPerSlice
            AppLog.debug("SyncPolicy.maxMessagesPerSlice", fields: ["max": maxMessagesPerSlice])
        }
    }
    @Published var longScanAndBackgroundOptIn: Bool {
        didSet {
            UserDefaults.standard.set(longScanAndBackgroundOptIn, forKey: Keys.longScanAndBackgroundOptIn)
            AppLog.debug("SyncPolicy.longScanAndBackgroundOptIn", fields: ["enabled": longScanAndBackgroundOptIn])
        }
    }
    @Published var coverageScanMonths: Int {
        didSet {
            let clamped = Self.clampCoverageMonths(coverageScanMonths)
            if clamped != coverageScanMonths {
                coverageScanMonths = clamped
                return
            }
            UserDefaults.standard.set(coverageScanMonths, forKey: Keys.coverageScanMonths)
            AppLog.debug("SyncPolicy.coverageScanMonths", fields: ["months": coverageScanMonths])
        }
    }
    @Published var coverageScanIntensity: CoverageScanIntensity {
        didSet {
            UserDefaults.standard.set(coverageScanIntensity.rawValue, forKey: Keys.coverageScanIntensity)
            AppLog.debug("SyncPolicy.coverageScanIntensity", fields: ["intensity": coverageScanIntensity.rawValue])
        }
    }
    @Published var coverageBackgroundRequiresCharging: Bool {
        didSet {
            UserDefaults.standard.set(
                coverageBackgroundRequiresCharging,
                forKey: Keys.coverageBackgroundRequiresCharging
            )
            AppLog.debug(
                "SyncPolicy.coverageBackgroundRequiresCharging",
                fields: ["enabled": coverageBackgroundRequiresCharging]
            )
        }
    }
    @Published var coveragePreferWiFi: Bool {
        didSet {
            UserDefaults.standard.set(coveragePreferWiFi, forKey: Keys.coveragePreferWiFi)
            AppLog.debug("SyncPolicy.coveragePreferWiFi", fields: ["enabled": coveragePreferWiFi])
        }
    }

    init() {
        let rangeRaw = UserDefaults.standard.string(forKey: Keys.defaultSyncRange) ?? SyncRange.threeWeeks.rawValue
        self.defaultSyncRange = SyncRange(rawValue: rangeRaw) ?? .threeWeeks
        self.backgroundSyncEnabled = UserDefaults.standard.object(forKey: Keys.backgroundEnabled) as? Bool ?? false
        self.backgroundIntervalHours = UserDefaults.standard.object(forKey: Keys.backgroundIntervalHours) as? Int ?? 6
        self.maxMessagesPerSlice = UserDefaults.standard.object(forKey: Keys.maxMessagesPerSlice) as? Int ?? 100_000
        self.longScanAndBackgroundOptIn = UserDefaults.standard.object(forKey: Keys.longScanAndBackgroundOptIn) as? Bool ?? false
        let months = UserDefaults.standard.object(forKey: Keys.coverageScanMonths) as? Int ?? Self.defaultCoverageMonths
        self.coverageScanMonths = Self.clampCoverageMonths(months)
        let intensityRaw = UserDefaults.standard.string(forKey: Keys.coverageScanIntensity) ?? CoverageScanIntensity.balanced.rawValue
        self.coverageScanIntensity = CoverageScanIntensity(rawValue: intensityRaw) ?? .balanced
        self.coverageBackgroundRequiresCharging = UserDefaults.standard.object(forKey: Keys.coverageBackgroundRequiresCharging) as? Bool ?? false
        self.coveragePreferWiFi = UserDefaults.standard.object(forKey: Keys.coveragePreferWiFi) as? Bool ?? false
        GmailClient.maxTotalMessagesPerSlice = maxMessagesPerSlice
    }

    static func clampCoverageMonths(_ value: Int) -> Int {
        min(max(value, minimumCoverageMonths), maximumCoverageMonths)
    }

    private enum Keys {
        static let defaultSyncRange = "sync.policy.defaultRange"
        static let backgroundEnabled = "sync.policy.backgroundEnabled"
        static let backgroundIntervalHours = "sync.policy.backgroundIntervalHours"
        static let maxMessagesPerSlice = "sync.policy.maxMessagesPerSlice"
        static let longScanAndBackgroundOptIn = "sync.policy.longScanAndBackgroundOptIn"
        static let coverageScanMonths = "sync.policy.coverageScanMonths"
        static let coverageScanIntensity = "sync.policy.coverageScanIntensity"
        static let coverageBackgroundRequiresCharging = "sync.policy.coverageBackgroundRequiresCharging"
        static let coveragePreferWiFi = "sync.policy.coveragePreferWiFi"
    }
}
