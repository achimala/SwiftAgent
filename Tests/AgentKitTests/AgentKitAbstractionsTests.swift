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
