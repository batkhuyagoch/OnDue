import SwiftUI

@MainActor
final class ManualPromotionSheetViewModel: ObservableObject {
    @Published var isPromoting = false
    @Published var error: Error?
    @Published var success = false

    private let messageId: String
    private let mailboxAccountId: String
    private let useCase: ManualPromotionUseCaseing

    init(
        messageId: String,
        mailboxAccountId: String,
        useCase: ManualPromotionUseCaseing
    ) {
        self.messageId = messageId
        self.mailboxAccountId = mailboxAccountId
        self.useCase = useCase
    }

    func promote() async {
        isPromoting = true
        defer { isPromoting = false }
        do {
            _ = try await useCase.promote(messageId: messageId, mailboxAccountId: mailboxAccountId)
            success = true
        } catch {
            self.error = error
        }
    }
}

struct ManualPromotionSheet: View {
    @Binding var isPresented: Bool
    @StateObject private var viewModel: ManualPromotionSheetViewModel

    init(
        messageId: String,
        mailboxAccountId: String,
        useCase: ManualPromotionUseCaseing,
        isPresented: Binding<Bool>
    ) {
        _isPresented = isPresented
        _viewModel = StateObject(
            wrappedValue: ManualPromotionSheetViewModel(
                messageId: messageId,
                mailboxAccountId: mailboxAccountId,
                useCase: useCase
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if viewModel.success {
                    successView
                } else {
                    promptView
                }
            }
            .padding()
            .navigationTitle("Promote to Important")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
            .alert(error: $viewModel.error)
        }
    }

    private var promptView: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Add this email to your important items?")
                .font(.headline)

            Text("This will mark it as an obligation and show it in your timeline.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                Task { await viewModel.promote() }
            } label: {
                if viewModel.isPromoting {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Promote to Important")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isPromoting)
        }
    }

    private var successView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)

            Text("Added to Important Items")
                .font(.headline)

            Text("You can now find this in your Timeline and Important views.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Done") {
                isPresented = false
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .buttonStyle(.borderedProminent)
        }
    }
}
