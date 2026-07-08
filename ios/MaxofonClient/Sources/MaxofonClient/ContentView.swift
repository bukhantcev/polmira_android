import SwiftUI

struct ContentView: View {
    @State private var session: MaxofonSession?
    @State private var unlocked = false
    @State private var pastedMessage = ""
    @State private var manualURL = ""
    @State private var manualUsername = ""
    @State private var manualPassword = ""
    @State private var errorText = ""
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView()
            } else if let session, unlocked {
                WebSessionView(session: session, reset: resetSession)
            } else if session != nil {
                UnlockView(errorText: $errorText, unlock: unlock)
            } else {
                PasteSetupView(
                    pastedMessage: $pastedMessage,
                    manualURL: $manualURL,
                    manualUsername: $manualUsername,
                    manualPassword: $manualPassword,
                    errorText: $errorText,
                    savePasted: savePastedSession,
                    saveManual: saveManualSession
                )
            }
        }
        .task {
            loadSavedSession()
        }
    }

    private func loadSavedSession() {
        defer { loading = false }

        do {
            session = try KeychainStore.shared.loadSession()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func savePastedSession() {
        do {
            let parsed = try MessageParser.parse(pastedMessage)
            saveSession(parsed)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveManualSession() {
        do {
            let parsed = try MaxofonSession.fromManualInput(
                urlText: manualURL,
                username: manualUsername,
                password: manualPassword
            )
            saveSession(parsed)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveSession(_ parsed: MaxofonSession) {
        do {
            try KeychainStore.shared.saveSession(parsed)
            session = parsed
            pastedMessage = ""
            manualURL = ""
            manualUsername = ""
            manualPassword = ""
            errorText = ""
            Task { await unlock() }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func unlock() async {
        do {
            unlocked = try await BiometricGate.unlock()
            errorText = ""
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func resetSession() {
        do {
            try KeychainStore.shared.deleteSession()
        } catch {
            errorText = error.localizedDescription
        }

        session = nil
        unlocked = false
    }
}

private struct PasteSetupView: View {
    @Binding var pastedMessage: String
    @Binding var manualURL: String
    @Binding var manualUsername: String
    @Binding var manualPassword: String
    @Binding var errorText: String
    let savePasted: () -> Void
    let saveManual: () -> Void

    private var canSaveManual: Bool {
        !manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !manualUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !manualPassword.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedMessage)
                        .frame(minHeight: 220)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Вставь сообщение из Maxofon")
                }

                Section {
                    TextField("Ссылка", text: $manualURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Логин", text: $manualUsername)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Пароль", text: $manualPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Или введи вручную")
                }

                if !errorText.isEmpty {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Сохранить из сообщения", action: savePasted)
                        .disabled(pastedMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Сохранить ручной ввод", action: saveManual)
                        .disabled(!canSaveManual)
                }
            }
            .navigationTitle("Maxofon")
        }
    }
}

private struct UnlockView: View {
    @Binding var errorText: String
    let unlock: () async -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Открыть Maxofon")
                .font(.title2.bold())

            Button("Разблокировать") {
                Task { await unlock() }
            }
            .buttonStyle(.borderedProminent)

            if !errorText.isEmpty {
                Text(errorText)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
        .task {
            await unlock()
        }
    }
}

private struct WebSessionView: View {
    let session: MaxofonSession
    let reset: () -> Void
    @State private var keyboardVisible = false
    @State private var keyboardRequest = 0
    @State private var composedText = ""
    @State private var composedTextRevision = 0
    @State private var submitTextRevision = 0
    @State private var suppressNextComposedTextSync = false
    @FocusState private var composedTextFocused: Bool

    var body: some View {
        MaxWebView(
            session: session,
            keyboardRequest: keyboardRequest,
            keyboardVisible: keyboardVisible,
            composedText: composedText,
            composedTextRevision: composedTextRevision,
            submitTextRevision: submitTextRevision
        )
            .ignoresSafeArea()
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .top) {
                if keyboardVisible {
                    HStack(spacing: 10) {
                        TextField("Ввод", text: $composedText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.send)
                            .focused($composedTextFocused)
                            .onSubmit {
                                guard !composedText.isEmpty else { return }
                                submitTextRevision += 1
                                suppressNextComposedTextSync = true
                                composedText = ""
                            }

                        Button {
                            composedTextFocused = false
                            keyboardVisible = false
                            keyboardRequest += 1
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 36, height: 36)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.async {
                            composedTextFocused = true
                        }
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                Menu {
                    Button("Сбросить настройки", role: .destructive, action: reset)
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title2)
                        .padding(12)
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                }
            }
            .overlay(alignment: .bottom) {
                if !keyboardVisible {
                    Button {
                        keyboardVisible = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            composedTextFocused = true
                        }
                    } label: {
                        Image(systemName: "keyboard")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 44)
                            .background(.black.opacity(0.62), in: Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(.white.opacity(0.22), lineWidth: 1)
                            )
                            .shadow(radius: 8)
                    }
                    .padding(.bottom, 18)
                }
            }
            .onChange(of: keyboardVisible) { visible in
                if visible {
                    DispatchQueue.main.async {
                        composedTextFocused = true
                    }
                } else {
                    composedTextFocused = false
                    keyboardRequest += 1
                }
            }
            .onChange(of: composedText) { _ in
                if suppressNextComposedTextSync {
                    suppressNextComposedTextSync = false
                    return
                }
                composedTextRevision += 1
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                if keyboardVisible {
                    keyboardVisible = false
                }
            }
    }
}
