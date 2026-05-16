import ExtensionFoundation

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var swiftAgentWorker: AppExtensionPoint {
        Name("__SWIFTAGENT_EXTENSION_POINT_NAME__")
        UserInterface(false)
    }
}
