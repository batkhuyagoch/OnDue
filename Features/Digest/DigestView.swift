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
        .alert("Error", isPresented: Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.clearError() } }
        )) {
            Button("OK") { viewModel.clearError() }
        } message: {
            Text(viewModel.error?.localizedDescription ?? "Something went wrong.")
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
                LearningToast(message: learning)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.horizontal)
                    .padding(.bottom, 52)
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
        ContentUnavailableView(
            "No action items yet",
            systemImage: "checkmark.circle",
            description: Text("Connect Gmail and sync to see important items.")
        )
    }
    
    private var digestList: some View {
        List {
            Section {
                lensRow
                groupingRow
            }
            if viewModel.isEmpty {
                Section {
                    emptyState
                }
            }
            ForEach(viewModel.sections) { section in
                Section(header: Text(section.title)) {
                    ForEach(section.items) { item in
                        NavigationLink {
                            ObligationDetailView(
                                obligation: item.obligation,
                                environment: environment.value,
                                onConfirm: { Task { await viewModel.confirm(item.obligation) } },
                                onDone: { Task { await viewModel.markDone(item.obligation) } },
                                onDismiss: { Task { await viewModel.dismiss(item.obligation) } },
                                onSnooze: { Task { await viewModel.snooze(item.obligation) } },
                                onBlockSender: { Task { await viewModel.blockSender(item.obligation) } },
                                onBlockDomain: { Task { await viewModel.blockDomain(item.obligation) } }
                            )
                        } label: {
                            DigestRowView(obligation: item.obligation, state: item.state)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                Task { await viewModel.markDone(item.obligation) }
                            } label: {
                                Label("Done", systemImage: "checkmark")
                            }
                            .tint(.green)
                            Button(role: .destructive) {
                                Task { await viewModel.dismiss(item.obligation) }
                            } label: {
                                Label("Dismiss", systemImage: "eye.slash")
                            }
                            Button(role: .destructive) {
                                Task { await viewModel.blockSender(item.obligation) }
                            } label: {
                                Label("Block Sender", systemImage: "hand.raised")
                            }
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

    private var groupingRow: some View {
        Picker("Group", selection: $viewModel.selectedGrouping) {
            ForEach(ObligationGrouping.allCases) { grouping in
                Text(grouping.title).tag(grouping)
            }
        }
        .pickerStyle(.menu)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleText
            deadlineText
            reasonChips
            evidenceText
        }
        .padding(.vertical, 4)
    }
    
    private var titleText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(obligation.title)
                .font(.subheadline.weight(.semibold))
            if state == .needsReview {
                Text("Needs Review")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.12))
                    )
            }
            if isToday {
                Text("Today")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.12))
                    )
            }
        }
    }
    
    @ViewBuilder
    private var deadlineText: some View {
        if let deadline = obligation.deadline {
            Text(deadlineLabel(for: deadline))
                .font(.subheadline)
                .foregroundStyle(deadlineColor(for: deadline))
        }
    }
    
    @ViewBuilder
    private var evidenceText: some View {
        if !obligation.evidenceQuote.isEmpty {
            Text("\"\(obligation.evidenceQuote)\"")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var reasonChips: some View {
        let chips = buildChips()
        if !chips.isEmpty {
            HStack(spacing: 6) {
                ForEach(chips, id: \.self) { chip in
                    Text(chip)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(chip == "Overdue" ? .red : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(chip == "Overdue" ? Color.clear : Color.secondary.opacity(0.12))
                                .overlay(
                                    Capsule()
                                        .stroke(chip == "Overdue" ? Color.red.opacity(0.4) : Color.clear, lineWidth: 1)
                                )
                        )
                }
            }
        }
    }

    private func buildChips() -> [String] {
        var chips: [String] = []

        if let deadline = obligation.deadline {
            if deadline < Calendar.current.startOfDay(for: Date()) {
                chips.append("Overdue")
            }
            chips.append("Due \(deadline.formatted(date: .abbreviated, time: .omitted))")
        }

        for reason in obligation.matchedReasons {
            let label = shortReasonLabel(for: reason)
            guard !chips.contains(label) else { continue }
            chips.append(label)
        }

        if chips.count > 4 {
            return Array(chips.prefix(4))
        }
        return chips
    }

    private func shortReasonLabel(for reason: String) -> String {
        let lowercased = reason.lowercased()
        if lowercased.contains("payment") || lowercased.contains("billing") || lowercased.contains("invoice") {
            return "Payment"
        }
        if lowercased.contains("document") || lowercased.contains("signature") || lowercased.contains("form") {
            return "Document"
        }
        if lowercased.contains("attachment") {
            return "Attachment"
        }
        if lowercased.contains("appointment") || lowercased.contains("meeting") || lowercased.contains("travel") {
            return "Appointment"
        }
        if lowercased.contains("request") || lowercased.contains("action") {
            return "Request"
        }
        if lowercased.contains("policy") || lowercased.contains("renewal") || lowercased.contains("insurance") {
            return "Policy"
        }
        if lowercased.contains("date") {
            return "Date"
        }
        return reason.count > 14 ? String(reason.prefix(14)) + "…" : reason
    }

    private func deadlineLabel(for deadline: Date) -> String {
        if Calendar.current.isDateInToday(deadline) {
            return "Today"
        }
        if deadline < Calendar.current.startOfDay(for: Date()) {
            return "Overdue • \(deadline.formatted(date: .abbreviated, time: .omitted))"
        }
        return deadline.formatted(date: .abbreviated, time: .shortened)
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

    private var isToday: Bool {
        guard let deadline = obligation.deadline else { return false }
        return Calendar.current.isDateInToday(deadline)
    }
}

private struct ObligationDetailView: View {
    let obligation: ObligationItem
    let environment: AppEnvironment
    let onConfirm: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void
    let onSnooze: () -> Void
    let onBlockSender: () -> Void
    let onBlockDomain: () -> Void
    @State private var message: MessageRecord?
    @State private var account: MailboxAccountRecord?
    @State private var showFullMessage = false
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

            if !obligation.matchedReasons.isEmpty {
                Section("Why we think this matters") {
                    ForEach(Array(obligation.matchedReasons.enumerated()), id: \.offset) { _, reason in
                        Text(shortReasonLabel(for: reason))
                    }
                }
            }

            if let messageBody = displayMessageText {
                Section("Email") {
                    Text(messageBody)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(showFullMessage ? nil : 8)
                        .textSelection(.enabled)
                    if fullMessageText != nil {
                        Button(showFullMessage ? "Show less" : "Show full message") {
                            showFullMessage.toggle()
                        }
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

            if let sender = message?.fromEmail {
                Section("Block") {
                    Button("Block sender (\(sender))") {
                        onBlockSender()
                    }
                    if let domain = message?.fromDomain, !domain.isEmpty {
                        Button("Block domain (\(domain))") {
                            onBlockDomain()
                        }
                    }
                }
            }
        }
        .navigationTitle("Obligation")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            actionBar
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
            Button("Confirm") { performAction(onConfirm) }
                .buttonStyle(.borderedProminent)
            Button("Done") { performAction(onDone) }
                .buttonStyle(.bordered)
            Button(role: .destructive) {
                performAction(onDismiss)
            } label: {
                Text("Dismiss")
            }
            .buttonStyle(.bordered)
            Button("Snooze") { performAction(onSnooze) }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func performAction(_ action: () -> Void) {
        action()
        dismiss()
    }

    private func shortReasonLabel(for reason: String) -> String {
        let lowercased = reason.lowercased()
        if lowercased.contains("payment") || lowercased.contains("billing") || lowercased.contains("invoice") {
            return "Payment"
        }
        if lowercased.contains("document") || lowercased.contains("signature") || lowercased.contains("form") {
            return "Document"
        }
        if lowercased.contains("attachment") {
            return "Attachment"
        }
        if lowercased.contains("appointment") || lowercased.contains("meeting") || lowercased.contains("travel") {
            return "Appointment"
        }
        if lowercased.contains("request") || lowercased.contains("action") {
            return "Request"
        }
        if lowercased.contains("policy") || lowercased.contains("renewal") || lowercased.contains("insurance") {
            return "Policy"
        }
        if lowercased.contains("date") {
            return "Date"
        }
        return reason
    }

    private var messageBodyText: String? {
        TextSanitizer.sanitizeMessage(
            bodyText: message?.bodyText,
            bodyHtml: message?.bodyHtml,
            snippet: message?.snippet
        )
    }

    private var fullMessageText: String? {
        TextSanitizer.sanitizeMessagePreservingNewlines(
            bodyText: message?.bodyText,
            bodyHtml: message?.bodyHtml,
            snippet: message?.snippet
        )
    }

    private var displayMessageText: String? {
        if showFullMessage {
            return fullMessageText ?? messageBodyText
        }
        return messageBodyText
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
