import ExtensionFoundation

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var agentKitHermesWorker: AppExtensionPoint {
        Name("agentkit-hermes-worker")
        UserInterface(false)
    }
}
