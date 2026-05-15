import HermesAgentKit
import SwiftUI

struct ContentView: View {
    @State private var baseURL = "https://api.openai.com/v1"
    @State private var apiKey = ""
    @State private var model = "dummy-model"
    @State private var message = "Say hello from Hermes on iOS."
    @State private var output = "Ready"
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 8) {
                    Button {
                        runProbe()
                    } label: {
                        Label("Probe", systemImage: "bolt.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)

                    Button {
                        runShellProbe()
                    } label: {
                        Label("Shell", systemImage: "terminal")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRunning)

                    Button {
                        sendMessage()
                    } label: {
                        Label(isRunning ? "Running" : "Send", systemImage: "paperplane")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                TextField("Message", text: $message, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRunning)

                ScrollView {
                    Text(output)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding()
            .navigationTitle("Hermes Agent")
        }
    }

    private var configuration: HermesChatConfiguration {
        HermesChatConfiguration(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    private var hermesPath: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("PythonApp", isDirectory: true)
            .appendingPathComponent("hermes", isDirectory: true)
    }

    private func runProbe() {
        let path = hermesPath
        isRunning = true
        output = "Starting embedded Python..."

        Task.detached {
            let text: String
            do {
                let result = try HermesAgentRuntime.shared.probe(hermesSourcePath: path)
                let toolProbe = try HermesAgentRuntime.shared.toolProbe(hermesSourcePath: path)
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
                output = text
                isRunning = false
            }
        }
    }

    private func runShellProbe() {
        isRunning = true
        output = "Starting embedded shell..."

        Task.detached {
            let text: String
            do {
                text = try HermesShellRuntime.shared.smokeTest()
            } catch {
                text = String(describing: error)
            }

            Self.writeProbeOutput(text)

            await MainActor.run {
                output = text
                isRunning = false
            }
        }
    }

    private func sendMessage() {
        guard let hermesPath else {
            output = "Missing bundled Hermes source."
            return
        }

        let userMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = configuration

        isRunning = true
        output += "\n\nUSER\n\(userMessage)\n\nHERMES STREAM\n"

        Task.detached {
            do {
                let final = try HermesAgentRuntime.shared.chat(
                    message: userMessage,
                    configuration: config,
                    hermesSourcePath: hermesPath
                ) { event in
                    Task { @MainActor in
                        append(event: event)
                    }
                }

                await MainActor.run {
                    output += "\n\nHERMES FINAL\n\(final)"
                    Self.writeProbeOutput(output)
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    output += "\n\nERROR\n\(String(describing: error))"
                    Self.writeProbeOutput(output)
                    isRunning = false
                }
            }
        }
    }

    @MainActor
    private func append(event: HermesChatEvent) {
        switch event.kind {
        case "delta":
            output += event.payload
        case "status":
            output += "[\(event.payload)]\n"
        case "done":
            output += "\n[done]"
        case "error":
            output += "\n[error]\n\(event.payload)"
        default:
            output += "\n[\(event.kind)] \(event.payload)"
        }
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
}
