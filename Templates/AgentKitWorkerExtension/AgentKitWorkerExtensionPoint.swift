import ExtensionFoundation

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var agentKitAgentWorker: AppExtensionPoint {
        Name("__AGENTKIT_EXTENSION_POINT_NAME__")
        UserInterface(false)
    }
}
