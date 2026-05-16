#if os(iOS)
import CHermesShell
#endif
import SwiftAgentCore
import Darwin
import Foundation
#if os(iOS)
import ios_system
#endif

public enum SwiftAgentIOSShellError: Error, CustomStringConvertible {
    case missingResources
    case commandFailedToStart(String)
    case workspaceSetupFailed(URL)

    public var description: String {
        switch self {
        case .missingResources:
            "SwiftAgent iOS shell resources were not found"
        case .commandFailedToStart(let command):
            "Shell command failed to start: \(command)"
        case .workspaceSetupFailed(let url):
            "Shell workspace could not be created at \(url.path)"
        }
    }
}

public final class SwiftAgentIOSShellEnvironment: SwiftAgentShellEnvironment, @unchecked Sendable {
#if os(iOS)
    private let lock = NSRecursiveLock()
    private let pythonRuntime = HermesAgentRuntime()
    private var initialized = false

    public init() {}

    public func run(
        _ command: String,
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> SwiftAgentShellResult {
        try run(SwiftAgentShellCommand(command: command, cwd: cwd, environment: environment))
    }

    public func run(_ command: SwiftAgentShellCommand) throws -> SwiftAgentShellResult {
        lock.lock()
        defer { lock.unlock() }

        let workspace = try command.cwd ?? Self.defaultWorkspace()
        try initialize(workspace: workspace)
        try prepareRun(cwd: workspace, environment: command.environment)

        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftAgentIOSShell", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)

        let stdoutURL = captureDirectory
            .appendingPathComponent(".swiftagent-shell-stdout-\(UUID().uuidString)")
        let stderrURL = captureDirectory
            .appendingPathComponent(".swiftagent-shell-stderr-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        guard let stdoutFile = fopen(stdoutURL.path, "w+") else {
            let message = "\(command.command) (cwd: \(workspace.path), stdout: \(stdoutURL.path), errno: \(errno))"
            throw SwiftAgentIOSShellError.commandFailedToStart(message)
        }
        guard let stderrFile = fopen(stderrURL.path, "w+") else {
            fclose(stdoutFile)
            let message = "\(command.command) (cwd: \(workspace.path), stderr: \(stderrURL.path), errno: \(errno))"
            throw SwiftAgentIOSShellError.commandFailedToStart(message)
        }
        defer {
            fclose(stdoutFile)
            fclose(stderrFile)
            ios_setStreams(stdin, stdout, stderr)
            HermesShell_SetThreadStreams(stdin, stdout, stderr)
        }

        ios_setStreams(stdin, stdoutFile, stderrFile)
        HermesShell_SetThreadStreams(stdin, stdoutFile, stderrFile)
        let status = ios_system(command.command)
        fflush(stdoutFile)
        fflush(stderrFile)

        var output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let errorOutput = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        if !errorOutput.isEmpty {
            output += errorOutput
        }

        return SwiftAgentShellResult(
            command: command.command,
            output: output,
            status: status
        )
    }

    private func initialize(workspace: URL) throws {
        if initialized {
            return
        }

        guard let shellResources = Bundle.module.url(forResource: "Shell", withExtension: nil),
              let commandDictionary = Bundle.module.url(
                forResource: "commandDictionary",
                withExtension: "plist",
                subdirectory: "Shell"
              )
        else {
            throw SwiftAgentIOSShellError.missingResources
        }

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        initializeEnvironment()
        try pythonRuntime.initialize()
        HermesShell_SetPythonInterpreterSlots(1)
        _ = addCommandList(commandDictionary.path)

        let binPath = shellResources.appendingPathComponent("bin", isDirectory: true)
        let workspaceBinPath = workspace.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceBinPath, withIntermediateDirectories: true)

        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        ios_setenv("PATH", "\(workspaceBinPath.path):\(binPath.path):\(existingPath)", 1)
        ios_setenv("HOME", workspace.path, 1)
        ios_setenv("TMPDIR", workspace.path, 1)
        ios_setenv("LC_ALL", "C", 1)
        ios_setenv("LANG", "C", 1)

        initialized = true
    }

    private func prepareRun(cwd: URL, environment: [String: String]) throws {
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        guard FileManager.default.changeCurrentDirectoryPath(cwd.path) else {
            throw SwiftAgentIOSShellError.workspaceSetupFailed(cwd)
        }
        ios_setDirectoryURL(cwd)

        for (key, value) in environment {
            ios_setenv(key, value, 1)
        }
    }

    private static func defaultWorkspace() throws -> URL {
        try SwiftAgentPaths.defaultShellWorkspace()
    }
#else
    public init() {}

    public func run(_ command: SwiftAgentShellCommand) throws -> SwiftAgentShellResult {
        throw SwiftAgentIOSShellError.missingResources
    }

#endif
}
