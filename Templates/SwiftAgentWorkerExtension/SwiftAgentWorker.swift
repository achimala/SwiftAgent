import SwiftAgent
import ExtensionFoundation
import Foundation

@main
struct SwiftAgentWorker: AppExtension {
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onConnection: { connection in
            connection.exportedInterface = SwiftAgentHermesXPC.serviceInterface()
            connection.exportedObject = SwiftAgentHermesXPCService()
            connection.remoteObjectInterface = SwiftAgentHermesXPC.eventSinkInterface()
            connection.resume()
            return true
        })
    }

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "__SWIFTAGENT_HOST_BUNDLE_ID__",
            name: "__SWIFTAGENT_EXTENSION_POINT_NAME__"
        )
    }
}
