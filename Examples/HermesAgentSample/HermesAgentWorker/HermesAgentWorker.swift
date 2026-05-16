import AgentKit
import AgentKitFoundationModels
import AgentKitMLX
import ExtensionFoundation
import Foundation

@main
struct HermesAgentWorker: AppExtension {
    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onConnection: { connection in
            connection.exportedInterface = AgentKitHermesXPC.serviceInterface()
            connection.exportedObject = AgentKitHermesXPCService(
                modelProviderResolver: { configuration in
                    if #available(iOS 26.0, *),
                       configuration.baseURL.hasPrefix("hermes-foundation-models://") {
                        return AgentKitFoundationModelsProvider()
                    }

                    if configuration.baseURL.hasPrefix("hermes-local-mlx://") {
                        return AgentKitMLXModelProvider()
                    }

                    return nil
                }
            )
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
