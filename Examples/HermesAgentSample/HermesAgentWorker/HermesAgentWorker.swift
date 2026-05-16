import SwiftAgent
import SwiftAgentMLX
import ExtensionFoundation
import Foundation

@main
struct HermesAgentWorker: AppExtension {
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onConnection: { connection in
            connection.exportedInterface = SwiftAgentHermesXPC.serviceInterface()
            connection.exportedObject = SwiftAgentHermesXPCService(
                modelProviderResolver: { configuration in
                    if configuration.baseURL.hasPrefix("hermes-local-mlx://") {
                        return SwiftAgentMLXModelProvider()
                    }

                    return nil
                }
            )
            connection.remoteObjectInterface = SwiftAgentHermesXPC.eventSinkInterface()
            connection.resume()
            return true
        })
    }

    @AppExtensionPoint.Bind
    var boundExtensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(host: "com.daysail.HermesAgentSample", name: "swiftagent-hermes-worker")
    }
}
