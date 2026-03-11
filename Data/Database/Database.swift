import Foundation
import GRDB

final class Database {
    
    /// The database connection pool
    let dbPool: DatabasePool
    
    /// Shared instance for the app
    static let shared: Database = {
        do {
            return try Database()
        } catch {
            initializationError = error
            Logger.info("Failed to initialize database: \(error)")
            if let fallback = try? Database(inMemory: true) {
                Logger.info("Falling back to in-memory database.")
                return fallback
            }
            fatalError("Failed to initialize database: \(error)")
        }
    }()

    static var initializationError: Error?
    
    nonisolated init(inMemory: Bool = false) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        
        // Mobile-optimized: Balance performance with battery/thermal constraints
        config.maximumReaderCount = 3  // Limit concurrent reads (was 5, too aggressive for mobile)
        config.busyMode = .timeout(3.0)  // Shorter timeout for mobile responsiveness
        
        if !inMemory {
            config.prepareDatabase { db in
                // WAL mode for concurrent reads/writes
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                
                // Mobile-optimized performance settings
                try db.execute(sql: "PRAGMA synchronous=NORMAL")  // Fast + safe in WAL
                try db.execute(sql: "PRAGMA cache_size=-8000")    // 8MB cache (not 64MB!)
                try db.execute(sql: "PRAGMA temp_store=MEMORY")   // Temp tables in memory
                try db.execute(sql: "PRAGMA mmap_size=67108864")  // 64MB mmap (not 256MB!)
                
                // Mobile-specific: Prevent checkpoint stalls
                try db.execute(sql: "PRAGMA wal_autocheckpoint=100")  // Checkpoint every 100 pages
                
                // Query optimization
                try db.execute(sql: "PRAGMA automatic_index=ON")
            }
        }

        if inMemory {
            // DatabasePool requires WAL support, which plain ":memory:" cannot provide.
            // Use an isolated temp file for tests while preserving inMemory semantics.
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("OnDue-Test-\(UUID().uuidString).sqlite")
            dbPool = try DatabasePool(path: tempURL.path, configuration: config)
        } else {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dbURL = appSupportURL.appendingPathComponent("OnDue.sqlite")
            dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        }
        
        try migrate()
    }
    
    nonisolated private func migrate() throws {
        var migrator = DatabaseMigrator()
        
        #if DEBUG
        // Speed up development by nuking the database when migrations change
        migrator.eraseDatabaseOnSchemaChange = true
        #endif
        
        Migrations.register(&migrator)
        try migrator.migrate(dbPool)
    }
}

// MARK: - Database Access Helpers

extension Database {
    
    /// Perform a read-only database operation
    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }
    
    /// Perform a write database operation
    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbPool.write(block)
    }
    
    /// Perform an async read-only operation
    func readAsync<T: Sendable>(_ block: @Sendable @escaping (GRDB.Database) throws -> T) async throws -> T {
        try await dbPool.read(block)
    }
    
    /// Perform an async write operation
    func writeAsync<T: Sendable>(_ block: @Sendable @escaping (GRDB.Database) throws -> T) async throws -> T {
        try await dbPool.write(block)
    }
    
    /// Checkpoint the WAL file to prevent it from growing too large
    /// Call this periodically (e.g., after large syncs)
    func checkpoint() async throws {
        try await dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
    
    /// Optimize database (should be called periodically, e.g., weekly)
    func optimize() async throws {
        try await dbPool.write { db in
            try db.execute(sql: "PRAGMA optimize")
            try db.execute(sql: "ANALYZE")
        }
    }
}
