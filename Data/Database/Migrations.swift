import Foundation
import GRDB

enum Migrations {
    nonisolated static func register(_ migrator: inout DatabaseMigrator) {
        
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

        migrator.registerMigration("v9_year_scan_results") { db in
            try db.create(table: "year_scan_result") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                t.column("messagePk", .integer).notNull()
                    .references("message", column: "pk", onDelete: .cascade)
                t.column("providerMessageId", .text).notNull()
                t.column("threadId", .text)
                t.column("subject", .text).notNull()
                t.column("snippet", .text).notNull()
                t.column("score", .double).notNull()
                t.column("matchedReasons", .text).notNull()
                t.column("detectedAt", .datetime).notNull()
            }

            try db.create(table: "year_scan_state") { t in
                t.column("id", .text).primaryKey()
                t.column("lastChecked", .datetime)
                t.column("scannedMessageCount", .integer).notNull().defaults(to: 0)
                t.column("coverageSummary", .text).notNull().defaults(to: "")
            }
        }

        migrator.registerMigration("v10_year_scan_state_progress") { db in
            try db.alter(table: "year_scan_state") { t in
                t.add(column: "isInProgress", .boolean).notNull().defaults(to: false)
                t.add(column: "statusMessage", .text)
                t.add(column: "updatedAt", .datetime)
            }
        }

        migrator.registerMigration("v11_obligation_repeat_tracking") { db in
            try db.alter(table: "obligation") { t in
                t.add(column: "repeatCount", .integer).notNull().defaults(to: 1)
                t.add(column: "lastSeenAt", .datetime)
            }
        }

