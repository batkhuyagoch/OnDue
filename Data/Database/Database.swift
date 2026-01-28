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
            fatalError("Failed to initialize database: \(error)")
        }
    }()
    
    init(inMemory: Bool = false) throws {
        if inMemory {
            dbPool = try DatabasePool(path: ":memory:")
        } else {
            let fileManager = FileManager.default
            let appSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let dbURL = appSupportURL.appendingPathComponent("OnDue.sqlite")
            dbPool = try DatabasePool(path: dbURL.path)
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
