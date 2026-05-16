import Foundation

public enum SwiftAgentPaths {
    public static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("SwiftAgent", isDirectory: true)
    }

    public static func defaultAgentHome() throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("AgentHome", isDirectory: true)
    }

    public static func defaultShellWorkspace() throws -> URL {
        try applicationSupportDirectory()
            .appendingPathComponent("ShellWorkspace", isDirectory: true)
    }
}
