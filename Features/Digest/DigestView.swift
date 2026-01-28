import SwiftUI

struct DigestView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = DigestViewModel()

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Digest")
        }
        .task {
            await viewModel.loadDigest(using: environment.value)
        }
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
            "No obligations yet",
            systemImage: "checkmark.seal",
            description: Text("Connect Gmail to build your digest.")
        )
    }
    
    private var digestList: some View {
        List {
            ForEach(viewModel.sections) { section in
                Section {
                    ForEach(section.items) { item in
                        DigestRowView(obligation: item)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    Task { await viewModel.dismiss(item) }
                                } label: {
                                    Label("Dismiss", systemImage: "eye.slash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    Task { await viewModel.snooze(item) }
                                } label: {
                                    Label("Snooze", systemImage: "moon.zzz")
                                }
                                .tint(.indigo)
                            }
                    }
                } header: {
                    DigestSectionHeader(kind: section.kind)
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - Section Header

private struct DigestSectionHeader: View {
    let kind: DigestSection.Kind
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .foregroundStyle(color)
            Text(kind.title)
        }
        .font(.subheadline.weight(.semibold))
        .textCase(nil)
    }
    
    private var color: Color {
        switch kind.color {
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
            evidenceText
        }
        .padding(.vertical, 4)
    }
    
    private var titleText: some View {
        Text(obligation.title)
            .font(.headline)
    }
    
    @ViewBuilder
    private var deadlineText: some View {
        if let deadline = obligation.deadline {
            Text(deadline.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private var evidenceText: some View {
        if !obligation.evidenceQuote.isEmpty {
            Text("\"\(obligation.evidenceQuote)\"")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
    }
}
