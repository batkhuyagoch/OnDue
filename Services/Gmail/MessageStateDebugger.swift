import Foundation
import GRDB

// MARK: - Debug Helpers for Local State Management

#if DEBUG

/// Debug utilities for inspecting and managing local message state
enum MessageStateDebugger {
    
    /// Prints all recorded user actions to the console
    static func printAllActions() async {
        do {
            let actions = try await Database.shared.readAsync { db in
                try UserActionRecord
                    .order(UserActionRecord.Columns.timestamp.desc)
                    .fetchAll(db)
            }
            
            print("\n📊 Total Actions Recorded: \(actions.count)\n")
            
            if actions.isEmpty {
                print("No actions recorded yet.")
                return
            }
            
            let grouped = Dictionary(grouping: actions, by: { $0.actionType })
            
            for (actionType, actionList) in grouped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("  \(actionType.rawValue.uppercased()): \(actionList.count)")
            }
            
            print("\n📝 Recent Actions:\n")
            for action in actions.prefix(20) {
                let syncStatus = action.synced ? "✓" : "○"
                print("  \(syncStatus) [\(action.actionType.rawValue)] \(action.messageID) - \(formatDate(action.timestamp))")
                if let data = action.actionData {
                    print("      Data: \(data)")
                }
            }
            
            if actions.count > 20 {
                print("\n  ... and \(actions.count - 20) more")
            }
            
        } catch {
            print("❌ Error fetching actions: \(error)")
        }
    }
    
    /// Prints actions for a specific message
    static func printActions(forMessageID messageID: String) async {
        do {
            let actions = try await Database.shared.readAsync { db in
                try UserActionRecord
                    .filter(UserActionRecord.Columns.messageID == messageID)
                    .order(UserActionRecord.Columns.timestamp.desc)
                    .fetchAll(db)
            }
            
            print("\n📧 Actions for message: \(messageID)\n")
            
            if actions.isEmpty {
                print("No actions recorded for this message.")
                return
            }
            
            for action in actions {
                let syncStatus = action.synced ? "✓ synced" : "○ pending"
                print("  [\(action.actionType.rawValue)] \(formatDate(action.timestamp)) - \(syncStatus)")
                if let data = action.actionData {
                    print("      Data: \(data)")
                }
            }
            
        } catch {
            print("❌ Error fetching actions: \(error)")
        }
    }
    
    /// Prints summary statistics
    static func printStatistics() async {
        do {
            let stats = try await Database.shared.readAsync { db -> Stats in
                let total = try UserActionRecord.fetchCount(db)
                let synced = try UserActionRecord
                    .filter(UserActionRecord.Columns.synced == true)
                    .fetchCount(db)
                let unsynced = total - synced
                
                let byType = try UserActionRecord.UserActionType.allCases.map { type -> (UserActionRecord.UserActionType, Int) in
                    let count = try UserActionRecord
                        .filter(UserActionRecord.Columns.actionType == type.rawValue)
                        .fetchCount(db)
                    return (type, count)
                }
                
                let uniqueMessages = try UserActionRecord
                    .select(UserActionRecord.Columns.messageID)
                    .distinct()
                    .fetchCount(db)
                
                return Stats(
                    total: total,
                    synced: synced,
                    unsynced: unsynced,
                    uniqueMessages: uniqueMessages,
                    byType: byType
                )
            }
            
            print("\n📊 Local State Statistics\n")
            print("  Total Actions: \(stats.total)")
            print("  Synced: \(stats.synced)")
            print("  Pending Sync: \(stats.unsynced)")
            print("  Unique Messages: \(stats.uniqueMessages)")
            print("\n  By Action Type:")
            
            for (type, count) in stats.byType where count > 0 {
                print("    \(type.rawValue): \(count)")
            }
            
        } catch {
            print("❌ Error fetching statistics: \(error)")
        }
    }
    
    /// Clears all recorded actions (use with caution!)
    static func clearAllActions() async {
        do {
            let deleted = try await Database.shared.writeAsync { db in
                try UserActionRecord.deleteAll(db)
            }
            print("🗑️ Cleared \(deleted) actions")
        } catch {
            print("❌ Error clearing actions: \(error)")
        }
    }
    
    /// Clears actions for a specific message
    static func clearActions(forMessageID messageID: String) async {
        do {
            let deleted = try await Database.shared.writeAsync { db in
                try UserActionRecord
                    .filter(UserActionRecord.Columns.messageID == messageID)
                    .deleteAll(db)
            }
            print("🗑️ Cleared \(deleted) actions for message \(messageID)")
        } catch {
            print("❌ Error clearing actions: \(error)")
        }
    }
    
    /// Simulates recording test actions (for development)
    static func createTestActions() async {
        do {
            try await Database.shared.writeAsync { db in
                let testActions = [
                    UserActionRecord(messageID: "test-msg-1", actionType: .dismissed),
                    UserActionRecord(messageID: "test-msg-2", actionType: .deleted),
                    UserActionRecord(messageID: "test-msg-3", actionType: .markedDone),
                    UserActionRecord.labeledAction(messageID: "test-msg-4", labels: ["Important", "Work"])
                ]
                
                for action in testActions {
                    try action.insert(db)
                }
            }
            print("✅ Created \(4) test actions")
        } catch {
            print("❌ Error creating test actions: \(error)")
        }
    }
    
    // MARK: - Private Helpers
    
    private struct Stats {
        let total: Int
        let synced: Int
        let unsynced: Int
        let uniqueMessages: Int
        let byType: [(UserActionRecord.UserActionType, Int)]
    }
    
    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - SwiftUI Debug View (Optional)

