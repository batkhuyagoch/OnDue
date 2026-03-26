import Foundation
import GRDB

struct BlockedSendersAndDomains: Sendable {
    let senders: Set<String>
    let domains: Set<String>

    func isBlocked(sender: String?, domain: String?) -> Bool {
        if let s = sender?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !s.isEmpty, senders.contains(s) {
            return true
        }
        if let d = domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !d.isEmpty, domains.contains(d) {
            return true
        }
        return false
    }
}

protocol SuppressionRepositorying: Sendable {
    func addSender(mailboxAccountId: String, sender: String) async throws
    func addDomain(mailboxAccountId: String, domain: String) async throws
    func isBlocked(mailboxAccountId: String, sender: String?, domain: String?) async throws -> Bool
    func fetchAllBlocked(mailboxAccountId: String) async throws -> BlockedSendersAndDomains
}

final class SuppressionRepository: SuppressionRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func addSender(mailboxAccountId: String, sender: String) async throws {
        try await saveSuppression(
            mailboxAccountId: mailboxAccountId,
            type: .sender,
            value: sender
        )
    }

    func addDomain(mailboxAccountId: String, domain: String) async throws {
        try await saveSuppression(
            mailboxAccountId: mailboxAccountId,
            type: .domain,
            value: domain
        )
    }

    func isBlocked(mailboxAccountId: String, sender: String?, domain: String?) async throws -> Bool {
        let normalizedSender = sender?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return try await database.readAsync { db in
            if let senderValue = normalizedSender, !senderValue.isEmpty {
                let senderBlocked = try SuppressionRecord
                    .filter(Column("isEnabled") == true)
                    .filter(Column("type") == SuppressionRecord.SuppressionType.sender)
                    .filter(Column("value") == senderValue)
                    .filter(Column("mailboxAccountId") == mailboxAccountId || Column("mailboxAccountId") == nil)
                    .fetchCount(db) > 0
                if senderBlocked { return true }
            }

            if let domainValue = normalizedDomain, !domainValue.isEmpty {
                let domainBlocked = try SuppressionRecord
                    .filter(Column("isEnabled") == true)
                    .filter(Column("type") == SuppressionRecord.SuppressionType.domain)
                    .filter(Column("value") == domainValue)
                    .filter(Column("mailboxAccountId") == mailboxAccountId || Column("mailboxAccountId") == nil)
                    .fetchCount(db) > 0
                if domainBlocked { return true }
            }

            return false
        }
    }

    func fetchAllBlocked(mailboxAccountId: String) async throws -> BlockedSendersAndDomains {
        try await database.readAsync { db in
            let records = try SuppressionRecord
                .filter(Column("isEnabled") == true)
                .filter(Column("mailboxAccountId") == mailboxAccountId || Column("mailboxAccountId") == nil)
                .fetchAll(db)

            var senders = Set<String>()
            var domains = Set<String>()
            for record in records {
                switch record.type {
                case .sender: senders.insert(record.value)
                case .domain: domains.insert(record.value)
                case .subjectPattern: break
                }
            }
            return BlockedSendersAndDomains(senders: senders, domains: domains)
        }
    }

    private func saveSuppression(
        mailboxAccountId: String,
        type: SuppressionRecord.SuppressionType,
        value: String
    ) async throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }

        try await database.writeAsync { db in
            let existing = try SuppressionRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("type") == type)
                .filter(Column("value") == normalized)
                .fetchOne(db)

            if var existing {
                existing.isEnabled = true
                try existing.save(db)
            } else {
                let record = SuppressionRecord(
                    mailboxAccountId: mailboxAccountId,
                    type: type,
                    value: normalized,
                    isEnabled: true
                )
                try record.insert(db)
            }
        }
    }
}
