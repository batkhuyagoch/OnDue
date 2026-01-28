import Foundation
import GRDB

enum FTS {
    static let tableName = "message_fts"
    
    /// Search messages using FTS5
    static func searchMessages(
        query: String,
        mailboxAccountId: String,
        in db: GRDB.Database,
        limit: Int = 50
    ) throws -> [MessageRecord] {
        guard !query.isEmpty else { return [] }
        
        // Escape special FTS5 characters and create search pattern
        let sanitized = sanitizeQuery(query)
        
        let sql = """
            SELECT message.*
            FROM message
            JOIN message_fts ON message_fts.rowid = message.pk
            WHERE message_fts MATCH ?
              AND message.mailboxAccountId = ?
              AND message.isDeleted = 0
            ORDER BY rank
            LIMIT ?
        """
        
        return try MessageRecord.fetchAll(db, sql: sql, arguments: [sanitized, mailboxAccountId, limit])
    }
    
    /// Sanitize user input for FTS5 query
    private static func sanitizeQuery(_ query: String) -> String {
        // Remove special FTS5 operators for safety
        let cleaned = query
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Split into words and add prefix matching
        let words = cleaned.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        return words.map { "\($0)*" }.joined(separator: " ")
    }
}
