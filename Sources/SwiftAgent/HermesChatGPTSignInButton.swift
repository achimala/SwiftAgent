import SwiftUI
#if os(iOS)
import SafariServices
#elseif os(macOS)
import AppKit
#endif

@MainActor
public final class HermesChatGPTSignInState: ObservableObject {
    public enum Phase: Equatable {
        case idle
        case requestingCode
        case waitingForUser(HermesChatGPTDeviceAuthorization)
        case exchanging
        case signedIn
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    @Published public var isPresented = false

    private let authClient: HermesChatGPTAuthClient
    private let tokenStore: any HermesChatGPTTokenStore
    private var signInTask: Task<Void, Never>?
    private var onAuthenticated: (@MainActor (HermesChatGPTTokenResponse) -> Void)?

    public init(
        authClient: HermesChatGPTAuthClient = HermesChatGPTAuthClient(),
        tokenStore: any HermesChatGPTTokenStore = HermesChatGPTKeychainTokenStore()
    ) {
        self.authClient = authClient
        self.tokenStore = tokenStore
    }

    deinit {
        signInTask?.cancel()
    }

    public func storedTokens() throws -> HermesChatGPTTokenResponse? {
        try tokenStore.loadTokens()
    }

    public func signOut() throws {
        signInTask?.cancel()
        signInTask = nil
        phase = .idle
        try tokenStore.deleteTokens()
    }

    public func beginSignIn(onAuthenticated: @escaping @MainActor (HermesChatGPTTokenResponse) -> Void) {
        signInTask?.cancel()
        self.onAuthenticated = onAuthenticated
        isPresented = true
        phase = .requestingCode

        signInTask = Task { [authClient, tokenStore] in
            do {
                let deviceAuthorization = try await authClient.requestDeviceAuthorization()
                try Task.checkCancellation()
                phase = .waitingForUser(deviceAuthorization)

                let code = try await authClient.waitForAuthorizationCode(deviceAuthorization: deviceAuthorization)
                try Task.checkCancellation()
                phase = .exchanging

                let tokens = try await authClient.exchangeAuthorizationCode(
                    authorizationCode: code.authorizationCode,
                    codeVerifier: code.codeVerifier
                )
                try tokenStore.saveTokens(tokens)
                try Task.checkCancellation()

                phase = .signedIn
                isPresented = false
                onAuthenticated(tokens)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(Self.displayText(for: error))
            }
        }
    }

    public func retry() {
        guard let onAuthenticated else { return }
        beginSignIn(onAuthenticated: onAuthenticated)
    }

    public func cancel() {
        signInTask?.cancel()
        signInTask = nil
        isPresented = false
        phase = .idle
    }

    private static func displayText(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

public struct HermesChatGPTSignInButton<Label: View>: View {
    @StateObject private var state: HermesChatGPTSignInState
    private let label: () -> Label
    private let onAuthenticated: @MainActor (HermesChatGPTTokenResponse) -> Void

    public init(
        state: HermesChatGPTSignInState = HermesChatGPTSignInState(),
        @ViewBuilder label: @escaping () -> Label,
        onAuthenticated: @escaping @MainActor (HermesChatGPTTokenResponse) -> Void
    ) {
        _state = StateObject(wrappedValue: state)
        self.label = label
        self.onAuthenticated = onAuthenticated
    }

    public var body: some View {
        Button {
            state.beginSignIn(onAuthenticated: onAuthenticated)
        } label: {
            label()
        }
        .sheet(isPresented: $state.isPresented) {
            HermesChatGPTSignInSheet(state: state)
        }
    }
}

public extension HermesChatGPTSignInButton where Label == SwiftUI.Label<Text, Image> {
    init(
        state: HermesChatGPTSignInState = HermesChatGPTSignInState(),
        onAuthenticated: @escaping @MainActor (HermesChatGPTTokenResponse) -> Void
    ) {
        self.init(state: state) {
            Label("Sign in with ChatGPT", systemImage: "person.crop.circle.badge.checkmark")
        } onAuthenticated: {
            onAuthenticated($0)
        }
    }
}

private struct HermesChatGPTSignInSheet: View {
    @ObservedObject var state: HermesChatGPTSignInState
    @State private var copiedCode: String?

    var body: some View {
        switch state.phase {
        case .waitingForUser(let deviceAuthorization):
            deviceBrowser(deviceAuthorization)
        default:
            NavigationStack {
                content
                    .navigationTitle("ChatGPT")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                state.cancel()
                            }
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .idle, .requestingCode:
            centeredContent {
                ProgressView()
            }
        case .waitingForUser(let deviceAuthorization):
            deviceBrowser(deviceAuthorization)
        case .exchanging:
            centeredContent {
                ProgressView("Finishing sign in")
            }
        case .signedIn:
            centeredContent {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            centeredContent {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try Again") {
                    state.retry()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func centeredContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 24) {
            Spacer(minLength: 12)

            Image(systemName: imageName)
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()

            Spacer(minLength: 12)
        }
        .padding(24)
    }

    @ViewBuilder
    private func deviceBrowser(_ deviceAuthorization: HermesChatGPTDeviceAuthorization) -> some View {
        ZStack(alignment: .topTrailing) {
            #if os(iOS)
            HermesChatGPTSafariView(url: HermesChatGPTAuthConstants.deviceURL)
            .ignoresSafeArea()
            #else
            centeredContent {
                Link(destination: HermesChatGPTAuthConstants.deviceURL) {
                    Label("Open Sign In Page", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }
            #endif

            codeOverlay(deviceAuthorization.userCode)
                .padding(.top, 132)
                .padding(.trailing, 12)
        }
    }

    private func codeOverlay(_ code: String) -> some View {
        Button {
            copyCode(code)
        } label: {
            HStack(spacing: 8) {
                Text(code)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Image(systemName: copiedCode == code ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copiedCode == code ? "Copied code" : "Copy code")
        .ifAvailableChatGPTGlass(in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 5)
    }

    private func copyCode(_ code: String) {
        #if os(iOS)
        UIPasteboard.general.string = code
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif

        copiedCode = code
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedCode == code {
                copiedCode = nil
            }
        }
    }

    private var imageName: String {
        switch state.phase {
        case .failed:
            "exclamationmark.triangle"
        case .signedIn:
            "checkmark.circle"
        default:
            "person.crop.circle.badge.checkmark"
        }
    }

    private var title: String {
        switch state.phase {
        case .requestingCode:
            "Preparing Sign In"
        case .waitingForUser:
            "Enter This Code"
        case .exchanging:
            "Finishing Sign In"
        case .signedIn:
            "Signed In"
        case .failed:
            "Sign In Failed"
        case .idle:
            "Sign In With ChatGPT"
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .waitingForUser:
            "Open the OpenAI device page, sign in, and enter the code below."
        case .failed:
            "The ChatGPT sign-in flow did not complete."
        default:
            "Connect a ChatGPT account for the Codex-backed Hermes provider."
        }
    }
}

#if os(iOS)
private struct HermesChatGPTSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#endif

private extension View {
    @ViewBuilder
    func ifAvailableChatGPTGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.secondary.opacity(0.18))
                }
        }
    }
}
