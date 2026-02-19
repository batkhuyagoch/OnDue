import SwiftUI
import Combine

struct DigestView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = DigestViewModel()

    var body: some View {
        content
            .navigationTitle("Obligations")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CoverageStatusView()
                    } label: {
                        Label("Coverage", systemImage: "checkmark.seal")
                    }
                }
            }
        .task {
            await viewModel.loadDigest(using: environment.value)
        }
        .onReceive(environment.value.filterPreferencesStore.objectWillChange) { _ in
            Task { await viewModel.loadDigest(using: environment.value) }
        }
        .searchable(text: $viewModel.searchQuery, placement: .navigationBarDrawer(displayMode: .automatic))
        .onChange(of: viewModel.searchQuery) { _, newValue in
            viewModel.updateSearchQuery(newValue)
        }
        .onChange(of: viewModel.selectedLens) { _, _ in
            Task { await viewModel.loadDigest(using: environment.value) }
        }
        .onChange(of: viewModel.selectedGrouping) { _, _ in
            Task { await viewModel.loadDigest(using: environment.value) }
        }
        .onChange(of: viewModel.showOverdueItems) { _, _ in
            Task { await viewModel.loadDigest(using: environment.value) }
        }
        .alert("Couldn't load obligations", isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("Try again") {
                viewModel.clearError()
                Task { await viewModel.loadDigest(using: environment.value) }
            }
            Button("Dismiss", role: .cancel) { viewModel.clearError() }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "Tap Try again to reload your obligations.")
        }
        .overlay(alignment: .bottom) {
            if let banner = viewModel.undoBanner {
                UndoToast(
                    message: banner.message,
                    onUndo: { Task { await viewModel.undoLastAction() } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            if let learning = viewModel.learningBanner {
                if viewModel.undoBanner == nil {
                    LearningToast(message: learning)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.horizontal)
                        .padding(.bottom, 12)
                }
            }
        }
        .animation(.easeInOut, value: viewModel.undoBanner?.id)
        .animation(.easeInOut, value: viewModel.learningBanner)
    }
    
    // MARK: - Content
    
    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            digestList
        }
    }
    
    private var emptyState: some View {
        ContentUnavailableView {
            Label("No action items yet", systemImage: "checkmark.circle")
        } description: {
            Text("Connect Gmail, then sync your inbox to discover obligations.")
        } actions: {
            NavigationLink {
                ConnectGmailView()
            } label: {
                Label("Connect Gmail", systemImage: "link")
            }
            .buttonStyle(.borderedProminent)
        }
    }
    
    private var digestList: some View {
        List {
            Section {
                lensRow
                groupingMenu
            }
            if viewModel.isEmpty {
                Section {
                    emptyState
                }
            }
            ForEach(viewModel.sections) { section in
                Section(header: Text(section.title)) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        NavigationLink {
                            ObligationDetailView(
                                obligation: item.obligation,
                                state: item.state,
                                environment: environment.value,
                                onConfirm: { Task { await viewModel.confirm(item.obligation) } },
                                onDone: { Task { await viewModel.markDone(item.obligation) } },
                                onDismiss: { Task { await viewModel.dismiss(item.obligation) } },
                                onSnooze: { Task { await viewModel.snooze(item.obligation) } },
                                onBlockSender: { sender in
                                    Task { await viewModel.blockSender(item.obligation, senderOverride: sender) }
                                },
                                onBlockDomain: { domain in
                                    Task { await viewModel.blockDomain(item.obligation, domainOverride: domain) }
                                }
                            )
                        } label: {
                            DigestRowView(
                                obligation: item.obligation,
                                state: item.state,
                                debugFilterNote: DigestViewModel.digestFilterExplain(
                                    item.obligation,
                                    preferences: environment.value.filterPreferencesStore
                                )
                            )
                        }
                        .onAppear {
                            Task {
                                await viewModel.logExposure(
                                    obligation: item.obligation,
                                    state: item.state,
                                    position: index
                                )
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                Task { await viewModel.markDone(item.obligation) }
                            } label: {
                                Label("Mark done", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task { await viewModel.confirm(item.obligation) }
                            } label: {
                                Label("Confirm", systemImage: "checkmark.seal")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var lensRow: some View {
        Picker("Lens", selection: $viewModel.selectedLens) {
            ForEach(ObligationLens.allCases) { lens in
                Text(lens.title).tag(lens)
            }
        }
        .pickerStyle(.segmented)
    }

    private var groupingMenu: some View {
        Menu {
            if viewModel.selectedLens == .active {
                Toggle(isOn: $viewModel.showOverdueItems) {
                    Label("Show overdue items", systemImage: viewModel.showOverdueItems ? "eye" : "eye.slash")
                }
            }
            ForEach(ObligationGrouping.allCases) { grouping in
                Button {
                    viewModel.selectedGrouping = grouping
                } label: {
                    if grouping == viewModel.selectedGrouping {
                        Label(grouping.title, systemImage: "checkmark")
                    } else {
                        Text(grouping.title)
                    }
                }
            }
        } label: {
            Label("Group by \(viewModel.selectedGrouping.title)", systemImage: "rectangle.3.group")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UndoToast: View {
    let message: String
    let onUndo: () -> Void

    var body: some View {
        HStack {
            Text(message)
                .font(.subheadline)
            Spacer()
            Button("Undo") { onUndo() }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct LearningToast: View {
    let message: String

    var body: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Row View

private struct DigestRowView: View {
    let obligation: ObligationItem
    let state: ObligationLifecycleState
    let debugFilterNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(obligation.title)
                    .font(.subheadline.weight(.semibold))
                if let statusChipText = primaryStatusChip {
                    statusChip(statusChipText)
                }
            }
            if let deadline = obligation.deadline {
                Text(deadlineLabel(for: deadline))
                    .font(.caption)
                    .foregroundStyle(deadlineColor(for: deadline))
            }
            if let supportingText = supportingLineText {
                Text(supportingText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
#if DEBUG
            if let debugFilterNote, !debugFilterNote.isEmpty {
                Text(debugFilterNote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
#endif
        }
        .padding(.vertical, 4)
    }

    private func statusChip(_ chip: String) -> some View {
        let isOverdue = chip == "Overdue"
        let isStatus = chip == "Needs Review" || chip == "Due today"
        return Text(chip)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isOverdue ? .red : (isStatus ? .orange : .secondary))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isOverdue ? Color.clear : (isStatus ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.12)))
                    .overlay(
                        Capsule()
                            .stroke(isOverdue ? Color.red.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
    }

    private var primaryStatusChip: String? {
        if state == .needsReview { return "Needs Review" }
        if let deadline = obligation.deadline {
            if deadline < Calendar.current.startOfDay(for: Date()) { return "Overdue" }
            if Calendar.current.isDateInToday(deadline) { return "Due today" }
        }
        if obligation.reasonCode != .other {
            return ReasonCatalog.shortChipText(for: obligation.reasonCode)
        }
        return nil
    }

    private var supportingLineText: String? {
        if !obligation.evidenceQuote.isEmpty {
            return "\"\(obligation.evidenceQuote)\""
        }
        guard let firstReason = obligation.matchedReasons.first else { return nil }
        return DigestReasonLabeler.shortReasonLabel(for: firstReason)
    }

    private func deadlineLabel(for deadline: Date) -> String {
        if Calendar.current.isDateInToday(deadline) {
            return "Due today"
        }
        if deadline < Calendar.current.startOfDay(for: Date()) {
            return "Overdue • \(deadline.formatted(date: .abbreviated, time: .omitted))"
        }
        return "Due \(deadline.formatted(date: .abbreviated, time: .shortened))"
    }

    private func deadlineColor(for deadline: Date) -> Color {
        if Calendar.current.isDateInToday(deadline) {
            return .orange
        }
        if deadline < Calendar.current.startOfDay(for: Date()) {
            return .red
        }
        return .secondary
    }

}

private struct ObligationDetailView: View {
    let obligation: ObligationItem
    let state: ObligationLifecycleState
    let environment: AppEnvironment
    let onConfirm: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void
    let onSnooze: () -> Void
    let onBlockSender: (String) -> Void
    let onBlockDomain: (String) -> Void
    @State private var message: MessageRecord?
    @State private var account: MailboxAccountRecord?
    @State private var showFullMessage = false
    @State private var showDismissConfirmation = false
    @State private var showBlockSenderConfirmation = false
    @State private var showBlockDomainConfirmation = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(obligation.title)
                    .font(.title3.weight(.semibold))
            }

            Section("Details") {
                if let deadline = obligation.deadline {
                    LabeledContent("Due", value: deadline.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Category", value: obligation.category.rawValue.capitalized)
                LabeledContent("Confidence", value: "\(Int(obligation.confidence * 100))%")
                if obligation.repeatCount > 1 {
                    LabeledContent("Seen", value: "\(obligation.repeatCount) times")
                }
                if let lastSeenAt = obligation.lastSeenAt {
                    LabeledContent("Last seen", value: lastSeenAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

#if DEBUG
            Section("Filter diagnostics") {
                Text(
                    DigestViewModel.digestFilterExplain(
                        obligation,
                        preferences: environment.filterPreferencesStore
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
#endif

            if !obligation.matchedReasons.isEmpty {
                Section("Why this matters") {
                    if obligation.reasonCode != .other {
                        Text(ReasonCatalog.displayText(for: obligation.reasonCode))
                    }
                    ForEach(Array(obligation.matchedReasons.enumerated()), id: \.offset) { _, reason in
                        let label = DigestReasonLabeler.shortReasonLabel(for: reason)
                        if obligation.reasonCode == .other || label != ReasonCatalog.shortChipText(for: obligation.reasonCode) {
                            Text(label)
                        }
                    }
                }
            }

            if let detailText = detailMessageText {
                Section("Email") {
                    Text(showFullMessage ? detailText.full : detailText.preview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(showFullMessage ? nil : 8)
                        .fixedSize(horizontal: false, vertical: showFullMessage)
                        .textSelection(.enabled)
                    if canExpandMessage(preview: detailText.preview, expanded: detailText.full) {
                        Button(showFullMessage ? "Show less" : "Show full message") {
                            showFullMessage.toggle()
                        }
                    }
                    if detailText.isTruncated {
                        Text("Message content truncated for performance. Open in provider for full content.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if !obligation.evidenceQuote.isEmpty {
                Section("Evidence") {
                    Text(obligation.evidenceQuote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let providerURL = providerMessageURL {
                Section {
                    Button(openLabel) {
                        openURL(providerURL)
                    }
                }
            }
        }
        .navigationTitle("Obligation")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .confirmationDialog("Dismiss item?", isPresented: $showDismissConfirmation, titleVisibility: .visible) {
            Button("Mark as not an obligation", role: .destructive) {
                performAction(onDismiss)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll remove this from your active obligations and treat it as a false positive.")
        }
        .confirmationDialog("Block sender?", isPresented: $showBlockSenderConfirmation, titleVisibility: .visible) {
            if let sender = message?.fromEmail {
                Button("Block \(sender)", role: .destructive) {
                    performAction { onBlockSender(sender) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All future messages from this sender will be suppressed.")
        }
        .confirmationDialog("Block domain?", isPresented: $showBlockDomainConfirmation, titleVisibility: .visible) {
            if let domain = message?.fromDomain, !domain.isEmpty {
                Button("Block \(domain)", role: .destructive) {
                    performAction { onBlockDomain(domain) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All future messages from this domain will be suppressed.")
        }
        .task {
            message = try? await environment.messageRepository.fetchByPk(obligation.messagePk)
            if let mailboxId = message?.mailboxAccountId {
                account = try? await environment.mailboxAccountRepository.fetch(byId: mailboxId)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(primaryCTALabel) {
                performAction(primaryCTAAction)
            }
            .buttonStyle(.borderedProminent)
            Button("Snooze") { performAction(onSnooze) }
                .buttonStyle(.bordered)
            Menu {
                Button(role: .destructive) {
                    showDismissConfirmation = true
                } label: {
                    Label("Not an obligation", systemImage: "eye.slash")
                }
                if let sender = message?.fromEmail {
                    Button(role: .destructive) {
                        showBlockSenderConfirmation = true
                    } label: {
                        Label("Block sender (\(sender))", systemImage: "hand.raised")
                    }
                }
                if let domain = message?.fromDomain, !domain.isEmpty {
                    Button(role: .destructive) {
                        showBlockDomainConfirmation = true
                    } label: {
                        Label("Block domain (\(domain))", systemImage: "network")
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var primaryCTALabel: String {
        state == .needsReview ? "Confirm" : "Mark done"
    }

    private var primaryCTAAction: () -> Void {
        state == .needsReview ? onConfirm : onDone
    }

    private func performAction(_ action: () -> Void) {
        action()
        dismiss()
    }

    private var detailMessageText: TextSanitizer.DetailText? {
        TextSanitizer.sanitizeDetailMessage(
            bodyText: message?.bodyText,
            bodyHtml: message?.bodyHtml,
            snippet: message?.snippet
        )
    }

    private func canExpandMessage(preview: String, expanded: String) -> Bool {
        let normalizedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpanded = expanded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPreview.isEmpty, !normalizedExpanded.isEmpty else { return false }
        if normalizedExpanded != normalizedPreview {
            return true
        }
        return normalizedExpanded.contains("\n")
    }

    private var providerMessageURL: URL? {
        guard let message else { return nil }
        if account?.provider == .gmail {
            if let threadId = message.threadId {
                return URL(string: "https://mail.google.com/mail/u/0/#inbox/\(threadId)")
            }
            return URL(string: "https://mail.google.com/mail/u/0/#inbox/\(message.providerMessageId)")
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = message.fromEmail
        components.queryItems = [
            URLQueryItem(name: "subject", value: message.subject)
        ]
        return components.url
    }

    private var openLabel: String {
        if account?.provider == .gmail {
            return "Open in Gmail"
        }
        return "Open in Mail"
    }
}

private enum DigestReasonLabeler {
    static func shortReasonLabel(for reason: String) -> String {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()

        // First prefer canonical reason text mappings.
        let explicitCode = ReasonCatalog.code(from: normalized)
        if explicitCode != .other {
            return ReasonCatalog.shortChipText(for: explicitCode)
        }
        if lowercased.contains("delivery") || lowercased.contains("package") || lowercased.contains("shipment") {
            return "Delivery"
        }
        if lowercased.contains("appointment") || lowercased.contains("meeting") || lowercased.contains("travel") {
            return "Appointment"
        }
        if lowercased.contains("verify") || lowercased.contains("identity") || lowercased.contains("account") {
            return "Verify"
        }
        if lowercased.contains("legal") || lowercased.contains("compliance") || lowercased.contains("court") || lowercased.contains("irs") {
            return "Legal"
        }
        if lowercased.contains("waiting") || lowercased.contains("awaiting") {
            return "Follow-up"
        }
        if lowercased.contains("request") || lowercased.contains("action") {
            return "Request"
        }
        if lowercased.contains("deadline") || lowercased.contains("due") {
            return "Deadline"
        }
        if lowercased.contains("payment") || lowercased.contains("billing") || lowercased.contains("invoice") {
            return "Payment"
        }
        if lowercased.contains("document") || lowercased.contains("signature") || lowercased.contains("form") {
            return "Document"
        }
        if lowercased.contains("security") || lowercased.contains("sign-in") {
            return "Security"
        }
        if lowercased.contains("receipt") || lowercased.contains("confirmation") {
            return "Receipt"
        }
        if lowercased.contains("promo") || lowercased.contains("marketing") || lowercased.contains("newsletter") {
            return "Marketing"
        }
        return normalized.count > 14 ? String(normalized.prefix(14)) + "…" : normalized
    }
}
