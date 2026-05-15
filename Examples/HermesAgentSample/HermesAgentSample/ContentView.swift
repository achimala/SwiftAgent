import AgentKit
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

    @State private var draft = "Create a file named hello.txt that says hello from Hermes, then read it back."
    @State private var entries: [ChatEntry] = ChatTranscriptFormatter.welcomeEntries()
    @State private var isRunning = false
    @State private var showingSettings = false
    @State private var showingSessions = false
    @State private var sessions: [HermesSessionSummary] = []
    @State private var currentSessionID: String?
    @State private var timingEvents: [UUID: [TimingEvent]] = [:]
    @State private var activeReasoningEntries: [UUID: UUID] = [:]
    @State private var assistantIDsWithReasoning: Set<UUID> = []
    @FocusState private var draftFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                composer
            }
            .background(Color(uiColor: .systemBackground))
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
                    enableMemory: $enableMemory,
                    isRunning: isRunning,
                    onShellProbe: runShellProbe,
                    onHermesProbe: runProbe
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
            .onChange(of: entries) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Hermes", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .focused($draftFocused)
                    .disabled(isRunning)

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(.bar)
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

    private func loadCurrentSession() {
        let configuration = agentConfiguration
        Task.detached {
            do {
                let state = try HermesAgent(configuration: configuration).sessionState()
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
                let state = try HermesAgent(configuration: configuration).sessionState()
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
                let state = try HermesAgent(configuration: configuration).loadSession(sessionID)
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
                let state = try HermesAgent(configuration: configuration).newSession()
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
        timingEvents.removeAll()
        activeReasoningEntries.removeAll()
        assistantIDsWithReasoning.removeAll()
    }

    private func runProbe() {
        let configuration = agentConfiguration
        isRunning = true
        append(.status, title: "Probe", body: "Starting embedded Python and Hermes...")

        Task.detached {
            let text: String
            do {
                let agent = try HermesAgent(configuration: configuration)
                let result = try agent.probe()
                let toolProbe = try agent.toolProbe()
                text = """
                PYTHON
                \(result.python)

                HERMES
                \(result.hermes)

                HERMES TOOL DISPATCH
                \(toolProbe)
                """
            } catch {
                text = String(describing: error)
            }

            Self.writeProbeOutput(text)

            await MainActor.run {
                append(.debug, title: "Probe Output", body: Self.displayPreview(text))
                isRunning = false
            }
        }
    }

    private func runShellProbe() {
        isRunning = true
        append(.status, title: "Shell", body: "Running embedded shell smoke test...")

        Task.detached {
            let text: String
            do {
                text = try AgentKitISHShellEnvironment().smokeTest()
            } catch {
                text = String(describing: error)
            }

            Self.writeProbeOutput(text)

            await MainActor.run {
                append(.debug, title: "Shell Output", body: Self.displayPreview(text))
                isRunning = false
            }
        }
    }

    private func sendMessage() {
        let userMessage = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty else { return }

        draft = ""
        draftFocused = false
        append(.user, title: "You", body: userMessage)
        let assistantID = append(.assistant, title: "Hermes", body: "", isStreaming: true)
        timingEvents[assistantID] = []
        let config = agentConfiguration
        isRunning = true

        Task.detached {
            do {
                let agent = try HermesAgent(configuration: config)
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
                    appendTimingSummary(for: assistantID)
                    Self.writeProbeOutput(transcriptText)
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    finishAssistant(assistantID, fallback: "")
                    stopReasoningSpinner(for: assistantID)
                    append(.error, title: "Error", body: Self.displayText(for: error))
                    appendTimingSummary(for: assistantID)
                    Self.writeProbeOutput(transcriptText)
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
            recordTiming(event.payload, assistantID: assistantID)
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

    private func recordTiming(_ payload: String, assistantID: UUID) {
        guard let data = payload.data(using: .utf8),
              let timing = try? JSONDecoder().decode(TimingEvent.self, from: data)
        else { return }
        timingEvents[assistantID, default: []].append(timing)
    }

    private func appendTimingSummary(for assistantID: UUID) {
        guard let timings = timingEvents.removeValue(forKey: assistantID), !timings.isEmpty else { return }
        let body = timings
            .map { timing in
                let detail = timing.detail.map { " \($0)" } ?? ""
                return "\(ChatTranscriptFormatter.formatTimingLabel(timing.label)) \(ChatTranscriptFormatter.formatElapsed(timing.elapsedMs))\(detail)"
            }
            .joined(separator: "\n")
        append(.debug, title: "Timing", body: body)
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

    private var transcriptText: String {
        entries.map { entry in
            var parts = ["\(entry.title)\n\(entry.body)"]
            if let input = entry.toolInput, !input.isEmpty {
                parts.append("Input\n\(input)")
            }
            if let output = entry.toolOutput, !output.isEmpty {
                parts.append("Output\n\(output)")
            }
            return parts.joined(separator: "\n\n")
        }
        .joined(separator: "\n\n")
    }

    nonisolated private static func writeProbeOutput(_ text: String) {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let url = documents.appendingPathComponent("hermes-probe-output.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSLog("Hermes probe output written to %@", url.path)
        } catch {
            NSLog("Failed to write Hermes probe output: %@", String(describing: error))
        }
    }

    nonisolated private static func displayPreview(_ text: String, limit: Int = 20_000) -> String {
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]) + "\n\n... truncated in UI; full output was written to hermes-probe-output.txt"
    }

    nonisolated private static func displayText(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
