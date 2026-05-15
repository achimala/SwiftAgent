import AgentKit
import ExtensionFoundation
import Foundation

@main
struct HermesAgentWorker: AppExtension {
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
        AppExtensionPoint.Identifier(host: "com.daysail.HermesAgentSample", name: "agentkit-hermes-worker")
    }
}
