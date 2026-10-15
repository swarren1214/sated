import AuthenticationServices
import SwiftUI

/// The sign-in screen, laid out like Suffice's and Hearken's: the app icon, name and promise,
/// three things Sated does, and Sign in with Apple pinned at the bottom with "Not now" under it.
///
/// Signing in is optional unless `AppConfig.requiresSignIn` is on (App Review guideline
/// 5.1.1(v): the food log works without an account). Someone already signed in to BigTable or
/// Suffice on this iPhone never sees it; Sated picks up that sign-in.
struct SignInView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let isShort = proxy.size.height < 700 || verticalSizeClass == .compact
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: isShort ? 20 : 32) {
                        header(isShort: isShort)
                        features
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, isShort ? 32 : 72)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 520)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)

                controls
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemBackground))
        .interactiveDismissDisabled()
    }

    private func header(isShort: Bool) -> some View {
        VStack(spacing: 14) {
            Image("AppIconImage")
                .resizable()
                .scaledToFit()
                .frame(width: isShort ? 64 : 92, height: isShort ? 64 : 92)
                .clipShape(RoundedRectangle(cornerRadius: (isShort ? 64 : 92) * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .accessibilityHidden(true)
            Text("Sated")
                .font(.largeTitle.bold())
            Text("Eat well, without the busywork.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 18) {
            FeatureRow(symbol: "mic.fill", title: "Log by saying it", detail: "“Two eggs and toast” becomes a logged breakfast, from your iPhone, Watch or Siri.")
            FeatureRow(symbol: "fork.knife", title: "Eating out, covered", detail: "Restaurant menus and your usuals at the places you go.")
            FeatureRow(symbol: "lock.fill", title: "Private by design", detail: "Your log stays on your devices and in your own iCloud. Coach runs on your iPhone.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            AppleSignInButton()
            if !AppConfig.requiresSignIn {
                Button("Not now") {
                    withAnimation { account.skipSignIn() }
                }
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            Text("One sign-in for Sated, BigTable and Suffice. Sated never uploads your food log.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Sign in with Apple, wired to `AccountStore`. Black in light mode, white in dark, as Apple asks.
struct AppleSignInButton: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce: String?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
            do {
                nonce = try HearthAPI.prepareAppleRequest(request)
            } catch {
                errorMessage = error.localizedDescription
            }
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    errorMessage = "Apple didn't return a usable sign-in. Please try again."
                    return
                }
                let requestNonce = nonce
                isWorking = true
                Task {
                    defer { isWorking = false }
                    do {
                        try await account.signIn(with: credential, nonce: requestNonce)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            case .failure(let error as ASAuthorizationError) where error.code == .canceled:
                break
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 50)
        .clipShape(Capsule())
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView()
                    .tint(colorScheme == .dark ? .black : .white)
            }
        }
        .alert("Couldn't Sign In", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

private struct FeatureRow: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    SignInView()
        .environment(AccountStore.shared)
}
