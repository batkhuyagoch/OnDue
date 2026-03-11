import SwiftUI
import Combine

// MARK: - Redesigned Digest View (Apple-style UX)

struct DigestView_Redesigned: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = DigestViewModel()
    @Namespace private var animation

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                // Quick Stats Header
                if !viewModel.isEmpty {
                    quickStatsHeader
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                }
                
                // Filter Pills
                filterRow
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                
                // Obligation Cards
                if viewModel.isEmpty {
                    emptyState
                        .padding(.top, 60)
                } else {
                    obligationCards
                        .padding(.horizontal)
                }
            }
        }
        .refreshable {
            await performQuickSync()
        }
        .background(Color(.systemGroupedBackground))
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
        .onChange(of: viewModel.selectedMode) { _, _ in
            Task { await viewModel.loadDigest(using: environment.value) }
        }
        .onChange(of: viewModel.selectedGrouping) { _, _ in
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
            toastOverlays
        }
        .animation(.easeInOut, value: viewModel.undoBanner?.id)
        .animation(.easeInOut, value: viewModel.learningBanner)
    }
    
    // MARK: - Quick Sync
    
    private func performQuickSync() async {
        do {
            let accounts = try await environment.value.mailboxAccountRepository.fetchAll()
            guard let account = accounts.first else { return }
            
            _ = try await environment.value.gmailSyncCoordinator.sync(
                mailboxAccountId: account.id,
                daysBack: 30,
                forceFullSync: false
            )
            
            // Reload the digest after sync
            await viewModel.loadDigest(using: environment.value)
        } catch {
            print("Quick sync failed: \(error)")
        }
    }
    
    // MARK: - Quick Stats Header
    
    private var quickStatsHeader: some View {
        HStack(spacing: 16) {
            if viewModel.isGlobalSearchActive {
                StatBubble(
                    value: globalSearchCount(for: .now),
                    label: "Now",
                    icon: "circle.fill",
                    color: .blue
                )
                StatBubble(
                    value: globalSearchCount(for: .later),
                    label: "Later",
                    icon: "calendar",
                    color: .orange
                )
                StatBubble(
                    value: globalSearchCount(for: .done),
                    label: "Done",
                    icon: "checkmark.circle.fill",
                    color: .green
                )
            } else {
                // Show different stats based on selected mode
                switch viewModel.selectedMode {
                case .now:
                    StatBubble(
                        value: totalItemsInView,
                        label: "Now",
                        icon: "circle.fill",
                        color: .blue
                    )
                    StatBubble(
                        value: dueTodayCount,
                        label: "Today",
                        icon: "clock.fill",
                        color: .orange
                    )
                    StatBubble(
                        value: thisWeekCount,
                        label: "This Week",
                        icon: "calendar",
                        color: .purple
                    )
                case .later:
                    StatBubble(
                        value: totalItemsInView,
                        label: "Later",
                        icon: "calendar.badge.clock",
                        color: .orange
                    )
                    StatBubble(
                        value: wakingTodayCount,
                        label: "Due Today",
                        icon: "bell.fill",
                        color: .orange
                    )
                case .done:
                    StatBubble(
                        value: totalItemsInView,
                        label: "Done",
                        icon: "checkmark.circle.fill",
                        color: .green
                    )
                    StatBubble(
                        value: resolvedTodayCount,
                        label: "Today",
                        icon: "calendar",
                        color: .secondary
                    )
                }
            }
            
            Spacer()
        }
    }
    
    private func globalSearchCount(for mode: DigestMode) -> Int {
        let title = mode.title
        guard let section = viewModel.sections.first(where: { $0.title == title }) else {
            return 0
        }
        return section.items.count
    }
    
    // Total items currently visible
    private var totalItemsInView: Int {
        viewModel.sections.reduce(0) { $0 + $1.items.count }
    }
    
    // Count for active lens
    private var dueTodayCount: Int {
        viewModel.sections.reduce(0) { sum, section in
            sum + section.items.filter { $0.dueBucket == .today }.count
        }
    }
    
    private var thisWeekCount: Int {
        viewModel.sections.reduce(0) { sum, section in
            sum + section.items.filter { $0.dueBucket == .next3Days || $0.dueBucket == .next7Days }.count
        }
    }
    
    // Count for later mode
    private var wakingTodayCount: Int {
        viewModel.sections.reduce(0) { sum, section in
            sum + section.items.filter { item in
                guard let snoozeUntil = item.obligation.snoozedUntil else { return false }
                return Calendar.current.isDateInToday(snoozeUntil)
            }.count
        }
    }
    
    // Count for done mode
    private var resolvedTodayCount: Int {
        viewModel.sections.reduce(0) { sum, section in
            sum + section.items.filter { item in
                // Use updatedAt as a proxy for when it was resolved
                Calendar.current.isDateInToday(item.obligation.updatedAt)
            }.count
        }
    }
    
    // MARK: - Filter Row
    
    private var filterRow: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $viewModel.selectedMode) {
                ForEach(DigestMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Menu {
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
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Obligation Cards
    
    private var obligationCards: some View {
        LazyVStack(spacing: 12) {
            ForEach(viewModel.sections) { section in
                if !section.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        // Section Header
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.top, 8)
                        
                        // Cards
                        ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                            ModernObligationCard(
                                obligation: item.obligation,
                                state: item.state,
                                senderEmail: item.senderEmail,
                                senderDomain: item.senderDomain,
                                onConfirm: { Task { await viewModel.confirm(item.obligation) } },
                                onDone: { Task { await viewModel.markDone(item.obligation) } },
                                onDismiss: { Task { await viewModel.dismiss(item.obligation) } },
                                onSnooze: { Task { await viewModel.snooze(item.obligation) } },
                                onBlockSender: { sender in
                                    Task { await viewModel.blockSender(item.obligation, senderOverride: sender) }
                                },
                                onBlockDomain: { domain in
                                    Task { await viewModel.blockDomain(item.obligation, domainOverride: domain) }
                                },
                                environment: environment.value
                            )
                            .onAppear {
                                Task {
                                    await viewModel.logExposure(
                                        obligation: item.obligation,
                                        state: item.state,
                                        position: index
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            // Different empty states based on lens
            switch viewModel.selectedMode {
            case .now:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green, .green.opacity(0.2))
                    .symbolEffect(.bounce, value: viewModel.isEmpty)
                
                Text("You're all caught up!")
                    .font(.title2.weight(.bold))
                
                Text("No items need your attention right now")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .later:
                Image(systemName: "zzz")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                
                Text("Nothing for later")
                    .font(.title2.weight(.bold))
                
                Text("Upcoming and snoozed items will appear here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .done:
                Image(systemName: "tray")
                    .font(.system(size: 64))
                    .foregroundStyle(.secondary)
                
                Text("Nothing completed yet")
                    .font(.title2.weight(.bold))
                
                Text("Finished obligations appear here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
    
    // MARK: - Toast Overlays
    
    @ViewBuilder
    private var toastOverlays: some View {
        if let banner = viewModel.undoBanner {
            UndoToast(
                message: banner.message,
                onUndo: { Task { await viewModel.undoLastAction() } }
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .padding(.horizontal)
            .padding(.bottom, 12)
        } else if let learning = viewModel.learningBanner {
            LearningToast(message: learning)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.horizontal)
                .padding(.bottom, 12)
        }
    }
}

// MARK: - Supporting Views

private struct StatBubble: View {
    let value: Int
    let label: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text("\(value)")
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(color)
            
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 60)
    }
}

private struct FilterPill: View {
    let title: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void
    
    init(title: String, count: Int? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.isSelected = isSelected
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                
                if let count = count {
                    Text("(\(count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? Color.blue : Color(.systemGray5))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ModernObligationCard: View {
    let obligation: ObligationItem
    let state: ObligationLifecycleState
    let senderEmail: String?
    let senderDomain: String?
    let onConfirm: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void
    let onSnooze: () -> Void
    let onBlockSender: (String) -> Void
    let onBlockDomain: (String) -> Void
    let environment: AppEnvironment
    
    @State private var showDetail = false
    @State private var showActions = false
    @State private var offset: CGFloat = 0
    @State private var isDragging = false
    
    var body: some View {
        Button {
            showDetail = true
        } label: {
            cardContent
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu {
            contextMenuActions
        }
        .sheet(isPresented: $showDetail) {
            NavigationStack {
                ObligationDetailView(
                    obligation: obligation,
                    state: state,
                    environment: environment,
                    onConfirm: onConfirm,
                    onDone: onDone,
                    onDismiss: onDismiss,
                    onSnooze: onSnooze,
                    onBlockSender: onBlockSender,
                    onBlockDomain: onBlockDomain
                )
            }
        }
    }
    
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top Row: Status Badge + Deadline
            HStack {
                if state == .needsReview {
                    StatusBadge(
                        text: "Need Confirmation",
                        icon: "sparkles",
                        color: .blue
                    )
                } else if isOverdue {
                    StatusBadge(
                        text: "Overdue",
                        icon: "exclamationmark.circle.fill",
                        color: .red
                    )
                } else if isDueToday {
                    StatusBadge(
                        text: "Today",
                        icon: "clock.fill",
                        color: .orange
                    )
                }
                
                Spacer()
                
                if let deadline = obligation.deadline {
                    DeadlineChip(deadline: deadline)
                }
            }
            
            // Title
            Text(obligation.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)

            if let senderLine {
                HStack(spacing: 6) {
                    Image(systemName: "at")
                        .font(.caption2)
                    Text(senderLine)
                        .font(.caption)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            
            // Evidence Quote
            if !obligation.evidenceQuote.isEmpty {
                Text("\"\(obligation.evidenceQuote)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
            }
            
            // Bottom Row: Category + Quick Actions
            HStack {
                // Category Icon
                HStack(spacing: 4) {
                    Image(systemName: categoryIcon)
                        .font(.caption2)
                    Text(obligation.category.rawValue.capitalized)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(.secondary)
                
                Spacer()
                
                // Quick Action Buttons
                quickActions
            }
        }
        .padding(16)
    }
    
    private var quickActions: some View {
        HStack(spacing: 8) {
            // Confirm/Done button
            Button {
                if state == .needsReview {
                    onConfirm()
                } else {
                    onDone()
                }
            } label: {
                Image(systemName: state == .needsReview ? "checkmark.seal.fill" : "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(state == .needsReview ? .blue : .green)
            }
            .buttonStyle(.plain)
            
            // Snooze button
            Button {
                onSnooze()
            } label: {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            
            // Direct "Not an Obligation" action
            Button(role: .destructive) {
                onDismiss()
            } label: {
                Image(systemName: "eye.slash")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
    
    @ViewBuilder
    private var contextMenuActions: some View {
        Button {
            if state == .needsReview {
                onConfirm()
            } else {
                onDone()
            }
        } label: {
            Label(state == .needsReview ? "Confirm" : "Mark Done", systemImage: "checkmark.circle")
        }
        
        Button {
            onSnooze()
        } label: {
            Label("Snooze", systemImage: "clock")
        }
        
        Divider()
        
        Button(role: .destructive) {
            onDismiss()
        } label: {
            Label("Not an Obligation", systemImage: "eye.slash")
        }

        Divider()

        Button(role: .destructive) {
            // Empty override intentionally falls back to message lookup in DigestViewModel.
            onBlockSender("")
        } label: {
            Label("Block Sender", systemImage: "hand.raised")
        }

        Button(role: .destructive) {
            // Empty override intentionally falls back to message lookup in DigestViewModel.
            onBlockDomain("")
        } label: {
            Label("Block Domain", systemImage: "network")
        }
    }
    
    private var isOverdue: Bool {
        guard let deadline = obligation.deadline else { return false }
        return deadline < Calendar.current.startOfDay(for: Date())
    }
    
    private var isDueToday: Bool {
        guard let deadline = obligation.deadline else { return false }
        return Calendar.current.isDateInToday(deadline)
    }
    
    private var categoryIcon: String {
        switch obligation.category {
        case .payment: return "dollarsign.circle"
        case .document: return "doc.text"
        case .appointment: return "calendar"
        case .deadline: return "clock.badge.exclamationmark"
        case .request: return "hand.raised"
        case .followUp: return "arrow.turn.up.right"
        case .other: return "doc"
        }
    }

    private var senderLine: String? {
        let trimmedEmail = senderEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDomain = senderDomain?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedEmail, !trimmedEmail.isEmpty {
            if let trimmedDomain, !trimmedDomain.isEmpty, !trimmedEmail.lowercased().contains(trimmedDomain.lowercased()) {
                return "\(trimmedEmail) • \(trimmedDomain)"
            }
            return trimmedEmail
        }
        if let trimmedDomain, !trimmedDomain.isEmpty {
            return trimmedDomain
        }
        return nil
    }
}

private struct StatusBadge: View {
    let text: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }
}

private struct DeadlineChip: View {
    let deadline: Date
    
    private var timeText: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(deadline) {
            return deadline.formatted(date: .omitted, time: .shortened)
        } else if deadline < calendar.startOfDay(for: Date()) {
            let days = calendar.dateComponents([.day], from: deadline, to: Date()).day ?? 0
            return "\(days)d ago"
        } else {
            let days = calendar.dateComponents([.day], from: Date(), to: deadline).day ?? 0
            if days == 1 {
                return "Tomorrow"
            } else if days < 7 {
                return "\(days)d"
            } else {
                return deadline.formatted(date: .abbreviated, time: .omitted)
            }
        }
    }
    
    private var chipColor: Color {
        let calendar = Calendar.current
        if calendar.isDateInToday(deadline) {
            return .orange
        } else if deadline < calendar.startOfDay(for: Date()) {
            return .red
        } else {
            return .secondary
        }
    }
    
    var body: some View {
        Text(timeText)
            .font(.caption2.weight(.medium))
            .foregroundStyle(chipColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(chipColor.opacity(0.1))
            )
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}
// MARK: - Obligation Detail View (Reused from DigestView)

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
    @State private var showFullMessage = true
    @State private var showReasonBreakdown = false
    @State private var showDebugDiagnostics = false
    @State private var showDismissConfirmation = false
    @State private var showBlockSenderConfirmation = false
    @State private var showBlockDomainConfirmation = false
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        detailList
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
            .sheet(isPresented: $showReasonBreakdown) {
                NavigationStack {
                    List {
                        Section("Summary") {
                            Text(ReasonCatalog.displayText(for: obligation.reasonCode))
                                .font(.body)
                        }
                        if !reasonDetails.isEmpty {
                            Section("Signals (\(reasonDetails.count))") {
                                ForEach(Array(reasonDetails.enumerated()), id: \.offset) { _, reason in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 1)
                                        Text(reason)
                                            .font(.subheadline)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle("Why Flagged")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showReasonBreakdown = false }
                        }
                    }
                }
            }
            .task {
                message = try? await environment.messageRepository.fetchByPk(obligation.messagePk)
                if let mailboxId = message?.mailboxAccountId {
                    account = try? await environment.mailboxAccountRepository.fetch(byId: mailboxId)
                }
            }
    }

    private var detailList: some View {
        List {
            headerSection
            decisionSection
            reasonSection
            messageEvidenceSection
            keyFactsSection
            providerSection
            debugSection
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(obligation.title)
                    .font(.title3.weight(.semibold))
                senderIdentityRow
                statusChipsRow
            }
        }
    }

    @ViewBuilder
    private var providerSection: some View {
        if let providerURL = providerMessageURL {
            Section {
                Button {
                    openURL(providerURL)
                } label: {
                    Label(openLabel, systemImage: account?.provider == .gmail ? "envelope.badge" : "envelope")
                }
            }
        }
    }

    private var keyFactsSection: some View {
        Section("Context") {
            if let deadline = obligation.deadline {
                LabeledContent("Due", value: deadline.formatted(date: .abbreviated, time: .shortened))
            }
            if let account {
                LabeledContent("Inbox", value: account.emailAddress)
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
    }

    private var decisionSection: some View {
        Section("Decision") {
            LabeledContent("Outcome", value: state == .needsReview ? "Needs confirmation" : "Actionable")
            LabeledContent("Reason", value: ReasonCatalog.displayText(for: obligation.reasonCode))
            LabeledContent("Confidence", value: "\(Int(obligation.confidence * 100))%")
            LabeledContent("Policy", value: obligation.policyVersion)
        }
    }

    @ViewBuilder
    private var reasonSection: some View {
        if let reasonSummary = DigestReasonLabeler.summaryLine(for: obligation), !reasonSummary.isEmpty {
            Section("Why This Was Flagged") {
                Text(reasonSummary)
                    .font(.body.weight(.medium))

                if !reasonHighlights.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(reasonHighlights, id: \.self) { reason in
                            Text(reason)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .foregroundStyle(.secondary)
                                .background(
                                    Capsule()
                                        .fill(Color.secondary.opacity(0.12))
                                )
                        }
                    }
                }

                if reasonDetails.count > reasonHighlights.count {
                    Text("+\(reasonDetails.count - reasonHighlights.count) more signals")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !reasonDetails.isEmpty {
                    Button {
                        showReasonBreakdown = true
                    } label: {
                        Label("View full explanation", systemImage: "info.circle")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var messageEvidenceSection: some View {
        if let detailText = detailMessageText {
            Section("Message") {
                Text(showFullMessage ? detailText.full : detailText.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(showFullMessage ? nil : 10)
                    .fixedSize(horizontal: false, vertical: showFullMessage)
                    .textSelection(.enabled)
                if canExpandMessage(preview: detailText.preview, expanded: detailText.full) {
                    Button(showFullMessage ? "Show compact preview" : "Show full message") {
                        showFullMessage.toggle()
                    }
                    .font(.subheadline)
                }
                if detailText.isTruncated {
                    Text("Message is very long; this view shows the safe maximum. Open in provider for the absolute full source.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var debugSection: some View {
#if DEBUG
        Section("Diagnostics") {
            DisclosureGroup("Filter diagnostics", isExpanded: $showDebugDiagnostics) {
                Text(
                    DigestViewModel.digestFilterExplain(
                        obligation,
                        preferences: environment.filterPreferencesStore
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
#endif
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

    private var senderIdentityRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "at.circle")
                .foregroundStyle(.secondary)
            if let sender = message?.fromEmail, !sender.isEmpty {
                Text(sender)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else {
                Text("Sender unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            if let domain = message?.fromDomain, !domain.isEmpty {
                Text("• \(domain)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var statusChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(headerChips, id: \.title) { chip in
                    Text(chip.title)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(chip.background))
                        .foregroundStyle(chip.foreground)
                }
            }
        }
    }

    private var headerChips: [HeaderChip] {
        var chips: [HeaderChip] = []
        chips.append(state == .needsReview
            ? HeaderChip(title: "Need confirmation", foreground: .orange, background: Color.orange.opacity(0.12))
            : HeaderChip(title: "Active", foreground: .secondary, background: Color.secondary.opacity(0.12)))
        chips.append(riskChip)
        if let deadline = obligation.deadline {
            if deadline < Calendar.current.startOfDay(for: Date()) {
                chips.append(HeaderChip(title: "Overdue", foreground: .red, background: Color.red.opacity(0.12)))
            } else if Calendar.current.isDateInToday(deadline) {
                chips.append(HeaderChip(title: "Due today", foreground: .orange, background: Color.orange.opacity(0.12)))
            } else {
                chips.append(
                    HeaderChip(
                        title: "Due \(deadline.formatted(date: .abbreviated, time: .omitted))",
                        foreground: .secondary,
                        background: Color.secondary.opacity(0.12)
                    )
                )
            }
        }
        return chips
    }

    private var riskChip: HeaderChip {
        switch obligation.risk {
        case .high:
            return HeaderChip(title: "High risk", foreground: .red, background: Color.red.opacity(0.12))
        case .medium:
            return HeaderChip(title: "Medium risk", foreground: .orange, background: Color.orange.opacity(0.12))
        case .low:
            return HeaderChip(title: "Low risk", foreground: .secondary, background: Color.secondary.opacity(0.12))
        }
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

    private var reasonDetails: [String] {
        DigestReasonLabeler.detailLines(for: obligation)
    }

    private var reasonHighlights: [String] {
        Array(DigestReasonLabeler.highlightLines(for: obligation).prefix(4))
    }

    private var providerMessageURL: URL? {
        guard let message else { return nil }
        if account?.provider == .gmail {
            let trimmedThreadId = message.threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = (trimmedThreadId?.isEmpty == false ? trimmedThreadId : nil) ?? message.providerMessageId
            let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            return URL(string: "https://mail.google.com/mail/u/0/#all/\(encodedTarget)")
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

    private struct HeaderChip {
        let title: String
        let foreground: Color
        let background: Color
    }
}

// MARK: - Digest Reason Labeler (Reused from DigestView)

private enum DigestReasonLabeler {
    static func summaryLine(for obligation: ObligationItem) -> String? {
        if obligation.reasonCode != .other {
            return ReasonCatalog.displayText(for: obligation.reasonCode)
        }
        guard let firstReason = obligation.matchedReasons.first else { return nil }
        return shortReasonLabel(for: firstReason)
    }

    static func detailLines(for obligation: ObligationItem) -> [String] {
        var lines: [String] = []
        for reason in obligation.matchedReasons {
            let label = fullReasonLabel(for: reason)
            if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(label)
            }
        }
        return Array(Set(lines)).sorted()
    }

    static func highlightLines(for obligation: ObligationItem) -> [String] {
        var lines: [String] = []
        for reason in obligation.matchedReasons {
            let label = shortReasonLabel(for: reason)
            if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(label)
            }
        }
        return Array(Set(lines)).sorted()
    }

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
        return normalized
    }

    private static func fullReasonLabel(for reason: String) -> String {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "" }
        let explicitCode = ReasonCatalog.code(from: normalized)
        if explicitCode != .other {
            return ReasonCatalog.displayText(for: explicitCode)
        }
        return normalized
    }
}

