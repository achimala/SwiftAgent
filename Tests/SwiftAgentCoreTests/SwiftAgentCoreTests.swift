import SwiftAgentCore
import Foundation
import XCTest

final class SwiftAgentCoreTests: XCTestCase {
    func testMockShellRecordsCommands() throws {
        let shell = SwiftAgentMockShellEnvironment { command in
            SwiftAgentShellResult(command: command.command, output: "ran \(command.command)", status: 0)
        }

        let result = try shell.run("pwd", cwd: URL(fileURLWithPath: "/tmp"), environment: ["A": "B"])

        XCTAssertEqual(result.output, "ran pwd")
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(shell.commands.map(\.command), ["pwd"])
        XCTAssertEqual(shell.commands.first?.environment["A"], "B")
    }

    func testMockModelProviderEmitsRequestEvent() async throws {
        let provider = SwiftAgentMockModelProvider { request in
            #"{"echo":\#(request.rawJSON)}"#
        }
        let events = EventRecorder()

        let output = try await provider.complete(
            request: SwiftAgentModelRequest(rawJSON: #"{"messages":[]}"#)
        ) { event in
            events.append(event)
        }

        let requests = await provider.requests
        XCTAssertEqual(requests.map(\.rawJSON), [#"{"messages":[]}"#])
        XCTAssertEqual(events.kinds, ["mock_model_request"])
        XCTAssertEqual(output, #"{"echo":{"messages":[]}}"#)
    }

    func testShellConvenienceBuildsCommand() throws {
        let cwd = URL(fileURLWithPath: "/tmp/swiftagent")
        let shell = SwiftAgentMockShellEnvironment { command in
            XCTAssertEqual(command.command, "ls -la")
            XCTAssertEqual(command.cwd, cwd)
            XCTAssertEqual(command.environment, ["LANG": "C"])
            return SwiftAgentShellResult(command: command.command, output: "ok", status: 0)
        }

        let result = try shell.run("ls -la", cwd: cwd, environment: ["LANG": "C"])

        XCTAssertEqual(result.command, "ls -la")
        XCTAssertEqual(result.output, "ok")
        XCTAssertEqual(result.status, 0)
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [SwiftAgentEvent] = []

    var kinds: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.map(\.kind)
    }

    func append(_ event: SwiftAgentEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
