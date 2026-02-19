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
    
    init(inMemory: Bool = false) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        if !inMemory {
            config.prepareDatabase { db in
                try db.execute(sql: "PRAGMA journal_mode=WAL")
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
    
    private func migrate() throws {
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
}
