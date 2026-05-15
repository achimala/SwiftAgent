import AgentKit
import Foundation
import XCTest

final class AgentKitAbstractionsTests: XCTestCase {
    func testMockShellRecordsCommands() throws {
        let shell = AgentKitMockShellEnvironment { command in
            AgentKitShellResult(command: command.command, output: "ran \(command.command)", status: 0)
        }

        let result = try shell.run("pwd", cwd: URL(fileURLWithPath: "/tmp"), environment: ["A": "B"])

        XCTAssertEqual(result.output, "ran pwd")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(shell.commands.map(\.command), ["pwd"])
        XCTAssertEqual(shell.commands.first?.environment["A"], "B")
    }

    func testMockModelProviderEmitsRequestEvent() async throws {
        let provider = AgentKitMockModelProvider { request in
            #"{"echo":\#(request.rawJSON)}"#
        }
        let events = EventRecorder()

        let output = try await provider.complete(
            request: AgentKitModelRequest(rawJSON: #"{"messages":[]}"#)
        ) { event in
            events.append(event)
        }

        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.rawJSON), [#"{"messages":[]}"#])
        XCTAssertEqual(events.kinds, ["mock_model_request"])
        XCTAssertEqual(output, #"{"echo":{"messages":[]}}"#)
    }

    func testHermesRuntimeAcceptsAgentKitProviders() {
        let runtime = HermesAgentRuntime()
        runtime.setShellEnvironment(AgentKitMockShellEnvironment())
        runtime.setModelProvider(AgentKitMockModelProvider())
    }

    func testHermesXPCInterfacesAreConstructible() {
        XCTAssertNotNil(AgentKitHermesXPC.serviceInterface())
        XCTAssertNotNil(AgentKitHermesXPC.eventSinkInterface())
    }

    func testHermesAgentCanUseInjectedBackend() throws {
        let backend = MockHermesBackend()
        let sourceURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HermesSource", isDirectory: true)
        let agent = HermesAgent(
            configuration: .openAI(apiKey: "test-key", model: "test-model"),
            sourceURL: sourceURL,
            backend: backend
        )

        let result = try agent.send("hello") { event in
            XCTAssertEqual(event.kind, "mock")
        }

        XCTAssertEqual(result, "mock response")
        XCTAssertEqual(backend.messages, ["hello"])
        XCTAssertEqual(backend.sourceURLs, [sourceURL])
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentKitEvent] = []

    var kinds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.map(\.kind)
    }

    func append(_ event: AgentKitEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class MockHermesBackend: HermesAgentBackend, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []
    private(set) var sourceURLs: [URL] = []

    func prepare(sourceURL: URL) throws -> String {
        "mock prepare"
    }

    func probe(sourceURL: URL) throws -> HermesProbeResult {
        HermesProbeResult(python: "python", hermes: "hermes")
    }

    func toolProbe(sourceURL: URL) throws -> String {
        "mock tool probe"
    }

    func send(
        _ message: String,
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) throws -> String {
        lock.lock()
        messages.append(message)
        sourceURLs.append(sourceURL)
        lock.unlock()
        onEvent(AgentKitEvent(kind: "mock", payload: configuration.model))
        return "mock response"
    }

    func sessionState(sourceURL: URL) throws -> HermesSessionState {
        throw HermesAgentError.python("not implemented")
    }

    func loadSession(_ sessionID: String, sourceURL: URL) throws -> HermesSessionState {
        throw HermesAgentError.python("not implemented")
    }

    func newSession(sourceURL: URL) throws -> HermesSessionState {
        throw HermesAgentError.python("not implemented")
    }
}