#if canImport(SwiftUI)
import SwiftUI

/// A debug view for inspecting local message state
struct MessageStateDebugView: View {
    @State private var actions: [UserActionRecord] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var selectedFilter: UserActionRecord.UserActionType? = nil
    
    var body: some View {
        List {
            Section {
                Button("Refresh") {
                    Task { await loadActions() }
                }
                
                Button("Print Stats") {
                    Task { await MessageStateDebugger.printStatistics() }
                }
                
                Button("Clear All", role: .destructive) {
                    Task {
                        await MessageStateDebugger.clearAllActions()
                        await loadActions()
                    }
                }
            }
            
            Section("Filter") {
                Picker("Type", selection: $selectedFilter) {
                    Text("All").tag(nil as UserActionRecord.UserActionType?)
                    ForEach(UserActionRecord.UserActionType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type as UserActionRecord.UserActionType?)
                    }
                }
            }
            
            Section("Actions (\(filteredActions.count))") {
                if isLoading {
                    ProgressView()
                } else if filteredActions.isEmpty {
                    Text("No actions recorded")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredActions) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(action.actionType.rawValue)
                                    .font(.headline)
                                Spacer()
                                if action.synced {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                }
                            }
                            
                            Text(action.messageID)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Text(action.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            
                            if let data = action.actionData {
                                Text("Data: \(data)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                Task {
                                    await MessageStateDebugger.clearActions(forMessageID: action.messageID)
                                    await loadActions()
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Local State Debug")
        .searchable(text: $searchText)
        .onChange(of: selectedFilter) { _, _ in
            Task { await loadActions() }
        }
        .task {
            await loadActions()
        }
    }
    
    private var filteredActions: [UserActionRecord] {
        var filtered = actions
        
        if let selectedFilter {
            filtered = filtered.filter { $0.actionType == selectedFilter }
        }
        
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.messageID.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return filtered
    }
    
    private func loadActions() async {
        isLoading = true
        do {
            actions = try await Database.shared.readAsync { db in
                try UserActionRecord
                    .order(UserActionRecord.Columns.timestamp.desc)
                    .fetchAll(db)
            }
            isLoading = false
        } catch {
            print("Error loading actions: \(error)")
            isLoading = false
        }
    }
}

// MARK: - Usage in Settings or Debug Menu

/*
// Add to your Settings or a debug menu:

NavigationLink("Debug: Local State") {
    MessageStateDebugView()
}
*/

#endif // canImport(SwiftUI)

// MARK: - Console Commands (for use in breakpoints or LLDB)

/*

To use these in a breakpoint or debug console:

1. Set a breakpoint
2. In LLDB console, run:

   po Task { await MessageStateDebugger.printAllActions() }
   po Task { await MessageStateDebugger.printStatistics() }
   po Task { await MessageStateDebugger.clearAllActions() }

Or add to your debug menu:

   Button("Debug: Print Actions") {
       Task { await MessageStateDebugger.printAllActions() }
   }

*/

#endif // DEBUG
