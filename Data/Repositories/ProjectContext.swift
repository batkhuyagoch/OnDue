// ProjectContext.swift
// This file provides context for development and AI assistance

/*
 PROJECT: OnDue - Email Action Sidekick
 PLATFORM: iOS (SwiftUI + UIKit)
 LANGUAGE: Swift 6.0+
 
 ============================================================
 ARCHITECTURE PATTERNS
 ============================================================
 
 1. SWIFTUI PATTERNS:
    - ViewModels: @MainActor + @ObservableObject
    - Views: struct + View protocol
    - State: @StateObject, @Published, @State
    - Import: SwiftUI (NOT Combine for @Published)
    
    Example:
    ```swift
    import SwiftUI  // ← Use this for @Published
    
    @MainActor
    final class MyViewModel: ObservableObject {
        @Published var items: [Item] = []
    }
    ```
 
 2. CONCURRENCY:
    - Use async/await throughout
    - Avoid Combine (except where needed)
    - Repositories are @unchecked Sendable
    - Database operations use DatabasePool.read/write
    
 3. DEPENDENCY INJECTION:
    - Central AppEnvironment struct
    - Pass environment to ViewModels
    - Repository pattern for data access
    
    Example:
    ```swift
    init(environment: AppEnvironment) {
        self.environment = environment
    }
    ```
 
 ============================================================
 KEY DEPENDENCIES
 ============================================================
 
 - GRDB: SQLite database with async support
 - GoogleSignIn: Gmail OAuth authentication
 - BackgroundTasks: Background sync scheduling
 - UserNotifications: Daily digest notifications
 
 ============================================================
 DATA FLOW
 ============================================================
 
 View → ViewModel → Repository → Database
   ↓        ↓           ↓            ↓
 SwiftUI  Logic    Queries      SQLite (GRDB)
 
 ============================================================
 CURRENT STATUS (Phase 1)
 ============================================================
 
 ✅ COMPLETE:
 - Timeline view with weekly grouping
 - Daily digest notifications
 - Enhanced rule engine (20+ signals)
 - Smart date extraction
 - Manual promotion feature
 
 🔨 INTEGRATING:
 - Files added to Xcode project ✓
 - Target membership configured ✓
 - Building and testing...
 
 ⚠️ NOTES:
 - Phase1Tests.swift should be removed or moved to test target
 - All 7 new Swift files must be in main app target
 
 📋 NEXT (Phase 2):
 - Calendar integration (EventKit)
 - Smart reminders (7d, 3d, 1d before)
 - Bills dashboard
 
 ============================================================
 COMMON PATTERNS IN THIS PROJECT
 ============================================================
 
 1. Obligation Detection:
    - Parse email with EmailParser
    - Score with RuleEngine
    - Store with ObligationRepository
 
 2. UI Updates:
    - Fetch data in ViewModel.load()
    - Update @Published properties
    - SwiftUI auto-refreshes
 
 3. User Actions:
    - User taps button
    - ViewModel calls repository
    - Repository updates database
    - Reload data
 
 ============================================================
 FILE ORGANIZATION
 ============================================================
 
 Models/
   - Obligation.swift (ObligationRecord, ObligationItem)
   - Feedback.swift (FeedbackRecord)
 
 Repositories/
   - ObligationRepository.swift
   - MessageRepository.swift
   - FeedbackRepository.swift
   - RuleWeightRepository.swift
 
ViewModels/
  - DigestViewModel.swift
 
Views/
  - DigestView.swift
  - SettingsView.swift
 
 Services/
   - GmailClient.swift
   - RuleEngine.swift
   - EmailParser.swift
   - DateExtractor.swift
 
 Core/
   - Database.swift
   - AppEnvironment.swift
   - Migrations.swift
 
 ============================================================
 IMPORTANT NOTES FOR AI ASSISTANTS
 ============================================================
 
 1. When creating ViewModels:
    - ALWAYS import SwiftUI (not Combine)
    - ALWAYS use @MainActor
    - ALWAYS use ObservableObject protocol
 
 2. When creating Views:
    - Import SwiftUI
    - Use struct, not class
    - Prefer @StateObject for owned ViewModels
 
 3. When creating Repositories:
    - Mark as @unchecked Sendable
    - Use async/await for all operations
    - Always use database.readAsync/writeAsync
 
 4. Database Operations:
    - Read: database.readAsync { db in ... }
    - Write: database.writeAsync { db in ... }
    - Use GRDB's record types (FetchableRecord, PersistableRecord)
 
5. Testing:
   - Use XCTest for current test suite
 
 ============================================================
 DEBUGGING TIPS
 ============================================================
 
1. Obligations not showing data?
   → Check ObligationProjectionRepository.fetchItems()
   → Check RuleEngine assessment decisions
 
 2. Notifications not working?
    → Check UNUserNotificationCenter permissions
    → Verify setupNotificationCategories() called
 
 3. Rule engine not detecting?
    → Log matched signals in RuleEngine
    → Check signal.matches() logic
 
 4. Database errors?
    → Check Migrations.swift
    → Verify table schema matches records
 
 ============================================================
 SWIFT 6 CONCURRENCY NOTES
 ============================================================
 
 - DatabasePool is thread-safe (Sendable)
 - ViewModels are @MainActor (run on main thread)
 - Repositories are @unchecked Sendable (GRDB handles safety)
 - Use Task { } for background work
 - Use await to call async functions
 
 ============================================================
 VERSION HISTORY
 ============================================================
 
 v0.1 (Jan 2026) - Initial scaffold
 v0.2 (Feb 2026) - Basic digest view
 v1.0 (Feb 6, 2026) - Phase 1 complete ✅
 
 ============================================================
 */

// This file is documentation only and should not be compiled
// To keep it from being compiled, don't add it to any target
// Just keep it in the project for reference
