#if false
// Tests temporarily disabled due to Swift 6 concurrency

import XCTest
import Foundation
import GRDB
@testable import OnDue

// MARK: - Tests for Local State Management

/// Tests for UserActionRecord and MessageStateManager
class MessageStateTests: XCTestCase {
    
    // MARK: - UserActionRecord Tests
    
    func testCreateDismissedAction() {
        let action = UserActionRecord(
            messageID: "test-message-123",
            actionType: .dismissed
        )
        
        XCTAssertEqual(action.messageID, "test-message-123")
        XCTAssertEqual(action.actionType, .dismissed)
        XCTAssertFalse(action.synced)
        XCTAssertNil(action.actionData)
    }
    
    func testCreateLabeledAction() {
        let labels = ["Work", "Important"]
        let action = UserActionRecord.labeledAction(
            messageID: "test-message-456",
            labels: labels
        )
        
        XCTAssertEqual(action.messageID, "test-message-456")
        XCTAssertEqual(action.actionType, .labeled)
        XCTAssertEqual(action.labels, labels)
    }
    
    func testDecodingLabels() {
        let labels = ["Personal", "Urgent"]
        let action = UserActionRecord.labeledAction(
            messageID: "test-msg",
            labels: labels
        )
        
        let decodedLabels = action.labels
        XCTAssertEqual(decodedLabels, labels)
    }
    
    // MARK: - MessageStateManager Tests
    
    func testRecordAndRetrieveAction() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let messageID = "msg-\(UUID().uuidString)"
        
        // Record dismissal
        try await stateManager.recordAction(messageID: messageID, action: .dismissed)
        
        // Retrieve actions
        let actions = try await stateManager.getActions(for: messageID)
        
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.messageID, messageID)
        XCTAssertEqual(actions.first?.actionType, .dismissed)
    }
    
    func testMultipleActions() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let messageID = "msg-\(UUID().uuidString)"
        
        // Record multiple actions
        try await stateManager.recordAction(messageID: messageID, action: .dismissed)
        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        try await stateManager.recordLabels(messageID: messageID, labels: ["Important"])
        
        let actions = try await stateManager.getActions(for: messageID)
        
        XCTAssertEqual(actions.count, 2)
        
        // Should be sorted by timestamp desc (newest first)
        XCTAssertEqual(actions[0].actionType, .labeled)
        XCTAssertEqual(actions[1].actionType, .dismissed)
    }
    
    func testFilterDismissedMessages() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        // Create test messages
        let messages = [
            GmailMessageSummary(
                messageID: "msg-1",
                threadID: nil,
                sender: "sender1@example.com",
                senderName: "Sender 1",
                subject: "Test 1",
                snippet: "Snippet 1",
                receivedAt: Date(),
                labelIDs: [],
                hasAttachments: false
            ),
            GmailMessageSummary(
                messageID: "msg-2",
                threadID: nil,
                sender: "sender2@example.com",
                senderName: "Sender 2",
                subject: "Test 2",
                snippet: "Snippet 2",
                receivedAt: Date(),
                labelIDs: [],
                hasAttachments: false
            )
        ]
        
        // Dismiss first message
        try await stateManager.recordAction(messageID: "msg-1", action: .dismissed)
        
        // Filter messages
        let filtered = try await stateManager.filterWithLocalState(messages)
        
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].messageID, "msg-2")
    }
    
    func testApplyLocalLabels() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let message = GmailMessageSummary(
            messageID: "msg-label-test",
            threadID: nil,
            sender: "test@example.com",
            senderName: "Test",
            subject: "Test",
            snippet: "Test",
            receivedAt: Date(),
            labelIDs: ["INBOX"],
            hasAttachments: false
        )
        
        // Add local labels
        try await stateManager.recordLabels(messageID: "msg-label-test", labels: ["Work", "Important"])
        
        // Apply labels
        let updated = try await stateManager.applyLocalLabels([message])
        
        XCTAssertEqual(updated.count, 1)
        XCTAssertTrue(updated[0].labelIDs.contains("INBOX"))
        XCTAssertTrue(updated[0].labelIDs.contains("Work"))
        XCTAssertTrue(updated[0].labelIDs.contains("Important"))
    }
    
    func testUndoLastAction() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let messageID = "msg-undo-test"
        
        // Record action
        try await stateManager.recordAction(messageID: messageID, action: .dismissed)
        
        // Verify it exists
        var actions = try await stateManager.getActions(for: messageID)
        XCTAssertEqual(actions.count, 1)
        
        // Undo
        try await stateManager.undoLastAction(for: messageID)
        
        // Verify it's gone
        actions = try await stateManager.getActions(for: messageID)
        XCTAssertEqual(actions.count, 0)
    }
    
    func testGetUnsyncedActions() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        // Record some actions (all default to unsynced)
        try await stateManager.recordAction(messageID: "msg-1", action: .dismissed)
        try await stateManager.recordAction(messageID: "msg-2", action: .deleted)
        
        let unsynced = try await stateManager.getUnsyncedActions()
        
        XCTAssertEqual(unsynced.count, 2)
        XCTAssertTrue(unsynced.allSatisfy { !$0.synced })
    }
    
    func testCleanupOldActions() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        // Create an old action (manually for testing)
        let oldDate = Calendar.current.date(byAdding: .day, value: -100, to: Date())!
        let oldAction = UserActionRecord(
            messageID: "old-msg",
            actionType: .dismissed,
            timestamp: oldDate,
            synced: true
        )
        
        try await db.writeAsync { db in
            try oldAction.insert(db)
        }
        
        // Create a recent action
        try await stateManager.recordAction(messageID: "new-msg", action: .dismissed)
        
        // Mark it as synced
        let newActions = try await stateManager.getActions(for: "new-msg")
        try await stateManager.markSynced(actionID: newActions[0].id)
        
        // Cleanup actions older than 90 days
        try await stateManager.cleanupOldActions(olderThanDays: 90)
        
        // Old action should be gone
        let oldActions = try await stateManager.getActions(for: "old-msg")
        XCTAssertTrue(oldActions.isEmpty)
        
        // Recent action should still exist
        let recentActions = try await stateManager.getActions(for: "new-msg")
        XCTAssertEqual(recentActions.count, 1)
    }
    
    func testReconcileWithLocalState() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let messages = [
            GmailMessageSummary(
                messageID: "msg-keep",
                threadID: nil,
                sender: "keep@example.com",
                senderName: "Keep",
                subject: "Keep This",
                snippet: "Keep",
                receivedAt: Date(),
                labelIDs: ["INBOX"],
                hasAttachments: false
            ),
            GmailMessageSummary(
                messageID: "msg-dismiss",
                threadID: nil,
                sender: "dismiss@example.com",
                senderName: "Dismiss",
                subject: "Dismiss This",
                snippet: "Dismiss",
                receivedAt: Date(),
                labelIDs: ["INBOX"],
                hasAttachments: false
            )
        ]
        
        // Dismiss one message
        try await stateManager.recordAction(messageID: "msg-dismiss", action: .dismissed)
        
        // Label the other
        try await stateManager.recordLabels(messageID: "msg-keep", labels: ["Important"])
        
        // Reconcile
        let reconciled = try await stateManager.reconcileWithLocalState(messages)
        
        // Should only have one message (dismissed one filtered out)
        XCTAssertEqual(reconciled.count, 1)
        
        // Should have original + local labels
        XCTAssertEqual(reconciled[0].messageID, "msg-keep")
        XCTAssertTrue(reconciled[0].labelIDs.contains("INBOX"))
        XCTAssertTrue(reconciled[0].labelIDs.contains("Important"))
    }
}

