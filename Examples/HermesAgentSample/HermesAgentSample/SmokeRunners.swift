import AgentKit
import AgentKitFoundationModels
import AgentKitMLX
import Foundation

enum SampleSmokeRunners {
    static func runIfRequested() async {
        await LocalMLXSmokeRunner.runIfRequested()
        await HermesLocalMLXSmokeRunner.runIfRequested()
        await HermesNewSessionSmokeRunner.runIfRequested()
        await HermesMLXSessionCycleSmokeRunner.runIfRequested()
        await HermesMLXStressSmokeRunner.runIfRequested()
        await HermesMLXToolSmokeRunner.runIfRequested()
        await FoundationModelsProviderSmokeRunner.runIfRequested()
        await HermesFoundationModelsSmokeRunner.runIfRequested()
        await HermesFoundationModelsToolSmokeRunner.runIfRequested()
        await AgentKitISHSmokeRunner.runIfRequested()
        await HermesExtensionProbeSmokeRunner.runIfRequested()
    }
}

private enum FoundationModelsProviderSmokeRunner {
    private static let argument = "--foundation-models-provider-smoke"

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "foundation-models-provider-smoke.log")
        await recorder.write("start")

        do {
            guard #available(iOS 26.0, *) else {
                await recorder.write("done skipped=requires-ios-26")
                return
            }

            let request: [String: Any] = [
                "model": AgentKitFoundationModels.modelIdentifier,
                "messages": [
                    [
                        "role": "user",
                        "content": "In one short sentence, say Apple Foundation Models direct provider smoke is working.",
                    ],
                ],
                "tools": [],
                "max_tokens": 48,
                "temperature": 0.1,
                "stream": true,
            ]
            let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
            let rawJSON = String(decoding: data, as: UTF8.self)
            let provider = AgentKitFoundationModelsProvider()
            let result = try await provider.complete(
                request: AgentKitModelRequest(rawJSON: rawJSON)
            ) { event in
                Task {
                    await recorder.write("event kind=\(event.kind) payload=\(event.payload)")
                }
            }
            await recorder.write("result \(result)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum LocalMLXSmokeRunner {
    private static let argument = "--local-mlx-smoke"
    private static let modelID = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit
    private static let prompt = "In one short sentence, say that local MLX inference is working on iPhone."

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-local-mlx-smoke.log")
        await recorder.write("start model=\(modelID)")

        do {
            let result = try await AgentKitMLXModelProvider().chat(
                message: prompt,
                configuration: .init(modelID: modelID, maxTokens: 48, temperature: 0.1)
            ) { event in
                Task {
                    await recorder.write("event kind=\(event.kind) payload=\(event.payload)")
                }
            }

            await recorder.write("result \(result)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum HermesLocalMLXSmokeRunner {
    private static let argument = "--hermes-local-mlx-smoke"
    private static let modelID = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit
    private static let prompt = "In one short sentence, say whether Hermes is running through a local MLX model."

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-e2e-mlx-smoke.log")
        await recorder.write("start model=\(modelID)")

        do {
            let agent = try LocalMLXAgentFactory.make(
                configuration: .localMLX(model: modelID, maxTokens: 64, temperature: 0.1)
            )
            let result = try agent.send(prompt) { event in
                Task {
                    await recorder.write("event kind=\(event.kind) payload=\(event.payload)")
                }
            }

            await recorder.write("result \(result)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum HermesNewSessionSmokeRunner {
    private static let argument = "--hermes-new-session-smoke"

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-new-session-smoke.log")
        await recorder.write("start")

        do {
            let agent = try LocalMLXAgentFactory.make(configuration: .localMLX())
            let before = try agent.sessionState()
            await recorder.write("before current=\(before.currentSessionID ?? "nil") sessions=\(before.sessions.count)")
            let state = try agent.newSession()
            await recorder.write("after current=\(state.currentSessionID ?? "nil") sessions=\(state.sessions.count)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum HermesMLXSessionCycleSmokeRunner {
    private static let argument = "--hermes-mlx-session-cycle-smoke"
    private static let modelID = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-mlx-session-cycle-smoke.log")
        await recorder.write("start model=\(modelID)")

        let configuration = HermesAgentConfiguration.localMLX(
            model: modelID,
            maxTokens: 48,
            temperature: 0.1,
            enableSoul: true,
            enableContext: true,
            enableMemory: true
        )

        do {
            let agent = try LocalMLXAgentFactory.make(configuration: configuration)
            let first = try agent.send("Reply with exactly: first ok") { event in
                Task {
                    await recorder.write("first event kind=\(event.kind) payload=\(event.payload)")
                }
            }
            await recorder.write("first result \(first)")

            let state = try agent.newSession()
            await recorder.write("new session current=\(state.currentSessionID ?? "nil")")

            let second = try agent.send("Reply with exactly: second ok") { event in
                Task {
                    await recorder.write("second event kind=\(event.kind) payload=\(event.payload)")
                }
            }
            await recorder.write("second result \(second)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum HermesMLXStressSmokeRunner {
    private static let argument = "--hermes-mlx-stress-smoke"
    private static let modelID = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-mlx-stress-smoke.log")
        await recorder.write("start model=\(modelID)")

        let configuration = HermesAgentConfiguration.localMLX(
            model: modelID,
            maxTokens: 48,
            temperature: 0.1,
            enableSoul: true,
            enableContext: true,
            enableMemory: true
        )

        do {
            let agent = try LocalMLXAgentFactory.make(configuration: configuration)
            for index in 1...4 {
                let result = try agent.send("Reply with exactly: turn \(index) ok") { event in
                    if event.kind == "timing" || event.kind == "done" {
                        Task {
                            await recorder.write("turn \(index) event kind=\(event.kind) payload=\(event.payload)")
                        }
                    }
                }
                await recorder.write("turn \(index) result \(result)")
            }

            let state = try agent.newSession()
            await recorder.write("new session current=\(state.currentSessionID ?? "nil")")

            for index in 5...6 {
                let result = try agent.send("Reply with exactly: turn \(index) ok") { event in
                    if event.kind == "timing" || event.kind == "done" {
                        Task {
                            await recorder.write("turn \(index) event kind=\(event.kind) payload=\(event.payload)")
                        }
                    }
                }
                await recorder.write("turn \(index) result \(result)")
            }

            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum HermesMLXToolSmokeRunner {
    private static let argument = "--hermes-mlx-tool-smoke"
    private static let modelID = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-mlx-tool-smoke.log")
        await recorder.write("start model=\(modelID)")

        let configuration = HermesAgentConfiguration.localMLX(
            model: modelID,
            maxTokens: 192,
            temperature: 0,
            enableSoul: false,
            enableContext: false,
            enableMemory: false
        )

        do {
            let agent = try LocalMLXAgentFactory.make(configuration: configuration)
            _ = try agent.newSession()
            let result = try agent.send("Use the file tools to create tool-smoke.txt containing exactly local mlx tool smoke, then read the file back and answer with its contents.") { event in
                Task {
                    await recorder.write("event kind=\(event.kind) payload=\(event.payload)")
                }
            }
            await recorder.write("result \(result)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum AgentKitISHSmokeRunner {
    private static let argument = "--hermes-ish-smoke"

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-ish-smoke.log")
        await recorder.write("start")

        do {
            let workspace = try HermesAgent.defaultWorkspace()
                .appendingPathComponent("LaunchArgISHShellSmoke", isDirectory: true)
            try? FileManager.default.removeItem(at: workspace)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

            let shell = AgentKitISHShellEnvironment()
            let first = try shell.run(
                "echo launch-ish-ok > launch.txt && cat launch.txt",
                cwd: workspace
            )
            await recorder.write("first status=\(first.status) output=\(first.output)")

            let second = try shell.run(
                "python3 -c 'print(654)' && rg launch-ish .",
                cwd: workspace
            )
            await recorder.write("second status=\(second.status) output=\(second.output)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum LocalMLXAgentFactory {
    static func make(configuration: HermesAgentConfiguration) throws -> HermesAgent {
        try HermesAgent(
            configuration: configuration,
            sourceURL: HermesAgent.bundledSourceURL(),
            executionMode: .inProcess,
            modelProvider: AgentKitMLXModelProvider()
        )
    }
}

private enum HermesFoundationModelsSmokeRunner {
    private static let argument = "--hermes-foundation-models-smoke"

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-foundation-models-smoke.log")
        await recorder.write("start")

        do {
            guard #available(iOS 26.0, *) else {
                await recorder.write("done skipped=requires-ios-26")
                return
            }

            let agent = try HermesAgent(
                configuration: .foundationModels(
                    maxTokens: 160,
                    temperature: 0.1,
                    enableSoul: false,
                    enableContext: false,
                    enableMemory: false
                ),
                sourceURL: HermesAgent.bundledSourceURL(),
                executionMode: .inProcess,
                modelProvider: AgentKitFoundationModelsProvider()
            )
            _ = try agent.newSession()
            let result = try agent.send("Reply exactly: Hermes is running through Apple Foundation Models.") { event in
                Task {
                    await recorder.write("event kind=\(event.kind) payload=\(event.payload)")
                }
            }
            await recorder.write("result \(result)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum HermesFoundationModelsToolSmokeRunner {
    private static let argument = "--hermes-foundation-models-tool-smoke"

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-foundation-models-tool-smoke.log")
        await recorder.write("start")

        do {
            guard #available(iOS 26.0, *) else {
                await recorder.write("done skipped=requires-ios-26")
                return
            }

            let agent = try HermesAgent(
                configuration: .foundationModels(
                    maxTokens: 256,
                    temperature: 0,
                    enableSoul: false,
                    enableContext: false,
                    enableMemory: false
                ),
                sourceURL: HermesAgent.bundledSourceURL(),
                executionMode: .inProcess,
                modelProvider: AgentKitFoundationModelsProvider()
            )
            _ = try agent.newSession()
            let result = try agent.send("Use the file tools to create apple-foundation-smoke.txt containing exactly apple foundation tool smoke, then read it back and answer with its contents.") { event in
                Task {
                    await recorder.write("event kind=\(event.kind) payload=\(event.payload)")
                }
            }
            await recorder.write("result \(result)")
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private enum HermesExtensionProbeSmokeRunner {
    private static let argument = "--hermes-extension-probe-smoke"

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(argument) else { return }

        let recorder = SmokeRecorder(filename: "hermes-extension-probe-smoke.log")
        await recorder.write("start")

        do {
            guard #available(iOS 26.0, *) else {
                await recorder.write("done skipped=requires-ios-26")
                return
            }

            let agent = try HermesAgent(
                configuration: .openAI(apiKey: "probe-key", model: "probe-model"),
                sourceURL: HermesAgent.bundledSourceURL(),
                backend: HermesExtensionProcessBackend(appExtensionPoint: .agentKitHermesWorker)
            )
            let result = try agent.probe()
            await recorder.write("python \(result.python)")
            await recorder.write("hermes \(result.hermes)")
            let toolProbe = try agent.toolProbe()
            await recorder.write("toolProbe \(toolProbe)")
            let sessionState = try agent.newSession()
            await recorder.write(
                "newSession current=\(sessionState.currentSessionID ?? "nil") sessions=\(sessionState.sessions.count)"
            )
            await recorder.write("done ok")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await recorder.write("done error=\(message)")
        }
    }
}

private actor SmokeRecorder {
    private let url: URL

    init(filename: String) {
        let documents = try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.url = (documents ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent(filename)
    }

    func write(_ line: String) {
        let text = "\(Date().ISO8601Format()) \(line)\n"
        if let data = text.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url)
            {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: [.atomic])
            }
        }
        NSLog("AgentKit smoke: %@", line)
    }
}
