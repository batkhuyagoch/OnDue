import Foundation
import Foundation
import SwiftUI
import Combine
import UserNotifications

// MARK: - Daily Digest Scheduler

@MainActor
final class DailyDigestScheduler: ObservableObject {
    
    static let shared = DailyDigestScheduler()
    
    private let notificationCenter = UNUserNotificationCenter.current()
    
    private init() {}
    
    /// Request notification permissions
    func requestAuthorization() async throws {
        let granted = try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else {
            throw DigestError.notificationPermissionDenied
        }
    }
    
    /// Schedule daily digest notification at preferred time
    func scheduleDailyDigest(at time: DateComponents = DateComponents(hour: 9, minute: 0)) async throws {
        // Cancel existing
        notificationCenter.removePendingNotificationRequests(withIdentifiers: ["daily-digest"])
        
        // Create new notification
        let content = UNMutableNotificationContent()
        content.title = "Your Daily Action Digest"
        content.body = "Review what needs your attention today"
        content.sound = .default
        content.categoryIdentifier = "DAILY_DIGEST"
        content.userInfo = ["type": "daily_digest"]
        
        // Trigger daily at specified time
        let trigger = UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        
        let request = UNNotificationRequest(
            identifier: "daily-digest",
            content: content,
            trigger: trigger
        )
        
        try await notificationCenter.add(request)
    }
    
    /// Setup notification categories and actions
    func setupNotificationCategories() {
        let promoteAction = UNNotificationAction(
            identifier: "PROMOTE_ACTION",
            title: "Promote to Important",
            options: [.foreground]
        )
        
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss",
            options: [.destructive]
        )
        
        let category = UNNotificationCategory(
            identifier: "DAILY_DIGEST",
            actions: [promoteAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        
        notificationCenter.setNotificationCategories([category])
    }
}

enum DigestError: LocalizedError {
    case notificationPermissionDenied
    
    var errorDescription: String? {
        switch self {
        case .notificationPermissionDenied:
            return "Notification permission denied. Please enable in Settings."
        }
    }
}

// MARK: - Settings View Integration

struct DigestSettingsView: View {
    @StateObject private var viewModel = DigestSettingsViewModel()
    @State private var digestTime = DateComponents(hour: 9, minute: 0)
    @State private var isEnabled = false
    @State private var showError: String?
    
    var body: some View {
        Form {
            Section {
                Toggle("Daily Digest Notification", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        Task {
                            if newValue {
                                await viewModel.enableDigest(
                                    digestTime: digestTime,
                                    onDisable: { isEnabled = false },
                                    onError: { showError = $0 }
                                )
                            } else {
                                viewModel.disableDigest()
                            }
                        }
                    }
                
                if isEnabled {
                    DatePicker(
                        "Notification Time",
                        selection: Binding(
                            get: {
                                let components = digestTime
                                return Calendar.current.date(from: components) ?? Date()
                            },
                            set: { newDate in
                                digestTime = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                                Task {
                                    let ok = await viewModel.scheduleDigest(at: digestTime)
                                    if !ok {
                                        showError = "Failed to schedule digest notification."
                                    }
                                }
                            }
                        ),
                        displayedComponents: [.hourAndMinute]
                    )
                }
            } header: {
                Text("Daily Digest")
            } footer: {
                Text("Get a notification each day with borderline items that need your review.")
            }
        }
        .navigationTitle("Digest Settings")
        .alert(
            "Error",
            isPresented: Binding(
                get: { showError != nil },
                set: { if !$0 { showError = nil } }
            )
        ) {
            Button("OK") { showError = nil }
        } message: {
            Text(showError ?? "Something went wrong")
        }
    }
}

@MainActor
final class DigestSettingsViewModel: ObservableObject {
    private let scheduler = DailyDigestScheduler.shared

    func enableDigest(
        digestTime: DateComponents,
        onDisable: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async {
        do {
            try await scheduler.requestAuthorization()
            try await scheduler.scheduleDailyDigest(at: digestTime)
        } catch {
            await onDisable()
            await onError(error.localizedDescription)
        }
    }

    func scheduleDigest(at digestTime: DateComponents) async -> Bool {
        do {
            try await scheduler.scheduleDailyDigest(at: digestTime)
            return true
        } catch {
            return false
        }
    }

    func disableDigest() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["daily-digest"])
    }
}
