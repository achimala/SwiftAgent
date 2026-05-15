import AgentKit
import ExtensionFoundation
import Foundation

@main
struct AgentKitAgentWorker: AppExtension {
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onConnection: { connection in
            connection.exportedInterface = AgentKitHermesXPC.serviceInterface()
            connection.exportedObject = AgentKitHermesXPCService()
            connection.remoteObjectInterface = AgentKitHermesXPC.eventSinkInterface()
            connection.resume()
            return true
        })
    }

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "__AGENTKIT_HOST_BUNDLE_ID__",
            name: "__AGENTKIT_EXTENSION_POINT_NAME__"
        )
    }
}
