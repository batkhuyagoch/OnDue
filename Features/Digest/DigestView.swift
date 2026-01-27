import SwiftUI
import Combine

struct DigestView: View {
    @EnvironmentObject private var environment: AppEnvironmentStore
    @StateObject private var viewModel = DigestViewModel()

    var body: some View {
        NavigationView {
            List {
                if viewModel.items.isEmpty {
                    ContentUnavailableView(
                        "No obligations yet",
                        systemImage: "checkmark.seal",
                        description: Text("Connect Gmail to build your digest.")
                    )
                } else {
                    ForEach(viewModel.items) { item in
                        DigestRow(item: item)
                    }
                }
            }
            .navigationTitle("Digest")
            .task {
                await viewModel.loadDigest(using: environment.value)
            }
        }
    }
}

private struct DigestRow: View {
    let item: Obligation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
            if let deadline = item.deadline {
                Text(deadline.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let evidence = item.evidenceLines.first {
                Text("“\(evidence.text)”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
