import SwiftUI
import Combine

struct DigestView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = DigestViewModel()
    @State private var showingFilters = false
    @State private var isOverdueExpanded = false
    @State private var searchText = ""

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Important")
        }
        .task {
            await viewModel.loadDigest(using: environment.value)
        }
        .onReceive(environment.value.filterPreferencesStore.objectWillChange) { _ in
            Task { await viewModel.loadDigest(using: environment.value) }
        }
        .sheet(isPresented: $showingFilters) {
            FilterPreferencesSheet(preferences: environment.value.filterPreferencesStore)
        }
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic))
        .onChange(of: searchText) { newValue in
            viewModel.updateSearchQuery(newValue)
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
        } else if viewModel.isEmpty {
            emptyState
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
                filterRow
            }
            if !viewModel.borderlineItems.isEmpty {
                Section("Review") {
                    ForEach(viewModel.borderlineItems) { item in
                        BorderlineRowView(
                            item: item,
                            onPromote: { Task { await viewModel.promote(item) } },
                            onDismiss: { Task { await viewModel.dismissBorderline(item) } }
                        )
                    }
                    if viewModel.hasMoreBorderline {
                        HStack {
                            Spacer()
                            Button {
                                Task { await viewModel.loadMoreBorderline() }
                            } label: {
                                if viewModel.isLoadingMoreBorderline {
                                    ProgressView()
                                } else {
                                    Text("Load more")
                                }
                            }
                            Spacer()
                        }
                    }
                }
            }
            ForEach(viewModel.sections) { section in
                if section.kind == .overdue {
                    Section {
                        DisclosureGroup(isExpanded: $isOverdueExpanded) {
                            ForEach(section.items) { item in
                                NavigationLink {
                                    ObligationDetailView(
                                        obligation: item,
                                        environment: environment.value,
                                        onConfirm: { Task { await viewModel.confirm(item) } },
                                        onDone: { Task { await viewModel.markDone(item) } },
                                        onDismiss: { Task { await viewModel.dismiss(item) } },
                                        onSnooze: { Task { await viewModel.snooze(item) } }
                                    )
                                } label: {
                                    DigestRowView(obligation: item)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button {
                                        Task { await viewModel.markDone(item) }
                                    } label: {
                                        Label("Done", systemImage: "checkmark")
                                    }
                                    .tint(.green)
                                    Button(role: .destructive) {
                                        Task { await viewModel.dismiss(item) }
                                    } label: {
                                        Label("Dismiss", systemImage: "eye.slash")
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        Task { await viewModel.confirm(item) }
                                    } label: {
                                        Label("Confirm", systemImage: "checkmark.seal")
                                    }
                                    .tint(.blue)
                                }
                            }
                        } label: {
                            DigestSectionHeader(kind: section.kind, count: section.items.count)
                        }
                    }
                } else {
                    Section {
                        ForEach(section.items) { item in
                            NavigationLink {
                                ObligationDetailView(
                                    obligation: item,
                                    environment: environment.value,
                                    onConfirm: { Task { await viewModel.confirm(item) } },
                                    onDone: { Task { await viewModel.markDone(item) } },
                                    onDismiss: { Task { await viewModel.dismiss(item) } },
                                    onSnooze: { Task { await viewModel.snooze(item) } }
                                )
                            } label: {
                                DigestRowView(obligation: item)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    Task { await viewModel.markDone(item) }
                                } label: {
                                    Label("Done", systemImage: "checkmark")
                                }
                                .tint(.green)
                                Button(role: .destructive) {
                                    Task { await viewModel.dismiss(item) }
                                } label: {
                                    Label("Dismiss", systemImage: "eye.slash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await viewModel.confirm(item) }
                                } label: {
                                    Label("Confirm", systemImage: "checkmark.seal")
                                }
                                .tint(.blue)
                            }
                        }
                    } header: {
                        DigestSectionHeader(kind: section.kind)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var filterRow: some View {
        Button {
            showingFilters = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text("Filters")
                Spacer()
                Text(filterSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var filterSummary: String {
        let prefs = environment.value.filterPreferencesStore
        let enabled = [
            prefs.includeSecurityAlerts,
            prefs.includeStatements,
            prefs.includeMarketing,
            prefs.includeNewsletters,
            prefs.includeShipping
        ].filter { $0 }.count
        return enabled == 0 ? "Default" : "\(enabled) on"
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

private struct BorderlineRowView: View {
    let item: BorderlineItem
    let onPromote: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.subject)
                .font(.subheadline.weight(.semibold))
            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("Thread")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                )
            HStack(spacing: 12) {
                Button("Promote") { onPromote() }
                    .buttonStyle(.borderedProminent)
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FilterPreferencesSheet: View {
    @ObservedObject var preferences: FilterPreferencesStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Include in Digest")) {
                    Toggle("Security alerts", isOn: $preferences.includeSecurityAlerts)
                    Toggle("Statements", isOn: $preferences.includeStatements)
                    Toggle("Marketing", isOn: $preferences.includeMarketing)
                    Toggle("Newsletters", isOn: $preferences.includeNewsletters)
                    Toggle("Shipping", isOn: $preferences.includeShipping)
                }
                Section {
                    Text("Defaults are off to keep only actionable obligations.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Filters")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Section Header

private struct DigestSectionHeader: View {
    let kind: DigestSection.Kind
    var count: Int? = nil
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .foregroundStyle(color)
            Text(kind.title)
            if let count {
                Text("(\(count))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }
    
    private var color: Color {
        switch kind.color {
        case .red: .red
        case .orange: .orange
        case .blue: .blue
        case .purple: .purple
        }
    }
}

// MARK: - Row View

private struct DigestRowView: View {
    let obligation: ObligationItem

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
    @State private var message: MessageRecord?
    @State private var account: MailboxAccountRecord?
    @Environment(\.openURL) private var openURL

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
            }

            if !obligation.matchedReasons.isEmpty {
                Section("Why this matters") {
                    ForEach(obligation.matchedReasons, id: \.self) { reason in
                        Text(shortReasonLabel(for: reason))
                    }
                }
            }

            if let messageBody = messageBodyText {
                Section("Message") {
                    Text(messageBody)
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
        .task {
            message = try? await environment.messageRepository.fetchByPk(obligation.messagePk)
            if let mailboxId = message?.mailboxAccountId {
                account = try? await environment.mailboxAccountRepository.fetch(byId: mailboxId)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Confirm") { onConfirm() }
                .buttonStyle(.borderedProminent)
            Button("Done") { onDone() }
                .buttonStyle(.bordered)
            Button(role: .destructive) {
                onDismiss()
            } label: {
                Text("Dismiss")
            }
            .buttonStyle(.bordered)
            Button("Snooze") { onSnooze() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
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
        if let body = message?.bodyText, !body.isEmpty {
            return body
        }
        if let snippet = message?.snippet, !snippet.isEmpty {
            return snippet
        }
        return nil
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
