import Foundation
import GRDB

enum Migrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        
        migrator.registerMigration("v1_initial") { db in
            
            // MARK: - mailbox_account
            
            try db.create(table: "mailbox_account") { t in
                t.column("id", .text).primaryKey()
                t.column("provider", .text).notNull()
                t.column("emailAddress", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("lastSyncAt", .datetime)
                t.column("gmailLastHistoryId", .text)
                t.column("lastFullSyncAt", .datetime)
                t.column("syncStatus", .text).notNull().defaults(to: "ok")
                t.column("syncError", .text)
                
                t.uniqueKey(["provider", "emailAddress"])
            }
            
            // MARK: - message
            
            try db.create(table: "message") { t in
                t.autoIncrementedPrimaryKey("pk")
                t.column("id", .text).notNull().unique()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                
                t.column("providerMessageId", .text).notNull()
                t.column("threadId", .text)
                t.column("internalDate", .datetime).notNull()
                
                t.column("fromEmail", .text).notNull()
                t.column("fromName", .text)
                t.column("fromDomain", .text)
                
                t.column("subject", .text).notNull()
                t.column("snippet", .text)
                t.column("bodyText", .text)
                t.column("hasAttachments", .boolean).notNull().defaults(to: false)
                
                t.column("labelIds", .text)
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("ingestedAt", .datetime).notNull()
                
                t.uniqueKey(["mailboxAccountId", "providerMessageId"])
            }
            
            // Message indexes
            try db.create(index: "message_mailbox_date", on: "message", columns: ["mailboxAccountId", "internalDate"])
            try db.create(index: "message_mailbox_from", on: "message", columns: ["mailboxAccountId", "fromEmail"])
            try db.create(index: "message_mailbox_thread", on: "message", columns: ["mailboxAccountId", "threadId"])
            
            // MARK: - message_fts (FTS5)
            
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.tokenizer = .porter(wrapping: .unicode61())
                t.content = "message"
                t.contentRowID = "pk"
                t.column("subject")
                t.column("bodyText")
            }
            
            // FTS triggers
            try db.execute(sql: """
                CREATE TRIGGER message_ai AFTER INSERT ON message BEGIN
                  INSERT INTO message_fts(rowid, subject, bodyText)
                  VALUES (new.pk, new.subject, coalesce(new.bodyText, ''));
                END;
            """)
            
            try db.execute(sql: """
                CREATE TRIGGER message_ad AFTER DELETE ON message BEGIN
                  INSERT INTO message_fts(message_fts, rowid, subject, bodyText)
                  VALUES('delete', old.pk, old.subject, coalesce(old.bodyText, ''));
                END;
            """)
            
            try db.execute(sql: """
                CREATE TRIGGER message_au AFTER UPDATE OF subject, bodyText ON message BEGIN
                  INSERT INTO message_fts(message_fts, rowid, subject, bodyText)
                  VALUES('delete', old.pk, old.subject, coalesce(old.bodyText, ''));
                  INSERT INTO message_fts(rowid, subject, bodyText)
                  VALUES (new.pk, new.subject, coalesce(new.bodyText, ''));
                END;
            """)
            
            // MARK: - candidate_score
            
            try db.create(table: "candidate_score") { t in
                t.column("messagePk", .integer).notNull()
                    .references("message", column: "pk", onDelete: .cascade)
                t.column("score", .integer).notNull()
                t.column("reasons", .text)
                t.column("rulesVersion", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime)
                
                t.primaryKey(["messagePk"])
            }
            
            // MARK: - obligation
            
            try db.create(table: "obligation") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                
                t.column("messagePk", .integer).notNull()
                    .references("message", column: "pk", onDelete: .cascade)
                
                t.column("status", .text).notNull()
                t.column("category", .text).notNull()
                t.column("title", .text).notNull()
                t.column("deadlineAt", .datetime)
                t.column("risk", .text).notNull()
                t.column("whoOwes", .text).notNull().defaults(to: "unknown")
                t.column("confidence", .double).notNull().defaults(to: 0.0)
                
                t.column("evidenceQuote", .text).notNull()
                t.column("obligationKey", .text).notNull()
                t.column("snoozedUntil", .datetime)
                t.column("resolvedAt", .datetime)
                
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                
                t.uniqueKey(["mailboxAccountId", "obligationKey"])
            }
            
            // Obligation indexes
            try db.create(index: "obligation_mailbox_status", on: "obligation", columns: ["mailboxAccountId", "status"])
            try db.create(index: "obligation_mailbox_deadline", on: "obligation", columns: ["mailboxAccountId", "deadlineAt"])
            try db.create(index: "obligation_message", on: "obligation", columns: ["messagePk"])
            
            // MARK: - feedback
            
            try db.create(table: "feedback") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                
                t.column("messagePk", .integer)
                    .references("message", column: "pk", onDelete: .cascade)
                
                t.column("obligationId", .text)
                    .references("obligation", column: "id", onDelete: .cascade)
                
                t.column("action", .text).notNull()
                t.column("reason", .text)
                t.column("createdAt", .datetime).notNull()
            }
            
            // Feedback indexes
            try db.create(index: "feedback_mailbox_created", on: "feedback", columns: ["mailboxAccountId", "createdAt"])
            try db.create(index: "feedback_obligation", on: "feedback", columns: ["obligationId"])
            try db.create(index: "feedback_message", on: "feedback", columns: ["messagePk"])
            
            // MARK: - suppression
            
            try db.create(table: "suppression") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text)
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                
                t.column("type", .text).notNull()
                t.column("value", .text).notNull()
                t.column("isEnabled", .boolean).notNull().defaults(to: true)
                t.column("createdAt", .datetime).notNull()
                
                t.uniqueKey(["mailboxAccountId", "type", "value"])
            }
            
            // Suppression index
            try db.create(index: "suppression_mailbox_type", on: "suppression", columns: ["mailboxAccountId", "type"])
        }

        migrator.registerMigration("v2_obligation_scoring") { db in
            try db.alter(table: "obligation") { t in
                t.add(column: "score", .double).notNull().defaults(to: 0.0)
                t.add(column: "matchedRuleIds", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v3_obligation_signal_types") { db in
            try db.alter(table: "obligation") { t in
                t.add(column: "matchedSignalTypes", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v4_obligation_reasons") { db in
            try db.alter(table: "obligation") { t in
                t.add(column: "matchedReasons", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v5_message_body_and_attachments") { db in
            try db.alter(table: "message") { t in
                t.add(column: "bodyHtml", .text)
                t.add(column: "attachmentTypes", .text)
                t.add(column: "hasPdf", .boolean).notNull().defaults(to: false)
                t.add(column: "hasCalendar", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v6_rule_weight") { db in
            try db.create(table: "rule_weight") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                t.column("ruleId", .text).notNull()
                t.column("multiplier", .double).notNull().defaults(to: 1.0)
                t.column("truePos", .integer).notNull().defaults(to: 0)
                t.column("falsePos", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["mailboxAccountId", "ruleId"])
            }
        }

        migrator.registerMigration("v7_feedback_rule_ids") { db in
            try db.alter(table: "feedback") { t in
                t.add(column: "matchedRuleIds", .text)
            }
        }

        migrator.registerMigration("v8_candidate_score_rule_ids") { db in
            try db.alter(table: "candidate_score") { t in
                t.add(column: "matchedRuleIds", .text)
            }
        }
    }
}
