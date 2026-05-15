import SwiftUI

@main
struct HermesAgentSampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await SampleSmokeRunners.runIfRequested()
                }
        }
    }
}
