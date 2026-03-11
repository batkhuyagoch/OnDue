import SwiftUI
import GoogleSignIn
import Combine

@MainActor
class AuthenticationState: ObservableObject {
    @Published var isSignedIn = false
    @Published var userEmail: String?
    @Published var lastSyncDate: Date?
    @Published var isCheckingSignIn = true

    func checkSignInStatus() async {
        isCheckingSignIn = true

        do {
            let restored = try await GmailAuthService.shared.restorePreviousSignIn()
            if restored {
                isSignedIn = true
                userEmail = GIDSignIn.sharedInstance.currentUser?.profile?.email
            } else {
                isSignedIn = false
                userEmail = nil
            }
        } catch {
            isSignedIn = GIDSignIn.sharedInstance.currentUser != nil
            userEmail = GIDSignIn.sharedInstance.currentUser?.profile?.email
        }

        isCheckingSignIn = false
    }

    func signIn() async {
        do {
            try await GmailAuthService.shared.authorize()
            await checkSignInStatus()
        } catch {
            print("Sign in error: \(error)")
        }
    }

    func signOut() async {
        GmailAuthService.shared.signOut()
        isSignedIn = false
        userEmail = nil
    }
}

struct OnboardingFlow: View {
    @EnvironmentObject private var authState: AuthenticationState
    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $currentPage) {
                OnboardingPage(
                    icon: "sparkle.magnifyingglass",
                    iconColor: .blue,
                    title: "Find Obligations Automatically",
                    description: "OnDue scans your Gmail to find deadlines, requests, and commitments you need to act on"
                )
                .tag(0)

                OnboardingPage(
                    icon: "checkmark.circle",
                    iconColor: .green,
                    title: "Never Miss What Matters",
                    description: "Get reminded about important obligations before they're due. Stay on top of everything."
                )
                .tag(1)

                OnboardingPage(
                    icon: "hand.raised",
                    iconColor: .orange,
                    title: "Privacy First",
                    description: "All scanning happens on your device. Your emails never leave your phone."
                )
                .tag(2)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 16) {
                Button {
                    Task {
                        await authState.signIn()
                    }
                } label: {
                    HStack {
                        Image(systemName: "envelope")
                        Text("Connect Gmail to Get Started")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("We only request read-only access")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let privacyURL = AppPrivacyConfiguration.privacyPolicyURL {
                    Link("Privacy Policy", destination: privacyURL)
                        .font(.caption)
                }
            }
            .padding()
            .padding(.bottom)
        }
    }
}

private struct OnboardingPage: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: icon)
                .font(.system(size: 80))
                .foregroundStyle(iconColor)

            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .padding()
    }
}
