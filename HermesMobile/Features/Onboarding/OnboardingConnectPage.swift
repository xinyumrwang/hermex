import SwiftUI

enum OnboardingConnectField: Hashable {
    case serverURL
    case password
}

struct OnboardingConnectPage: View {
    @Bindable var viewModel: OnboardingViewModel
    @Bindable var authManager: AuthManager
    @FocusState.Binding var focusedField: OnboardingConnectField?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingAdvanced = false

    private var canSubmit: Bool {
        !viewModel.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitConnection() {
        guard canSubmit else { return }
        Task { await viewModel.connect(authManager: authManager) }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Server", selection: $viewModel.serverKind) {
                    ForEach(ServerKind.allCases, id: \.self) { kind in
                        Text(verbatim: kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isConnectionLocked)
                .accessibilityLabel("Server")

                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    Text(viewModel.serverKind == .craft
                         ? "Connect directly to a Craft RPC server with its WebSocket URL and server token. Local development may use `ws://127.0.0.1:9100`."
                         : "Enter the exact HTTPS Tailscale Serve URL your agent returned, for example `https://server.tailnet-name.ts.net`.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    OnboardingField(systemImage: "link", title: String(localized: "Server URL")) {
                        ZStack(alignment: .leading) {
                            if viewModel.serverURLString.isEmpty {
                                Text(verbatim: viewModel.serverKind == .craft
                                     ? "ws://127.0.0.1:9100"
                                     : "https://server.tailnet-name.ts.net")
                                    .foregroundStyle(.white.opacity(0.38))
                                    .allowsHitTesting(false)
                            }

                            TextField("", text: $viewModel.serverURLString)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .foregroundStyle(.white)
                                .submitLabel(.go)
                                .tint(Color(red: 1.0, green: 0.74, blue: 0.10))
                                .focused($focusedField, equals: .serverURL)
                                .disabled(viewModel.isConnectionLocked)
                                .onSubmit { guard !viewModel.isConnectionLocked else { return }; submitConnection() }
                        }
                    }

                    if viewModel.isPasswordRequired {
                        OnboardingField(
                            systemImage: "key.fill",
                            title: viewModel.serverKind == .craft ? "Server Token" : String(localized: "Password")
                        ) {
                            SecureField(
                                "",
                                text: $viewModel.password,
                                prompt: Text(viewModel.serverKind == .craft ? "Craft server token" : "Server password")
                                    .foregroundStyle(.white.opacity(0.38))
                            )
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .disabled(viewModel.isConnectionLocked)
                            .onSubmit { guard !viewModel.isConnectionLocked else { return }; submitConnection() }
                        }
                    }
                }

                if viewModel.serverKind == .hermes {
                    DisclosureGroup(isExpanded: $isShowingAdvanced) {
                        CustomHeadersEditor(headers: $viewModel.customHeaders, style: .onboarding)
                            .disabled(viewModel.isConnectionLocked)
                            .padding(.top, 10)
                    } label: {
                        Label("Advanced", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .tint(.white.opacity(0.6))
                }

                if viewModel.isWorking {
                    OnboardingStatusBanner(
                        text: String(localized: "Checking server..."),
                        systemImage: "arrow.triangle.2.circlepath",
                        tint: .white.opacity(0.7),
                        showsProgress: true
                    )
                }

                if let connectionMessage = viewModel.connectionMessage {
                    OnboardingStatusBanner(
                        text: connectionMessage,
                        systemImage: "checkmark.circle.fill",
                        tint: Color(red: 0.45, green: 0.92, blue: 0.56)
                    )
                }

                if let errorMessage = viewModel.errorMessage {
                    OnboardingStatusBanner(
                        text: errorMessage,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Color(red: 1.0, green: 0.47, blue: 0.34)
                    )
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? 18 : 24)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
