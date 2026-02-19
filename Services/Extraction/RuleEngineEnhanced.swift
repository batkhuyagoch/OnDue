import Foundation

// MARK: - Enhanced Signals for Rule Engine
// These can be added to your existing signals array in RuleEngine

extension RuleEngine {
    
    /// Additional high-value signals for Phase 1
    var enhancedSignals: [Signal] {
        [
            Signal(
                id: "past_due",
                weight: 3.5,
                reason: "Payment is past due",
                signalType: .keyword,
                category: .payment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "past due", "overdue", "payment overdue", "late payment",
                        "final notice", "account suspended", "service interruption"
                    ])
                }
            ),
            Signal(
                id: "autopay_failed",
                weight: 3.0,
                reason: "Automatic payment failed",
                signalType: .keyword,
                category: .payment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "autopay failed", "automatic payment failed", "payment declined",
                        "card declined", "insufficient funds", "payment method failed"
                    ])
                }
            ),
            Signal(
                id: "account_change_required",
                weight: 2.2,
                reason: "Account update requested",
                signalType: .keyword,
                category: .request,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "update your account", "confirm your account details",
                        "account information required", "profile update required"
                    ])
                }
            ),
            Signal(
                id: "delivery_action_required",
                weight: 2.0,
                reason: "Delivery requires an action",
                signalType: .keyword,
                category: .request,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "confirm delivery", "delivery attempt failed", "reschedule delivery",
                        "pick up your package", "delivery address issue"
                    ])
                }
            ),

            // MARK: Legal & Immigration (authoritative senders)
            Signal(
                id: "legal_sender_gov_allowlist",
                weight: 3.2,
                reason: "Government sender allowlist",
                signalType: .sender,
                category: .document,
                matches: { email in
                    guard let domain = email.senderDomain else { return false }
                    return isGovernmentAllowlisted(domain: domain, normalizedText: email.normalizedText)
                }
            ),
            Signal(
                id: "legal_sender_uscis",
                weight: 3.4,
                reason: "USCIS sender",
                signalType: .sender,
                category: .document,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("uscis.gov") ||
                        (domain.hasSuffix("govdelivery.com") && email.normalizedText.contains("uscis"))
                }
            ),
            Signal(
                id: "legal_sender_state",
                weight: 3.0,
                reason: "Department of State sender",
                signalType: .sender,
                category: .document,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("state.gov")
                }
            ),
            Signal(
                id: "legal_sender_ssa",
                weight: 2.8,
                reason: "Social Security sender",
                signalType: .sender,
                category: .document,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("ssa.gov")
                }
            ),
            Signal(
                id: "legal_sender_irs",
                weight: 3.0,
                reason: "IRS sender",
                signalType: .sender,
                category: .deadline,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("irs.gov")
                }
            ),
            Signal(
                id: "legal_sender_courts",
                weight: 3.2,
                reason: "Court sender",
                signalType: .sender,
                category: .deadline,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("uscourts.gov") || domain.hasSuffix("courts.gov")
                }
            ),
            
            // MARK: Insurance & Policies
            Signal(
                id: "insurance_renewal",
                weight: 2.8,
                reason: "Insurance policy renewal",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "policy renewal", "renew your policy", "renewal notice",
                        "policy expires", "coverage expires", "policy expiration"
                    ])
                }
            ),
            Signal(
                id: "coverage_lapsed",
                weight: 4.0,
                reason: "Insurance coverage lapsed",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "coverage lapsed", "policy canceled", "policy cancellation",
                        "coverage terminated", "policy void", "no longer covered"
                    ])
                }
            ),
            
            // MARK: Taxes & Legal
            Signal(
                id: "tax_notice",
                weight: 4.0,
                reason: "Tax authority notice",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    let hasIRS = email.normalizedText.contains("irs") ||
                                 email.normalizedText.contains("internal revenue") ||
                                 email.normalizedText.contains("franchise tax board")
                    let hasAction = containsAny(email.normalizedText, [
                        "notice", "required", "filing deadline", "due date", "tax return"
                    ])
                    return hasIRS && hasAction
                }
            ),
            Signal(
                id: "irs_notice",
                weight: 3.6,
                reason: "IRS notice or balance due",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "irs notice", "notice of deficiency", "cp2000", "balance due",
                        "tax owed", "payment due to the irs"
                    ])
                }
            ),
            Signal(
                id: "legal_notice",
                weight: 4.5,
                reason: "Legal notice or court document",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "court notice", "legal notice", "summons", "subpoena",
                        "hearing date", "appear in court", "legal deadline"
                    ])
                }
            ),
            Signal(
                id: "jury_duty",
                weight: 3.4,
                reason: "Jury duty notice",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "jury duty", "jury summons", "juror questionnaire", "report for jury service"
                    ])
                }
            ),
            Signal(
                id: "court_summons",
                weight: 3.8,
                reason: "Summons or subpoena",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["summons", "subpoena", "order to appear"])
                }
            ),

            // MARK: Immigration (USCIS milestones)
            Signal(
                id: "uscis_receipt_notice",
                weight: 3.0,
                reason: "USCIS receipt/notice of action",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "receipt notice", "notice of action", "i-797", "i-797c",
                        "case was received", "case status"
                    ])
                }
            ),
            Signal(
                id: "uscis_rfe",
                weight: 4.2,
                reason: "USCIS request for evidence",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "request for evidence", "rfe", "notice of intent to deny", "noid"
                    ])
                }
            ),
            Signal(
                id: "uscis_biometrics",
                weight: 3.6,
                reason: "USCIS biometrics appointment",
                signalType: .keyword,
                category: .appointment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "biometrics appointment", "biometric services appointment",
                        "asc appointment", "application support center"
                    ])
                }
            ),
            Signal(
                id: "uscis_interview",
                weight: 3.4,
                reason: "USCIS interview or oath ceremony",
                signalType: .keyword,
                category: .appointment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "interview scheduled", "interview notice", "oath ceremony",
                        "naturalization interview", "citizenship interview"
                    ])
                }
            ),
            Signal(
                id: "immigration_deadline",
                weight: 3.2,
                reason: "Immigration response deadline",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    let hasImmigration = containsAny(email.normalizedText, [
                        "uscis", "immigration", "i-485", "i-130", "i-765", "i-131", "n-400"
                    ])
                    let hasDeadline = containsAny(email.normalizedText, [
                        "respond by", "response due", "due by", "deadline", "submit by"
                    ])
                    return hasImmigration && hasDeadline
                }
            ),
            
            // MARK: Medical & Health
            Signal(
                id: "medical_appointment",
                weight: 2.2,
                reason: "Medical appointment",
                signalType: .keyword,
                category: .appointment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "appointment scheduled", "upcoming appointment",
                        "appointment confirmation", "appointment reminder",
                        "doctor appointment", "medical appointment"
                    ])
                }
            ),
            Signal(
                id: "prescription_refill",
                weight: 2.0,
                reason: "Prescription refill ready",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "prescription ready", "refill ready", "medication ready",
                        "prescription expiring", "refill needed"
                    ])
                }
            ),
            
            // MARK: Work & HR
            Signal(
                id: "benefits_enrollment",
                weight: 2.5,
                reason: "Benefits enrollment deadline",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "open enrollment", "benefits enrollment", "enroll by",
                        "benefits deadline", "election period"
                    ])
                }
            ),
            Signal(
                id: "compliance_training",
                weight: 1.8,
                reason: "Required training or compliance",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "training required", "complete training", "certification due",
                        "compliance deadline", "mandatory training"
                    ])
                }
            ),
            
            // MARK: Travel
            Signal(
                id: "flight_checkin",
                weight: 2.2,
                reason: "Flight check-in available",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "check-in now", "flight check-in", "mobile boarding pass",
                        "check in for your flight", "online check-in"
                    ])
                }
            ),
            Signal(
                id: "passport_visa",
                weight: 3.0,
                reason: "Passport or visa expiration",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "passport expires", "visa expires", "passport renewal",
                        "visa application", "travel document expires"
                    ])
                }
            ),
            Signal(
                id: "passport_renewal",
                weight: 3.0,
                reason: "Passport renewal notice",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "passport renewal", "renew your passport", "passport application"
                    ])
                }
            ),
            
            // MARK: Identity & Verification
            Signal(
                id: "identity_verification",
                weight: 3.5,
                reason: "Identity verification required",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "verify your identity", "identity verification required",
                        "confirm your identity", "security verification",
                        "account verification needed"
                    ])
                }
            ),
            Signal(
                id: "ssa_notice",
                weight: 3.0,
                reason: "Social Security notice",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "social security notice", "ssa notice", "benefits statement",
                        "overpayment notice", "benefit verification"
                    ])
                }
            ),
            Signal(
                id: "license_renewal",
                weight: 2.8,
                reason: "License or registration renewal",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "license expires", "renew your license", "license renewal",
                        "registration expires", "registration renewal"
                    ])
                }
            ),
            
            // MARK: Subscription Management
            Signal(
                id: "trial_ending",
                weight: 1.8,
                reason: "Trial period ending",
                signalType: .keyword,
                category: .payment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "trial ending", "trial expires", "free trial ends",
                        "trial period ending", "will be charged"
                    ])
                }
            ),
            
            // MARK: Document Expiration
            Signal(
                id: "document_expires_soon",
                weight: 2.5,
                reason: "Important document expiring",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "expires on", "expiration date", "document expires",
                        "valid until", "renew before", "certification expires"
                    ])
                }
            ),
            
            // MARK: Anti-Signals (reduce false positives)
            Signal(
                id: "marketing_language",
                weight: -1.5,
                reason: "Marketing/promotional content",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    let marketingCount = [
                        "limited time offer", "special promotion", "sale ends",
                        "don't miss out", "exclusive deal", "shop now",
                        "buy now", "save up to", "discount"
                    ].filter { email.normalizedText.contains($0) }.count
                    return marketingCount >= 2
                }
            ),
            Signal(
                id: "newsletter",
                weight: -1.0,
                reason: "Newsletter content",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "newsletter", "weekly digest", "monthly roundup",
                        "in this issue", "latest news", "this week in"
                    ])
                }
            ),
            Signal(
                id: "promotional_label",
                weight: -1.2,
                reason: "Gmail promotional category",
                signalType: .label,
                category: nil,
                matches: { email in
                    email.labelIds.contains("promotions") ||
                    email.labelIds.contains("category_promotions")
                }
            )
        ]
    }

    /// Year-scan legal/immigration signals (high precision)
    var legalYearScanSignals: [Signal] {
        [
            Signal(
                id: "legal_sender_gov_allowlist",
                weight: 2.8,
                reason: "Government sender allowlist",
                signalType: .sender,
                category: .document,
                matches: { email in
                    guard let domain = email.senderDomain else { return false }
                    return isGovernmentAllowlisted(domain: domain, normalizedText: email.normalizedText)
                }
            ),
            Signal(
                id: "legal_sender_uscis",
                weight: 3.0,
                reason: "USCIS sender",
                signalType: .sender,
                category: .document,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("uscis.gov") ||
                        (domain.hasSuffix("govdelivery.com") && email.normalizedText.contains("uscis"))
                }
            ),
            Signal(
                id: "legal_sender_state",
                weight: 2.6,
                reason: "Department of State sender",
                signalType: .sender,
                category: .document,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("state.gov")
                }
            ),
            Signal(
                id: "legal_sender_ssa",
                weight: 2.4,
                reason: "Social Security sender",
                signalType: .sender,
                category: .document,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("ssa.gov")
                }
            ),
            Signal(
                id: "legal_sender_irs",
                weight: 2.8,
                reason: "IRS sender",
                signalType: .sender,
                category: .deadline,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("irs.gov")
                }
            ),
            Signal(
                id: "legal_sender_courts",
                weight: 2.8,
                reason: "Court sender",
                signalType: .sender,
                category: .deadline,
                matches: { email in
                    let domain = email.senderDomain ?? ""
                    return domain.hasSuffix("uscourts.gov") || domain.hasSuffix("courts.gov")
                }
            ),
            Signal(
                id: "uscis_receipt_notice",
                weight: 3.2,
                reason: "USCIS receipt/notice of action",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "receipt notice", "notice of action", "i-797", "i-797c",
                        "case was received", "case status"
                    ])
                }
            ),
            Signal(
                id: "uscis_rfe",
                weight: 3.8,
                reason: "USCIS request for evidence",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "request for evidence", "rfe", "notice of intent to deny", "noid"
                    ])
                }
            ),
            Signal(
                id: "uscis_biometrics",
                weight: 3.4,
                reason: "USCIS biometrics appointment",
                signalType: .keyword,
                category: .appointment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "biometrics appointment", "biometric services appointment",
                        "asc appointment", "application support center"
                    ])
                }
            ),
            Signal(
                id: "uscis_interview",
                weight: 3.2,
                reason: "USCIS interview or oath ceremony",
                signalType: .keyword,
                category: .appointment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "interview scheduled", "interview notice", "oath ceremony",
                        "naturalization interview", "citizenship interview"
                    ])
                }
            ),
            Signal(
                id: "immigration_deadline",
                weight: 3.0,
                reason: "Immigration response deadline",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    let hasImmigration = containsAny(email.normalizedText, [
                        "uscis", "immigration", "i-485", "i-130", "i-765", "i-131", "n-400"
                    ])
                    let hasDeadline = containsAny(email.normalizedText, [
                        "respond by", "response due", "due by", "deadline", "submit by"
                    ])
                    return hasImmigration && hasDeadline
                }
            ),
            Signal(
                id: "irs_notice",
                weight: 3.0,
                reason: "IRS notice or balance due",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "irs notice", "notice of deficiency", "cp2000", "balance due",
                        "tax owed", "payment due to the irs"
                    ])
                }
            ),
            Signal(
                id: "jury_duty",
                weight: 3.0,
                reason: "Jury duty notice",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "jury duty", "jury summons", "juror questionnaire", "report for jury service"
                    ])
                }
            ),
            Signal(
                id: "court_summons",
                weight: 3.2,
                reason: "Summons or subpoena",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["summons", "subpoena", "order to appear"])
                }
            ),
            Signal(
                id: "passport_renewal",
                weight: 2.8,
                reason: "Passport renewal notice",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "passport renewal", "renew your passport", "passport application"
                    ])
                }
            ),
            Signal(
                id: "ssa_notice",
                weight: 2.8,
                reason: "Social Security notice",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "social security notice", "ssa notice", "benefits statement",
                        "overpayment notice", "benefit verification"
                    ])
                }
            ),
            Signal(
                id: "legal_notice",
                weight: 3.0,
                reason: "Legal notice or court document",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "court notice", "legal notice", "hearing date", "legal deadline"
                    ])
                }
            )
        ]
    }
}

// MARK: - Helper Functions

private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
    keywords.contains(where: { text.contains($0) })
}

private func isGovernmentAllowlisted(domain: String, normalizedText: String) -> Bool {
    let lowercased = domain.lowercased()
    if lowercased.hasSuffix(".gov") || lowercased.hasSuffix(".mil") {
        return true
    }
    if lowercased.hasSuffix("govdelivery.com") {
        return containsAny(normalizedText, [
            "uscis", "immigration", "department of state", "state department",
            "social security", "irs", "court", "hearing", "summons"
        ])
    }
    if lowercased.contains(".state.") && lowercased.hasSuffix(".us") {
        return true
    }
    return false
}
