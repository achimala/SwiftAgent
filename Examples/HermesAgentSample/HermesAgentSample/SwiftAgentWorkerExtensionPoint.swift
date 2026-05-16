import ExtensionFoundation

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var swiftAgentWorker: AppExtensionPoint {
        Name("swiftagent-hermes-worker")
        UserInterface(false)
    }
}