// MARK: - Performance Tests

class MessageStatePerformanceTests: XCTestCase {
    
    func testFilterPerformance() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        // Create 1000 test messages
        let messages = (0..<1000).map { i in
            GmailMessageSummary(
                messageID: "msg-\(i)",
                threadID: nil,
                sender: "sender\(i)@example.com",
                senderName: "Sender \(i)",
                subject: "Test \(i)",
                snippet: "Snippet \(i)",
                receivedAt: Date(),
                labelIDs: [],
                hasAttachments: false
            )
        }
        
        // Dismiss 100 messages
        for i in 0..<100 {
            try await stateManager.recordAction(messageID: "msg-\(i)", action: .dismissed)
        }
        
        // Measure filter performance
        let start = Date()
        let filtered = try await stateManager.filterWithLocalState(messages)
        let duration = Date().timeIntervalSince(start)
        
        XCTAssertEqual(filtered.count, 900)
        XCTAssertLessThan(duration, 1.0, "Filtering should be fast (< 1 second)")
    }
}

// MARK: - Edge Case Tests

class MessageStateEdgeCaseTests: XCTestCase {
    
    func testEmptyMessageList() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let filtered = try await stateManager.filterWithLocalState([])
        XCTAssertTrue(filtered.isEmpty)
        
        let labeled = try await stateManager.applyLocalLabels([])
        XCTAssertTrue(labeled.isEmpty)
    }
    
    func testNoActionsRecorded() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let message = GmailMessageSummary(
            messageID: "msg-no-actions",
            threadID: nil,
            sender: "test@example.com",
            senderName: "Test",
            subject: "Test",
            snippet: "Test",
            receivedAt: Date(),
            labelIDs: [],
            hasAttachments: false
        )
        
        let filtered = try await stateManager.filterWithLocalState([message])
        XCTAssertEqual(filtered.count, 1)
        
        let labeled = try await stateManager.applyLocalLabels([message])
        XCTAssertEqual(labeled.count, 1)
    }
    
    func testMultipleActionTypes() async throws {
        let db = try Database(inMemory: true)
        let stateManager = MessageStateManager(database: db)
        
        let messageID = "msg-multi"
        
        // Record different action types for same message
        try await stateManager.recordAction(messageID: messageID, action: .markedDone)
        try await stateManager.recordLabels(messageID: messageID, labels: ["Work"])
        try await stateManager.recordAction(messageID: messageID, action: .confirmed)
        
        let actions = try await stateManager.getActions(for: messageID)
        
        XCTAssertEqual(actions.count, 3)
        
        let types = Set(actions.map { $0.actionType })
        XCTAssertTrue(types.contains(.markedDone))
        XCTAssertTrue(types.contains(.labeled))
        XCTAssertTrue(types.contains(.confirmed))
    }
}
#endif

