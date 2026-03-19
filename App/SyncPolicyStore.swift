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
    var coverage36MonthExperimentalEnabled: Bool { get set }
    var extendedScanKillSwitchEnabled: Bool { get set }
    var effectiveMaximumCoverageMonths: Int { get }
}

final class SyncPolicyStore: ObservableObject, SyncPolicyStoring {
    static let minimumCoverageMonths = 1
    static let defaultMaximumCoverageMonths = 12
    static let advancedMaximumCoverageMonths = 24
    static let maximumCoverageMonths = 36
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
            coverageScanMonths = Self.clampCoverageMonths(
                coverageScanMonths,
                max: effectiveMaximumCoverageMonths
            )
        }
    }
    @Published var coverageScanMonths: Int {
        didSet {
            let clamped = Self.clampCoverageMonths(
                coverageScanMonths,
                max: effectiveMaximumCoverageMonths
            )
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
    @Published var coverage36MonthExperimentalEnabled: Bool {
        didSet {
            UserDefaults.standard.set(coverage36MonthExperimentalEnabled, forKey: Keys.coverage36MonthExperimentalEnabled)
            AppLog.debug(
                "SyncPolicy.coverage36MonthExperimentalEnabled",
                fields: ["enabled": coverage36MonthExperimentalEnabled]
            )
            coverageScanMonths = Self.clampCoverageMonths(
                coverageScanMonths,
                max: effectiveMaximumCoverageMonths
            )
        }
    }
    @Published var extendedScanKillSwitchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(extendedScanKillSwitchEnabled, forKey: Keys.extendedScanKillSwitchEnabled)
            AppLog.debug(
                "SyncPolicy.extendedScanKillSwitchEnabled",
                fields: ["enabled": extendedScanKillSwitchEnabled]
            )
            coverageScanMonths = Self.clampCoverageMonths(
                coverageScanMonths,
                max: effectiveMaximumCoverageMonths
            )
        }
    }

    var effectiveMaximumCoverageMonths: Int {
        if extendedScanKillSwitchEnabled {
            return Self.defaultMaximumCoverageMonths
        }
        if coverage36MonthExperimentalEnabled {
            return Self.maximumCoverageMonths
        }
        if longScanAndBackgroundOptIn {
            return Self.advancedMaximumCoverageMonths
        }
        return Self.defaultMaximumCoverageMonths
    }

    init() {
        let rangeRaw = UserDefaults.standard.string(forKey: Keys.defaultSyncRange) ?? SyncRange.threeWeeks.rawValue
        self.defaultSyncRange = SyncRange(rawValue: rangeRaw) ?? .threeWeeks
        self.backgroundSyncEnabled = UserDefaults.standard.object(forKey: Keys.backgroundEnabled) as? Bool ?? false
        self.backgroundIntervalHours = UserDefaults.standard.object(forKey: Keys.backgroundIntervalHours) as? Int ?? 6
        self.maxMessagesPerSlice = UserDefaults.standard.object(forKey: Keys.maxMessagesPerSlice) as? Int ?? 100_000
        let longScanOptIn = UserDefaults.standard.object(forKey: Keys.longScanAndBackgroundOptIn) as? Bool ?? false
        let enable36MonthExperimental = UserDefaults.standard.object(forKey: Keys.coverage36MonthExperimentalEnabled) as? Bool ?? false
        let extendedRangeKillSwitch = UserDefaults.standard.object(forKey: Keys.extendedScanKillSwitchEnabled) as? Bool ?? false
        self.longScanAndBackgroundOptIn = longScanOptIn
        self.coverage36MonthExperimentalEnabled = enable36MonthExperimental
        self.extendedScanKillSwitchEnabled = extendedRangeKillSwitch
        let months = UserDefaults.standard.object(forKey: Keys.coverageScanMonths) as? Int ?? Self.defaultCoverageMonths
        let initialMax = extendedRangeKillSwitch
            ? Self.defaultMaximumCoverageMonths
            : (enable36MonthExperimental
                ? Self.maximumCoverageMonths
                : (longScanOptIn ? Self.advancedMaximumCoverageMonths : Self.defaultMaximumCoverageMonths))
        self.coverageScanMonths = Self.clampCoverageMonths(months, max: initialMax)
        let intensityRaw = UserDefaults.standard.string(forKey: Keys.coverageScanIntensity) ?? CoverageScanIntensity.balanced.rawValue
        self.coverageScanIntensity = CoverageScanIntensity(rawValue: intensityRaw) ?? .balanced
        self.coverageBackgroundRequiresCharging = UserDefaults.standard.object(forKey: Keys.coverageBackgroundRequiresCharging) as? Bool ?? false
        self.coveragePreferWiFi = UserDefaults.standard.object(forKey: Keys.coveragePreferWiFi) as? Bool ?? false
        GmailClient.maxTotalMessagesPerSlice = maxMessagesPerSlice
    }

    static func clampCoverageMonths(_ value: Int, max maxMonths: Int = maximumCoverageMonths) -> Int {
        min(Swift.max(value, minimumCoverageMonths), maxMonths)
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
        static let coverage36MonthExperimentalEnabled = "sync.policy.coverage36MonthExperimentalEnabled"
        static let extendedScanKillSwitchEnabled = "sync.policy.extendedScanKillSwitchEnabled"
    }
}
