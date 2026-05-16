import AgentKit
import AgentKitFoundationModels
import AgentKitMLX
import SwiftUI

struct ContentView: View {
    @AppStorage("hermes.provider") private var provider = "hermes"
    @AppStorage("hermes.baseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("hermes.apiKey") private var apiKey = ""
    @AppStorage("hermes.model") private var model = "gpt-4.1-mini"
    @AppStorage("hermes.mlxModel") private var mlxModel = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit
    @AppStorage("hermes.mlxMaxTokens") private var mlxMaxTokens = 128
    @AppStorage("hermes.mlxTemperature") private var mlxTemperature = 0.2
    @AppStorage("hermes.enableSoul") private var enableSoul = true
    @AppStorage("hermes.enableContext") private var enableContext = true
    @AppStorage("hermes.enableMemory") private var enableMemory = true

    @State private var draft = ""
    @State private var entries: [ChatEntry] = ChatTranscriptFormatter.welcomeEntries()
    @State private var isRunning = false
    @State private var showingSettings = false
    @State private var showingSessions = false
    @State private var sessions: [HermesSessionSummary] = []
    @State private var currentSessionID: String?
    @State private var activeReasoningEntries: [UUID: UUID] = [:]
    @State private var assistantIDsWithReasoning: Set<UUID> = []
    @FocusState private var draftFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
            }
            .background(Color(uiColor: .systemBackground))
            .safeAreaInset(edge: .bottom) {
                composer
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
            .navigationTitle("Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        refreshSessions()
                        showingSessions = true
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .disabled(isRunning)
                    .accessibilityLabel("Sessions")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            createNewSession()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(isRunning)
                        .accessibilityLabel("New chat")

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .task {
                loadCurrentSession()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    provider: $provider,
                    baseURL: $baseURL,
                    apiKey: $apiKey,
                    model: $model,
                    mlxModel: $mlxModel,
                    mlxMaxTokens: $mlxMaxTokens,
                    mlxTemperature: $mlxTemperature,
                    enableSoul: $enableSoul,
                    enableContext: $enableContext,
                    enableMemory: $enableMemory
                )
            }
            .sheet(isPresented: $showingSessions) {
                SessionsView(
                    sessions: sessions,
                    currentSessionID: currentSessionID,
                    isRunning: isRunning,
                    onRefresh: refreshSessions,
                    onNewSession: {
                        showingSessions = false
                        createNewSession()
                    },
                    onSelect: { session in
                        showingSessions = false
                        loadSession(session.id)
                    }
                )
            }
        }
    }

    private var transcript: some View {
        ZStack {
            if entries.isEmpty {
                EmptyChatView { prompt in
                    draft = prompt
                    draftFocused = true
                }
                .padding(.horizontal, 22)
                .transition(.opacity)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            ChatRow(entry: entry)
                                .id(entry.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.top, 28)
                    .padding(.bottom, 12)
                }
                .opacity(entries.isEmpty ? 0 : 1)
                .onChange(of: entries) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    @ViewBuilder
    private var composer: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 0) {
                composerField
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
        } else {
            composerField
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator).opacity(0.18))
                }
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
        }
    }

    private var composerField: some View {
        ZStack(alignment: .bottomTrailing) {
            TextField("Message Hermes", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit {
                    if canSend {
                        sendMessage()
                    }
                }
                .padding(.vertical, 15)
                .padding(.leading, 18)
                .padding(.trailing, 56)
                .focused($draftFocused)
                .disabled(isRunning)

            sendButton
                .padding(.trailing, 8)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var sendButton: some View {
        Button {
            sendMessage()
        } label: {
            sendButtonLabel
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .accessibilityLabel("Send message")
    }

    private var sendButtonLabel: some View {
        Image(systemName: "arrow.up")
            .font(.system(size: 16, weight: .bold))
            .frame(width: 36, height: 36)
            .foregroundStyle(canSend ? .white : .secondary)
            .background(canSend ? Color.accentColor : Color(uiColor: .tertiarySystemFill), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(canSend ? 0.24 : 0.12))
            }
            .ifAvailableGlass(in: Circle())
    }

    private var agentConfiguration: HermesAgentConfiguration {
        if usesLocalMLX {
            return .localMLX(
                model: mlxModel,
                maxTokens: mlxMaxTokens,
                temperature: mlxTemperature,
                enableSoul: enableSoul,
                enableContext: enableContext,
                enableMemory: enableMemory
            )
        }

        if usesFoundationModels {
            if #available(iOS 26.0, *) {
                return .foundationModels(
                    maxTokens: mlxMaxTokens,
                    temperature: mlxTemperature,
                    enableSoul: enableSoul,
                    enableContext: enableContext,
                    enableMemory: enableMemory
                )
            }
            return .openAI(
                apiKey: apiKey,
                model: model,
                baseURL: baseURL,
                enableSoul: enableSoul,
                enableContext: enableContext,
                enableMemory: enableMemory
            )
        }

        return .openAI(
            apiKey: apiKey,
            model: model,
            baseURL: baseURL,
            enableSoul: enableSoul,
            enableContext: enableContext,
            enableMemory: enableMemory
        )
    }

    private var usesLocalMLX: Bool {
        provider == "mlx"
    }

    private var usesFoundationModels: Bool {
        provider == "foundation"
    }

    nonisolated private static func makeAgent(configuration: HermesAgentConfiguration) throws -> HermesAgent {
        if configuration.baseURL.hasPrefix("hermes-foundation-models://") {
            if #available(iOS 26.0, *) {
                return try HermesAgent(
                    configuration: configuration,
                    sourceURL: HermesAgent.bundledSourceURL(),
                    executionMode: .inProcess,
                    modelProvider: AgentKitFoundationModelsProvider()
                )
            }
        }

        if configuration.baseURL.hasPrefix("hermes-local-mlx://") {
            return try HermesAgent(
                configuration: configuration,
                sourceURL: HermesAgent.bundledSourceURL(),
                executionMode: .inProcess,
                modelProvider: AgentKitMLXModelProvider()
            )
        }

        if #available(iOS 26.0, *) {
            return try HermesAgent(
                configuration: configuration,
                sourceURL: HermesAgent.bundledSourceURL(),
                backend: HermesExtensionProcessBackend(appExtensionPoint: .agentKitHermesWorker)
            )
        }

        return try HermesAgent(configuration: configuration)
    }

    private func loadCurrentSession() {
        let configuration = agentConfiguration
        Task.detached {
            do {
                let state = try Self.makeAgent(configuration: configuration).sessionState()
                await MainActor.run {
                    applySessionState(state, renderTranscript: true)
                }
            } catch {
                await MainActor.run {
                    _ = append(.error, title: "Session Error", body: String(describing: error))
                }
            }
        }
    }

    private func refreshSessions() {
        let configuration = agentConfiguration
        Task.detached {
            do {
                let state = try Self.makeAgent(configuration: configuration).sessionState()
                await MainActor.run {
                    applySessionState(state, renderTranscript: false)
                }
            } catch {
                await MainActor.run {
                    _ = append(.error, title: "Session Error", body: String(describing: error))
                }
            }
        }
    }

    private func loadSession(_ sessionID: String) {
        let configuration = agentConfiguration
        isRunning = true
        Task.detached {
            do {
                let state = try Self.makeAgent(configuration: configuration).loadSession(sessionID)
                await MainActor.run {
                    applySessionState(state, renderTranscript: true)
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    append(.error, title: "Session Error", body: String(describing: error))
                    isRunning = false
                }
            }
        }
    }

    private func createNewSession() {
        let configuration = agentConfiguration
        isRunning = true
        Task.detached {
            do {
                let state = try Self.makeAgent(configuration: configuration).newSession()
                await MainActor.run {
                    applySessionState(state, renderTranscript: true)
                    draft = ""
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    append(.error, title: "Session Error", body: String(describing: error))
                    isRunning = false
                }
            }
        }
    }

    @MainActor
    private func applySessionState(_ state: HermesSessionState, renderTranscript: Bool) {
        currentSessionID = state.currentSessionID
        sessions = state.sessions
        guard renderTranscript else { return }

        entries = ChatTranscriptFormatter.entries(from: state.currentSession)
        activeReasoningEntries.removeAll()
        assistantIDsWithReasoning.removeAll()
    }

    private func sendMessage() {
        let userMessage = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty else { return }

        draft = ""
        draftFocused = false
        append(.user, title: "You", body: userMessage)
        let assistantID = append(.assistant, title: "Hermes", body: "", isStreaming: true)
        let config = agentConfiguration
        isRunning = true

        Task.detached {
            do {
                let agent = try Self.makeAgent(configuration: config)
                let final = try agent.send(userMessage) { event in
                    Task { @MainActor in
                        handle(event: event, assistantID: assistantID)
                    }
                }

                await MainActor.run {
                    let result = ChatTranscriptFormatter.chatResult(from: final)
                    finishAssistant(assistantID, fallback: ChatTranscriptFormatter.finalResponse(from: result, raw: final))
                    appendFinalReasoning(result?.lastReasoning, assistantID: assistantID)
                    stopReasoningSpinner(for: assistantID)
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    finishAssistant(assistantID, fallback: "")
                    stopReasoningSpinner(for: assistantID)
                    append(.error, title: "Error", body: Self.displayText(for: error))
                    isRunning = false
                }
            }
        }
    }

    @discardableResult
    private func append(
        _ kind: ChatEntry.Kind,
        title: String,
        body: String,
        isStreaming: Bool = false
    ) -> UUID {
        let entry = ChatEntry(kind: kind, title: title, body: body, isStreaming: isStreaming)
        entries.append(entry)
        return entry.id
    }

    @MainActor
    private func handle(event: AgentKitEvent, assistantID: UUID) {
        switch event.kind {
        case "delta":
            endActiveReasoningChunk(for: assistantID)
            appendToAssistant(assistantID, text: event.payload)
        case "interim":
            endActiveReasoningChunk(for: assistantID)
            append(.assistant, title: "Hermes", body: event.payload)
        case "reasoning_delta":
            appendReasoning(event.payload, assistantID: assistantID)
        case "tool_gen":
            endActiveReasoningChunk(for: assistantID)
        case "tool_start":
            endActiveReasoningChunk(for: assistantID)
            if let tool = ChatTranscriptFormatter.decodeToolEvent(event.payload) {
                appendToolStart(tool)
            } else {
                append(.tool, title: "Running tool", body: event.payload)
            }
            moveEmptyAssistantToEnd(assistantID)
        case "tool_complete":
            endActiveReasoningChunk(for: assistantID)
            if let tool = ChatTranscriptFormatter.decodeToolEvent(event.payload) {
                finishTool(tool)
            } else {
                append(.tool, title: "Tool finished", body: event.payload)
            }
            moveEmptyAssistantToEnd(assistantID)
        case "tool_progress":
            endActiveReasoningChunk(for: assistantID)
        case "timing":
            break
        case "done":
            stopAssistantSpinner(assistantID)
            stopReasoningSpinner(for: assistantID)
        case "error":
            append(.error, title: "Hermes Error", body: event.payload)
        default:
            append(.status, title: event.kind, body: event.payload)
        }
    }

    private func moveEmptyAssistantToEnd(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let body = entries[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entries[index].isStreaming, body.isEmpty, index != entries.index(before: entries.endIndex) else { return }
        let entry = entries.remove(at: index)
        entries.append(entry)
    }

    private func appendToolStart(_ tool: ToolEvent) {
        let name = tool.name ?? "tool"
        let input = ChatTranscriptFormatter.formatToolInput(tool)
        let entry = ChatEntry(
            kind: .tool,
            title: ChatTranscriptFormatter.displayToolName(name),
            body: "",
            isStreaming: true,
            toolCallID: tool.id,
            toolName: name,
            toolInput: input.isEmpty ? nil : input,
            toolOutput: nil,
            toolSucceeded: nil
        )
        entries.append(entry)
    }

    private func finishTool(_ tool: ToolEvent) {
        let name = tool.name ?? "tool"
        let output = ChatTranscriptFormatter.formatToolResult(tool)
        let ok = tool.ok ?? true
        if let id = tool.id, let index = entries.lastIndex(where: { $0.toolCallID == id }) {
            entries[index].title = ChatTranscriptFormatter.displayToolName(name)
            entries[index].toolName = name
            entries[index].toolOutput = output
            entries[index].toolSucceeded = ok
            entries[index].isStreaming = false
            return
        }

        let entry = ChatEntry(
            kind: .tool,
            title: ChatTranscriptFormatter.displayToolName(name),
            body: "",
            isStreaming: false,
            toolCallID: tool.id,
            toolName: name,
            toolInput: nil,
            toolOutput: output,
            toolSucceeded: ok
        )
        entries.append(entry)
    }

    private func appendToAssistant(_ id: UUID, text: String) {
        guard !text.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].body += text
    }

    private func appendReasoning(_ text: String, assistantID: UUID) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assistantIDsWithReasoning.insert(assistantID)

        if let reasoningID = activeReasoningEntries[assistantID],
           let index = entries.firstIndex(where: { $0.id == reasoningID }) {
            entries[index].body += text
            entries[index].isStreaming = true
            return
        }

        let reasoningID = append(
            .reasoning,
            title: "Reasoning summary",
            body: text.trimmingCharacters(in: .whitespacesAndNewlines),
            isStreaming: true
        )
        activeReasoningEntries[assistantID] = reasoningID
        moveEmptyAssistantToEnd(assistantID)
    }

    private func appendFinalReasoning(_ text: String?, assistantID: UUID) {
        let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty, !assistantIDsWithReasoning.contains(assistantID) else { return }

        if let reasoningID = activeReasoningEntries[assistantID],
           let index = entries.firstIndex(where: { $0.id == reasoningID }) {
            entries[index].body = cleaned
            entries[index].isStreaming = false
            return
        }

        let entry = ChatEntry(
            kind: .reasoning,
            title: "Reasoning summary",
            body: cleaned,
            isStreaming: false
        )
        if let assistantIndex = entries.firstIndex(where: { $0.id == assistantID }) {
            entries.insert(entry, at: assistantIndex)
        } else {
            entries.append(entry)
        }
        activeReasoningEntries[assistantID] = entry.id
        assistantIDsWithReasoning.insert(assistantID)
    }

    private func stopReasoningSpinner(for assistantID: UUID) {
        guard let reasoningID = activeReasoningEntries[assistantID],
              let index = entries.firstIndex(where: { $0.id == reasoningID })
        else { return }
        entries[index].isStreaming = false
        activeReasoningEntries.removeValue(forKey: assistantID)
    }

    private func endActiveReasoningChunk(for assistantID: UUID) {
        stopReasoningSpinner(for: assistantID)
    }

    private func finishAssistant(_ id: UUID, fallback: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries[index].body = fallback.isEmpty ? "(no response text)" : fallback
        } else {
            entries[index].body = entries[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        entries[index].isStreaming = false
    }

    private func stopAssistantSpinner(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isStreaming = false
    }

    nonisolated private static func displayText(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}

private struct EmptyChatView: View {
    let onPromptSelected: (String) -> Void

    private let prompts = [
        "Create hello.txt and read it back.",
        "List the workspace files.",
        "Draft an AGENTS.md for this app sandbox.",
    ]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text("What should Hermes do?")
                    .font(.title2.weight(.semibold))

                Text("Start with a small workspace task.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        onPromptSelected(prompt)
                    } label: {
                        HStack(spacing: 10) {
                            Text(prompt)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color(uiColor: .separator).opacity(0.16))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 430)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 40)
    }
}

private extension View {
    @ViewBuilder
    func ifAvailableGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self
        }
    }
}
