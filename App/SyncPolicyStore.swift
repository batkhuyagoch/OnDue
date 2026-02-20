import Foundation
import Combine

protocol SyncPolicyStoring: AnyObject {
    var defaultSyncRange: SyncRange { get set }
    var backgroundSyncEnabled: Bool { get set }
    var backgroundIntervalHours: Int { get set }
    var maxMessagesPerSlice: Int { get set }
    var longScanAndBackgroundOptIn: Bool { get set }
}

final class SyncPolicyStore: ObservableObject, SyncPolicyStoring {
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

    init() {
        let rangeRaw = UserDefaults.standard.string(forKey: Keys.defaultSyncRange) ?? SyncRange.threeWeeks.rawValue
        self.defaultSyncRange = SyncRange(rawValue: rangeRaw) ?? .threeWeeks
        self.backgroundSyncEnabled = UserDefaults.standard.object(forKey: Keys.backgroundEnabled) as? Bool ?? false
        self.backgroundIntervalHours = UserDefaults.standard.object(forKey: Keys.backgroundIntervalHours) as? Int ?? 6
        self.maxMessagesPerSlice = UserDefaults.standard.object(forKey: Keys.maxMessagesPerSlice) as? Int ?? 100_000
        self.longScanAndBackgroundOptIn = UserDefaults.standard.object(forKey: Keys.longScanAndBackgroundOptIn) as? Bool ?? false
        GmailClient.maxTotalMessagesPerSlice = maxMessagesPerSlice
    }

    private enum Keys {
        static let defaultSyncRange = "sync.policy.defaultRange"
        static let backgroundEnabled = "sync.policy.backgroundEnabled"
        static let backgroundIntervalHours = "sync.policy.backgroundIntervalHours"
        static let maxMessagesPerSlice = "sync.policy.maxMessagesPerSlice"
        static let longScanAndBackgroundOptIn = "sync.policy.longScanAndBackgroundOptIn"
    }
}