        migrator.registerMigration("v12_obligation_projection") { db in
            try db.create(table: "obligation_projection") { t in
                t.column("obligationId", .text).primaryKey()
                t.column("state", .text).notNull()
                t.column("confidence", .double).notNull()
                t.column("dueDate", .datetime)
                t.column("dueBucket", .text).notNull()
                t.column("primaryThreadId", .text)
                t.column("lastActionAt", .datetime)
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(index: "obligation_projection_state", on: "obligation_projection", columns: ["state"])
            try db.create(index: "obligation_projection_dueDate", on: "obligation_projection", columns: ["dueDate"])
            try db.create(index: "obligation_projection_thread", on: "obligation_projection", columns: ["primaryThreadId"])

            try db.execute(sql: """
                INSERT INTO obligation_projection (
                    obligationId,
                    state,
                    confidence,
                    dueDate,
                    dueBucket,
                    primaryThreadId,
                    lastActionAt,
                    updatedAt
                )
                SELECT
                    o.id,
                    CASE
                        WHEN o.status = 'dismissed' THEN 'suppressed'
                        WHEN o.status = 'done' THEN 'resolved'
                        WHEN o.status = 'snoozed' THEN 'snoozed'
                        WHEN o.status = 'open' AND o.deadlineAt IS NOT NULL AND o.deadlineAt < datetime('now') THEN 'overdue'
                        WHEN o.status = 'open' AND o.confidence < 0.6 THEN 'needsReview'
                        ELSE 'active'
                    END AS state,
                    o.confidence,
                    o.deadlineAt,
                    CASE
                        WHEN o.deadlineAt IS NULL THEN 'noDueDate'
                        WHEN o.deadlineAt < datetime('now') THEN 'overdue'
                        WHEN date(o.deadlineAt) = date('now') THEN 'today'
                        WHEN o.deadlineAt <= datetime('now', '+3 days') THEN 'next3Days'
                        WHEN o.deadlineAt <= datetime('now', '+7 days') THEN 'next7Days'
                        ELSE 'later'
                    END AS dueBucket,
                    COALESCE(m.threadId, m.providerMessageId) AS primaryThreadId,
                    o.updatedAt,
                    o.updatedAt
                FROM obligation o
                JOIN message m ON m.pk = o.messagePk;
            """)
        }

        migrator.registerMigration("v13_candidate_score_double") { db in
            try db.execute(sql: """
                CREATE TABLE candidate_score_new (
                    messagePk INTEGER NOT NULL PRIMARY KEY REFERENCES message(pk) ON DELETE CASCADE,
                    score DOUBLE NOT NULL,
                    reasons TEXT,
                    rulesVersion INTEGER NOT NULL DEFAULT 1,
                    createdAt DATETIME NOT NULL,
                    updatedAt DATETIME,
                    matchedRuleIds TEXT
                );
            """)

            try db.execute(sql: """
                INSERT INTO candidate_score_new (
                    messagePk,
                    score,
                    reasons,
                    rulesVersion,
                    createdAt,
                    updatedAt,
                    matchedRuleIds
                )
                SELECT
                    messagePk,
                    CAST(score AS DOUBLE),
                    reasons,
                    rulesVersion,
                    createdAt,
                    updatedAt,
                    matchedRuleIds
                FROM candidate_score;
            """)

            try db.execute(sql: "DROP TABLE candidate_score;")
            try db.execute(sql: "ALTER TABLE candidate_score_new RENAME TO candidate_score;")
        }

        migrator.registerMigration("v14_obligation_projection_fk") { db in
            try db.execute(sql: """
                CREATE TABLE obligation_projection_new (
                    obligationId TEXT NOT NULL PRIMARY KEY REFERENCES obligation(id) ON DELETE CASCADE,
                    state TEXT NOT NULL,
                    confidence DOUBLE NOT NULL,
                    dueDate DATETIME,
                    dueBucket TEXT NOT NULL,
                    primaryThreadId TEXT,
                    lastActionAt DATETIME,
                    updatedAt DATETIME NOT NULL
                );
            """)

            try db.execute(sql: """
                INSERT INTO obligation_projection_new (
                    obligationId,
                    state,
                    confidence,
                    dueDate,
                    dueBucket,
                    primaryThreadId,
                    lastActionAt,
                    updatedAt
                )
                SELECT
                    p.obligationId,
                    p.state,
                    p.confidence,
                    p.dueDate,
                    p.dueBucket,
                    p.primaryThreadId,
                    p.lastActionAt,
                    p.updatedAt
                FROM obligation_projection p
                JOIN obligation o ON o.id = p.obligationId;
            """)

            try db.execute(sql: "DROP TABLE obligation_projection;")
            try db.execute(sql: "ALTER TABLE obligation_projection_new RENAME TO obligation_projection;")

            try db.create(index: "obligation_projection_state", on: "obligation_projection", columns: ["state"])
            try db.create(index: "obligation_projection_dueDate", on: "obligation_projection", columns: ["dueDate"])
            try db.create(index: "obligation_projection_thread", on: "obligation_projection", columns: ["primaryThreadId"])
        }

        migrator.registerMigration("v15_feedback_hypothesis_context") { db in
            try db.alter(table: "feedback") { t in
                t.add(column: "primaryHypothesisId", .text)
                t.add(column: "senderDomainClass", .text)
                t.add(column: "labelCluster", .text)
                t.add(column: "threadPattern", .text)
            }
            try db.create(index: "feedback_hypothesis", on: "feedback", columns: ["mailboxAccountId", "primaryHypothesisId"])
        }

        migrator.registerMigration("v16_hypothesis_review_calibration") { db in
            try db.create(table: "hypothesis_review_calibration") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                t.column("hypothesisId", .text).notNull()
                t.column("senderDomainClass", .text).notNull().defaults(to: "all")
                t.column("labelCluster", .text).notNull().defaults(to: "all")
                t.column("threadPattern", .text).notNull().defaults(to: "all")
                t.column("acceptedCount", .integer).notNull().defaults(to: 0)
                t.column("dismissedCount", .integer).notNull().defaults(to: 0)
                t.column("snoozedCount", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["mailboxAccountId", "hypothesisId", "senderDomainClass", "labelCluster", "threadPattern"])
            }
            try db.create(
                index: "hypothesis_review_lookup",
                on: "hypothesis_review_calibration",
                columns: ["mailboxAccountId", "hypothesisId", "senderDomainClass", "labelCluster", "threadPattern"]
            )
        }

