import AgentKitCore
import Foundation
#if os(iOS)
import AgentKitISH
#endif

public enum AgentKitISHShellError: Error, CustomStringConvertible {
    case missingRootFS
    case workspaceSetupFailed(URL)
    case sessionStartFailed(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .missingRootFS:
            "AgentKit iSH root filesystem was not found"
        case .workspaceSetupFailed(let url):
            "iSH workspace could not be created at \(url.path)"
        case .sessionStartFailed(let message):
            "iSH session failed to start: \(message)"
        case .commandFailed(let message):
            "iSH command failed: \(message)"
        }
    }
}

public final class AgentKitISHShellEnvironment: AgentKitShellEnvironment, @unchecked Sendable {
#if os(iOS)
    private let lock = NSRecursiveLock()
    private var session: OpaquePointer?
    private var mountedWorkspace: URL?

    public init() {}

    deinit {
        if let session {
            agentkit_ish_session_destroy(session)
        }
    }

    public func run(
        _ command: String,
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> HermesShellResult {
        try run(AgentKitShellCommand(command: command, cwd: cwd, environment: environment))
    }

    public func run(_ command: AgentKitShellCommand) throws -> AgentKitShellResult {
        lock.lock()
        defer { lock.unlock() }

        let workspace = try Self.defaultWorkspace()
        let runDirectory = command.cwd ?? workspace
        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        try ensureSession(workspace: workspace)

        let guestCwd = Self.guestPath(forHostPath: runDirectory.path, workspace: workspace.path)
        let environmentPrefix = command.environment
            .sorted { $0.key < $1.key }
            .compactMap { Self.exportLine(name: $0.key, value: $0.value) }
            .joined(separator: "\n")
        let wrappedCommand = """
        cd \(Self.shellQuote(guestCwd))
        \(environmentPrefix)
        \(command.command)
        """

        var outputPointer: UnsafeMutablePointer<CChar>?
        var errorPointer: UnsafeMutablePointer<CChar>?
        var status: Int32 = -1
        let result = agentkit_ish_session_run(
            session,
            wrappedCommand,
            Int32((command.environment["AGENTKIT_SHELL_TIMEOUT"].flatMap(Int.init) ?? command.environment["HERMES_SHELL_TIMEOUT"].flatMap(Int.init) ?? 60) * 1000),
            &outputPointer,
            &status,
            &errorPointer
        )
        defer {
            if let outputPointer {
                agentkit_ish_free_string(outputPointer)
            }
            if let errorPointer {
                agentkit_ish_free_string(errorPointer)
            }
        }

        if result != 0 {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown iSH error"
            throw AgentKitISHShellError.commandFailed(message)
        }

        return HermesShellResult(
            command: command.command,
            output: outputPointer.map { String(cString: $0) } ?? "",
            status: status
        )
    }

    public func smokeTest(cwd: URL? = nil) throws -> String {
        let workspace = try cwd ?? Self.defaultWorkspace()
            .appendingPathComponent("ISHShellSmokeTest", isDirectory: true)
        if cwd == nil {
            try? FileManager.default.removeItem(at: workspace)
        }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let commands = [
            "pwd",
            "echo needle > a.txt",
            "cat a.txt",
            "grep needle a.txt | head -20 > out.txt",
            "cat out.txt",
            "find . -type f | xargs grep needle",
            "rg needle . | head -20 > rg-out.txt",
            "cat rg-out.txt",
            "python3 -c 'print(\"python-c-ok\")'",
            "echo 'print(\"python-file-ok\")' > probe.py",
            "python3 probe.py",
            "python3 -c 'raise SystemExit(7)'",
            "python3 -c 'open(\"python-created.txt\", \"w\").write(\"created-by-python\\n\")'",
            "cat python-created.txt",
            "sh -c 'echo sh-c-ok'",
        ]

        var transcript = "ISH WORKSPACE\n\(workspace.path)\n\n"
        for command in commands {
            let result = try run(command, cwd: workspace)
            transcript += "$ \(command)\n"
            if !result.output.isEmpty {
                transcript += result.output
                if !result.output.hasSuffix("\n") {
                    transcript += "\n"
                }
            }
            transcript += "[status \(result.status)]\n\n"
        }
        return transcript
    }

    private func ensureSession(workspace: URL) throws {
        if session != nil {
            return
        }

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rootFS = try Self.installedRootFS()
        var createdSession: OpaquePointer?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = agentkit_ish_session_create(
            rootFS.path,
            workspace.path,
            &createdSession,
            &errorPointer
        )
        defer {
            if let errorPointer {
                agentkit_ish_free_string(errorPointer)
            }
        }
        guard result == 0, let createdSession else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown iSH session error"
            throw AgentKitISHShellError.sessionStartFailed(message)
        }

        session = createdSession
        mountedWorkspace = workspace
    }

    private static func installedRootFS() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let installRoot = supportDirectory
            .appendingPathComponent("AgentKit", isDirectory: true)
            .appendingPathComponent("iSH", isDirectory: true)
        let installed = installRoot.appendingPathComponent("alpine-arm64-fakefs", isDirectory: true)
        let marker = installed.appendingPathComponent(".agentkit-rootfs-ready")
        if FileManager.default.fileExists(atPath: marker.path) {
            return installed
        }

        guard let bundled = Bundle.module.url(
            forResource: "alpine-arm64-fakefs",
            withExtension: nil,
            subdirectory: "iSH"
        ) else {
            throw AgentKitISHShellError.missingRootFS
        }

        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundled, to: installed)
        try Data().write(to: marker)
        return installed
    }

    private static func defaultWorkspace() throws -> URL {
        try AgentKitPaths.defaultShellWorkspace()
    }

    private static func guestPath(forHostPath hostPath: String, workspace: String) -> String {
        if hostPath == workspace {
            return "/workspace"
        }
        let normalizedWorkspace = workspace.hasSuffix("/") ? workspace : workspace + "/"
        if hostPath.hasPrefix(normalizedWorkspace) {
            let suffix = String(hostPath.dropFirst(normalizedWorkspace.count))
            return "/workspace/" + suffix
        }
        return "/workspace"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func exportLine(name: String, value: String) -> String? {
        guard name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return "export \(name)=\(shellQuote(value))"
    }
#else
    public init() {}

    public func run(_ command: AgentKitShellCommand) throws -> AgentKitShellResult {
        throw AgentKitISHShellError.missingRootFS
    }

    public func smokeTest(cwd: URL? = nil) throws -> String {
        throw AgentKitISHShellError.missingRootFS
    }
#endif
}
