// Infinite Recall fork: this view is unreachable in the local-first build —
// the auth gate in DesktopHomeView/RewindOnlyView short-circuits to anonymous.
// Kept as a stub so dead-branch references still compile. If the gate ever
// fires (it shouldn't), the user sees a clear "no accounts" message and the
// buttons no-op locally without touching any network.
import SwiftUI

struct SignInView: View {
    @ObservedObject var authState: AuthState

    var body: some View {
        ZStack {
            // Full background
            OmiColors.backgroundPrimary
                .ignoresSafeArea()

            // Centered sign in card
            VStack(spacing: 32) {
                Spacer()

                // Logo/Title
                VStack(spacing: 16) {
                    if let logoURL = Bundle.resourceBundle.url(forResource: "herologo", withExtension: "png"),
                       let logoImage = NSImage(contentsOf: logoURL) {
                        Image(nsImage: logoImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 64, height: 64)
                    }

                    Text("Infinite Recall")
                        .scaledFont(size: 48, weight: .bold)
                        .foregroundColor(OmiColors.textPrimary)

                    Text("This build does not use accounts.")
                        .font(.title3)
                        .foregroundColor(OmiColors.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                // Disabled for local-first fork — anonymous user only.
                VStack(spacing: 12) {
                    Button(action: {
                        // Disabled for local-first fork — anonymous user only.
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "applelogo")
                                .scaledFont(size: 18)
                            Text("Sign in with Apple")
                                .scaledFont(size: 17, weight: .medium)
                        }
                        .foregroundColor(.black.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white.opacity(0.5))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(true)

                    Button(action: {
                        // Disabled for local-first fork — anonymous user only.
                    }) {
                        HStack(spacing: 8) {
                            GoogleLogo()
                                .frame(width: 18, height: 18)
                            Text("Sign in with Google")
                                .scaledFont(size: 17, weight: .medium)
                        }
                        .foregroundColor(.black.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white.opacity(0.5))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(true)
                }
                .frame(width: 320)

                Spacer()
                    .frame(height: 60)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Google Logo

/// Standard multicolor Google "G" logo
struct GoogleLogo: View {
    var body: some View {
        if let url = Bundle.resourceBundle.url(forResource: "google_logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

#Preview {
    SignInView(authState: AuthState.shared)
}