        migrator.registerMigration("v17_hypothesis_metric_counter") { db in
            try db.create(table: "hypothesis_metric_counter") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                t.column("profile", .text).notNull()
                t.column("hypothesisId", .text).notNull()
                t.column("counter", .text).notNull()
                t.column("count", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .datetime).notNull()
                t.uniqueKey(["mailboxAccountId", "profile", "hypothesisId", "counter"])
            }
            try db.create(
                index: "hypothesis_metric_counter_lookup",
                on: "hypothesis_metric_counter",
                columns: ["mailboxAccountId", "profile", "hypothesisId", "counter"]
            )
        }

        migrator.registerMigration("v18_decision_contract_columns") { db in
            try db.alter(table: "obligation") { t in
                t.add(column: "primaryHypothesisId", .text)
                t.add(column: "reasonCode", .text)
                t.add(column: "policyVersion", .text)
            }
            try db.alter(table: "obligation_projection") { t in
                t.add(column: "reasonCode", .text)
                t.add(column: "policyVersion", .text)
            }
            try db.create(index: "obligation_reason_code", on: "obligation", columns: ["reasonCode"])
            try db.create(index: "obligation_policy_version", on: "obligation", columns: ["policyVersion"])
        }

        migrator.registerMigration("v19_exposure_and_feedback_timestamps") { db in
            try db.create(table: "user_exposure_event") { t in
                t.column("id", .text).primaryKey()
                t.column("mailboxAccountId", .text).notNull()
                    .references("mailbox_account", column: "id", onDelete: .cascade)
                t.column("obligationId", .text).notNull()
                    .references("obligation", column: "id", onDelete: .cascade)
                t.column("digestRenderId", .text).notNull()
                t.column("hypothesisClass", .text).notNull()
                t.column("projectionState", .text).notNull()
                t.column("digestPosition", .integer).notNull().defaults(to: 0)
                t.column("exposedAt", .datetime).notNull()
                t.column("policyVersion", .text).notNull()
                t.uniqueKey(["mailboxAccountId", "obligationId", "digestRenderId"])
            }
            try db.create(
                index: "user_exposure_mailbox_obligation",
                on: "user_exposure_event",
                columns: ["mailboxAccountId", "obligationId", "exposedAt"]
            )
            try db.create(
                index: "user_exposure_hypothesis",
                on: "user_exposure_event",
                columns: ["mailboxAccountId", "hypothesisClass", "exposedAt"]
            )

            try db.alter(table: "feedback") { t in
                t.add(column: "exposureTimestamp", .datetime)
                t.add(column: "actionTimestamp", .datetime)
            }
        }

        migrator.registerMigration("v20_counter_integrity_and_diff_artifact") { db in
            try db.execute(sql: """
                CREATE TABLE policy_diff_artifact (
                    id TEXT NOT NULL PRIMARY KEY,
                    datasetId TEXT NOT NULL,
                    baselineVersion TEXT NOT NULL,
                    candidateVersion TEXT NOT NULL,
                    decisionDeltaPercent DOUBLE NOT NULL,
                    generatedAt DATETIME NOT NULL
                );
            """)
            try db.create(
                index: "policy_diff_artifact_versions",
                on: "policy_diff_artifact",
                columns: ["baselineVersion", "candidateVersion", "generatedAt"]
            )
        }

        migrator.registerMigration("v21_backfill_canonical_decision_fields") { db in
            try db.execute(sql: """
                UPDATE obligation
                SET primaryHypothesisId = COALESCE(NULLIF(primaryHypothesisId, ''), 'userActionRequired')
            """)
            try db.execute(sql: """
                UPDATE obligation
                SET reasonCode = COALESCE(NULLIF(reasonCode, ''), 'other')
            """)
            try db.execute(sql: """
                UPDATE obligation
                SET policyVersion = COALESCE(NULLIF(policyVersion, ''), 'v2_policy_driven')
            """)

            try db.execute(sql: """
                UPDATE obligation_projection
                SET reasonCode = COALESCE(NULLIF(reasonCode, ''), 'other')
            """)
            try db.execute(sql: """
                UPDATE obligation_projection
                SET policyVersion = COALESCE(NULLIF(policyVersion, ''), 'v2_policy_driven')
            """)
        }

        migrator.registerMigration("v22_year_scan_resume_state") { db in
            try db.alter(table: "year_scan_state") { t in
                t.add(column: "lastPaused", .datetime)
                t.add(column: "resumeStateJSON", .text)
            }
        }
        
        // MARK: - v23: Local message state management
        
        migrator.registerMigration("v23_user_actions") { db in
            try db.create(table: "user_actions") { t in
                t.column("id", .text).primaryKey()
                t.column("messageID", .text).notNull().indexed()
                t.column("actionType", .text).notNull()
                t.column("actionData", .text)
                t.column("timestamp", .date).notNull().indexed()
                t.column("synced", .boolean).notNull().defaults(to: false)
            }
            
            // Create indexes for common queries
            try db.create(index: "idx_user_actions_messageID_timestamp", 
                         on: "user_actions", 
                         columns: ["messageID", "timestamp"])
            try db.create(index: "idx_user_actions_actionType", 
                         on: "user_actions", 
                         columns: ["actionType"])
            try db.create(index: "idx_user_actions_synced", 
                         on: "user_actions", 
                         columns: ["synced"])
        }

        migrator.registerMigration("v24_year_scan_configuration") { db in
            try db.alter(table: "year_scan_state") { t in
                t.add(column: "scanRangeMonths", .integer).notNull().defaults(to: 12)
                t.add(column: "scanIntensity", .text).notNull().defaults(to: "balanced")
            }
        }

        migrator.registerMigration("v25_long_scan_output_contract") { db in
            let existingColumns = try db.columns(in: "year_scan_result").map(\.name)
            var addedConfidenceColumn = false

            if !existingColumns.contains("source") {
                try db.alter(table: "year_scan_result") { t in
                    t.add(column: "source", .text).notNull().defaults(to: LongScanSource.scan.rawValue)
                }
            }
            if !existingColumns.contains("promotionDecision") {
                try db.alter(table: "year_scan_result") { t in
                    t.add(column: "promotionDecision", .text).notNull().defaults(to: LongScanPromotionDecision.promoted.rawValue)
                }
            }
            if !existingColumns.contains("promotionReasonCode") {
                try db.alter(table: "year_scan_result") { t in
                    t.add(column: "promotionReasonCode", .text).notNull().defaults(to: LongScanPromotionReasonCode.promotedActionable.rawValue)
                }
            }
            if !existingColumns.contains("confidence") {
                try db.alter(table: "year_scan_result") { t in
                    t.add(column: "confidence", .double).notNull().defaults(to: 0.8)
                }
                addedConfidenceColumn = true
            }
            if !existingColumns.contains("dueDate") {
                try db.alter(table: "year_scan_result") { t in
                    t.add(column: "dueDate", .datetime)
                }
            }

            if addedConfidenceColumn {
                try db.execute(sql: """
                    UPDATE year_scan_result
                    SET confidence = min(1.0, max(0.0, score / 2.0));
                """)
            }
            try db.create(index: "year_scan_result_promotion_decision", on: "year_scan_result", columns: ["promotionDecision"])
        }

        migrator.registerMigration("v26_deadline_source") { db in
            let obligationColumns = try db.columns(in: "obligation").map(\.name)
            if !obligationColumns.contains("deadlineSource") {
                try db.alter(table: "obligation") { t in
                    t.add(column: "deadlineSource", .text)
                }
            }
        }

        migrator.registerMigration("v27_contract_confidence") { db in
            let obligationColumns = try db.columns(in: "obligation").map(\.name)
            if !obligationColumns.contains("contractConfidence") {
                try db.alter(table: "obligation") { t in
                    t.add(column: "contractConfidence", .text)
                }
            }
        }

        migrator.registerMigration("v28_surfacing_intent") { db in
            let projectionColumns = try db.columns(in: "obligation_projection").map(\.name)
            if !projectionColumns.contains("surfacingIntent") {
                try db.alter(table: "obligation_projection") { t in
                    t.add(column: "surfacingIntent", .text)
                }
            }
        }
    }
}
