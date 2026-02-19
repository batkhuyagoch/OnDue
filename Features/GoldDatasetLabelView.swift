import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct GoldDatasetLabelView: View {
    @StateObject private var viewModel = GoldDatasetLabelViewModel()
    @State private var showOverride = false
    @State private var showImporter = false
    @State private var customReason = ""
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            if let message = viewModel.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(viewModel.progressText)
                    .font(.subheadline.weight(.semibold))
                if viewModel.hasUnsavedChanges {
                    Text("Unsaved changes")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
                Spacer()
                Button("Back") { viewModel.back() }
                    .disabled(viewModel.currentIndex == 0)
            }
            if let path = viewModel.savePath {
                Text("Saved to \(path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let item = viewModel.currentItem {
                cardView(item: item)
            } else {
                Text("No items loaded.")
                    .foregroundStyle(.secondary)
            }

            actionBar
        }
        .padding()
        .navigationTitle("Label Dataset")
        .searchable(text: $viewModel.searchQuery, placement: .navigationBarDrawer(displayMode: .automatic))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Reload") { viewModel.load() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(viewModel.availableDatasetFilenames, id: \.self) { filename in
                        Button(filename) {
                            viewModel.selectDataset(filename)
                        }
                    }
                } label: {
                    Label(
                        viewModel.selectedDatasetFilename.isEmpty ? "Dataset" : viewModel.selectedDatasetFilename,
                        systemImage: "folder"
                    )
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Import") { showImporter = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { viewModel.save() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let url = viewModel.savedURL {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sheet(isPresented: $showOverride) {
            overrideSheet
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [UTType.json],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            viewModel.importDataset(from: url)
        }
        .onAppear {
            viewModel.refreshDatasetChoices()
            viewModel.load()
        }
    }

    private func cardView(item: GoldDatasetExportItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(item.subject)
                    .font(.headline)
                Spacer()
                Text(item.currentConfidence.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
            }

            Text(item.snippet ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(item.sender)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Engine output")
                    .font(.caption.weight(.semibold))
                Text("Decision: \(item.currentDecision.rawValue)")
                    .font(.caption)
                if let reasonText = viewModel.canonicalReasonText(for: item) {
                    Text("Reason: \(reasonText)")
                        .font(.caption)
                }
                if !item.currentHypotheses.isEmpty {
                    Text("Hypotheses: \(item.currentHypotheses.joined(separator: ", "))")
                        .font(.caption)
                }
                if !item.currentReasons.isEmpty {
                    Text("Reasons: \(item.currentReasons.joined(separator: " • "))")
                        .font(.caption)
                }
            }

            Divider()

            reasonChips(item: item)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(alignment: .topLeading) {
            swipeBadge
        }
        .offset(x: dragOffset.width * 0.15, y: dragOffset.height * 0.15)
        .gesture(dragGesture)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button("Reject") { viewModel.labelCurrent(outcome: "reject") }
                .buttonStyle(.bordered)
            Button("Needs Review") { viewModel.labelCurrent(outcome: "needsReview") }
                .buttonStyle(.bordered)
            Button("Accept") { viewModel.labelCurrent(outcome: "accept") }
                .buttonStyle(.borderedProminent)
            Button("Approve current") { viewModel.approveCurrent() }
                .buttonStyle(.bordered)
            Button("Override") { showOverride = true }
                .buttonStyle(.bordered)
        }
    }

    private func reasonChips(item: GoldDatasetExportItem) -> some View {
        var options = viewModel.reasonOptions.filter { !$0.isEmpty && $0 != "Other..." }
        if let canonical = viewModel.canonicalReasonText(for: item), !options.contains(canonical) {
            options.insert(canonical, at: 0)
        }
        let chips = Array(options.prefix(6))
        return VStack(alignment: .leading, spacing: 8) {
            Text("Quick reason")
                .font(.caption.weight(.semibold))
            WrapView(items: Array(chips)) { chip in
                Button(chip) {
                    if chip == "Other..." {
                        showOverride = true
                    } else {
                        viewModel.applyReason(chip)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                defer { dragOffset = .zero }
                if value.translation.width > 120 {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    viewModel.labelCurrent(outcome: "accept")
                } else if value.translation.width < -120 {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    viewModel.labelCurrent(outcome: "reject")
                } else if value.translation.height < -120 {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    viewModel.labelCurrent(outcome: "needsReview")
                }
            }
    }

    private var swipeBadge: some View {
        switch swipeDirection {
        case .accept:
            return AnyView(badge(text: "ACCEPT", color: .green))
        case .reject:
            return AnyView(badge(text: "REJECT", color: .red))
        case .needsReview:
            return AnyView(badge(text: "REVIEW", color: .orange))
        case .none:
            return AnyView(EmptyView())
        }
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color, lineWidth: 2)
            )
    }

    private var swipeDirection: SwipeDirection? {
        if dragOffset.width > 80 { return .accept }
        if dragOffset.width < -80 { return .reject }
        if dragOffset.height < -80 { return .needsReview }
        return nil
    }

    private var overrideSheet: some View {
        NavigationStack {
            Form {
                Section("Expected outcome") {
                    Picker("Outcome", selection: Binding(
                        get: { viewModel.currentItem?.expectedOutcome ?? "" },
                        set: { newValue in
                            if let item = viewModel.currentItem {
                                viewModel.updateExpectedOutcome(item, value: newValue.isEmpty ? nil : newValue)
                            }
                        }
                    )) {
                        Text("Unlabeled").tag("")
                        ForEach(viewModel.decisionValues, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                }

                Section("Expected hypothesis") {
                    Picker("Hypothesis", selection: Binding(
                        get: { viewModel.currentItem?.expectedHypothesis ?? "" },
                        set: { newValue in
                            if let item = viewModel.currentItem {
                                viewModel.updateExpectedHypothesis(item, value: newValue.isEmpty ? nil : newValue)
                            }
                        }
                    )) {
                        Text("Unlabeled").tag("")
                        ForEach(viewModel.hypothesisValues, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                }

                Section("Expected reason") {
                    Picker("Reason", selection: $customReason) {
                        Text("Custom").tag("")
                        ForEach(viewModel.reasonOptions.filter { $0 != "Other..." }, id: \.self) { value in
                            Text(value).tag(value)
                        }
                    }
                    .onChange(of: customReason) { _, newValue in
                        if let item = viewModel.currentItem, !newValue.isEmpty {
                            viewModel.updateExpectedReason(item, value: newValue)
                        }
                    }
                    TextField("Custom reason", text: $customReason, axis: .vertical)
                }
            }
            .navigationTitle("Override")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showOverride = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if let item = viewModel.currentItem {
                            if !customReason.isEmpty {
                                viewModel.updateExpectedReason(item, value: customReason)
                            }
                        }
                        showOverride = false
                        viewModel.advance()
                    }
                }
            }
            .onAppear {
                customReason = viewModel.currentItem?.expectedReason ?? ""
            }
        }
    }
}

private struct WrapView<Item: Hashable, Content: View>: View {
    let items: [Item]
    let content: (Item) -> Content

    var body: some View {
        FlexibleView(data: items, spacing: 8, alignment: .leading, content: content)
    }
}

private struct FlexibleView<Data: Collection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let alignment: HorizontalAlignment
    let content: (Data.Element) -> Content

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            ForEach(buildRows(), id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(row, id: \.self) { element in
                        content(element)
                    }
                }
            }
        }
    }

    private func buildRows() -> [[Data.Element]] {
        var rows: [[Data.Element]] = [[]]
        var currentRowWidth: CGFloat = 0
        let maxWidth: CGFloat = 300

        for element in data {
            let elementWidth: CGFloat = 100
            if currentRowWidth + elementWidth + spacing > maxWidth {
                rows.append([element])
                currentRowWidth = elementWidth
            } else {
                rows[rows.count - 1].append(element)
                currentRowWidth += elementWidth + spacing
            }
        }
        return rows
    }
}

private enum SwipeDirection {
    case accept
    case reject
    case needsReview
}
