import SwiftAgentCore
import Foundation
#if os(iOS)
import SwiftAgentISH
#endif

public enum SwiftAgentISHShellError: Error, CustomStringConvertible {
    case missingRootFS
    case workspaceSetupFailed(URL)
    case sessionStartFailed(String)
    case commandFailed(String)

    public var description: String {
        switch self {
        case .missingRootFS:
            "SwiftAgent iSH root filesystem was not found"
        case .workspaceSetupFailed(let url):
            "iSH workspace could not be created at \(url.path)"
        case .sessionStartFailed(let message):
            "iSH session failed to start: \(message)"
        case .commandFailed(let message):
            "iSH command failed: \(message)"
        }
    }
}

public final class SwiftAgentISHShellEnvironment: SwiftAgentShellEnvironment, @unchecked Sendable {
#if os(iOS)
    private let lock = NSRecursiveLock()
    private var session: OpaquePointer?
    private var mountedWorkspace: URL?

    public init() {}

    deinit {
        if let session {
            swiftagent_ish_session_destroy(session)
        }
    }

    public func run(
        _ command: String,
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> HermesShellResult {
        try run(SwiftAgentShellCommand(command: command, cwd: cwd, environment: environment))
    }

    public func run(_ command: SwiftAgentShellCommand) throws -> SwiftAgentShellResult {
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
        let result = swiftagent_ish_session_run(
            session,
            wrappedCommand,
            Int32((command.environment["SWIFTAGENT_SHELL_TIMEOUT"].flatMap(Int.init) ?? command.environment["HERMES_SHELL_TIMEOUT"].flatMap(Int.init) ?? 60) * 1000),
            &outputPointer,
            &status,
            &errorPointer
        )
        defer {
            if let outputPointer {
                swiftagent_ish_free_string(outputPointer)
            }
            if let errorPointer {
                swiftagent_ish_free_string(errorPointer)
            }
        }

        if result != 0 {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown iSH error"
            throw SwiftAgentISHShellError.commandFailed(message)
        }

        return HermesShellResult(
            command: command.command,
            output: outputPointer.map { String(cString: $0) } ?? "",
            status: status
        )
    }

    private func ensureSession(workspace: URL) throws {
        if session != nil {
            return
        }

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rootFS = try Self.installedRootFS()
        var createdSession: OpaquePointer?
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = swiftagent_ish_session_create(
            rootFS.path,
            workspace.path,
            &createdSession,
            &errorPointer
        )
        defer {
            if let errorPointer {
                swiftagent_ish_free_string(errorPointer)
            }
        }
        guard result == 0, let createdSession else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown iSH session error"
            throw SwiftAgentISHShellError.sessionStartFailed(message)
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
            .appendingPathComponent("SwiftAgent", isDirectory: true)
            .appendingPathComponent("iSH", isDirectory: true)
        let installed = installRoot.appendingPathComponent("alpine-arm64-fakefs", isDirectory: true)
        let marker = installed.appendingPathComponent(".swiftagent-rootfs-ready")
        if FileManager.default.fileExists(atPath: marker.path) {
            return installed
        }

        guard let bundled = Bundle.module.url(
            forResource: "alpine-arm64-fakefs",
            withExtension: nil,
            subdirectory: "iSH"
        ) else {
            throw SwiftAgentISHShellError.missingRootFS
        }

        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundled, to: installed)
        try Data().write(to: marker)
        return installed
    }

    private static func defaultWorkspace() throws -> URL {
        try SwiftAgentPaths.defaultShellWorkspace()
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

    public func run(_ command: SwiftAgentShellCommand) throws -> SwiftAgentShellResult {
        throw SwiftAgentISHShellError.missingRootFS
    }

#endif
}
