# AgentKit

AgentKit is a proof-of-concept Swift package for embedding an agent runtime into an iOS app.

The framework-level API is intentionally not Hermes-specific. AgentKit owns the app-facing abstractions for shell execution, model completion, persistent paths, streaming events, and test doubles. Hermes is currently the first concrete agent implementation: `HermesAgentRuntime` embeds CPython, loads the bundled Python Hermes source, and adapts Hermes terminal/model callbacks to AgentKit services.

## What Is Included

- `Vendor/Python.xcframework`: BeeWare Python 3.14 for iOS.
- `Vendor/AgentKitISH.xcframework`: a local iSH ARM64 static XCFramework for the embedded Linux-like shell backend.
- `Vendor/ish-arm64`: vendored GPLv3 iSH ARM64 source plus AgentKit embedding patches.
- `Sources/CHermesPython`: a C bridge around `PyConfig`, Python evaluation, and Hermes callback plumbing.
- `Sources/AgentKitCore`: the lightweight protocol/path layer and test doubles.
- `Sources/AgentKit`: the batteries-included iOS POC target that re-exports `AgentKitCore` and includes Hermes, iSH shell, iOS shell, and MLX providers.
- `Examples/HermesAgentSample`: an iOS app that bundles Hermes source plus vendored Python dependencies.
- `Scripts/build-native-wheels.sh`: a reproducible recipe for rebuilding the Rust-backed iOS wheels used by OpenAI/Pydantic.
- `Scripts/agentkit-scaffold-worker-extension.sh` and `Templates/AgentKitWorkerExtension`: boilerplate for adding the out-of-process AgentKit worker extension to a host app.

## Architecture

The public layering is:

- `AgentKitShellEnvironment`: runs shell commands for an agent. Current implementations are `AgentKitISHShellEnvironment` and the older `AgentKitIOSShellEnvironment`.
- `AgentKitModelProvider`: completes OpenAI-style model requests. Current implementations are `AgentKitMLXModelProvider` and `AgentKitMockModelProvider`.
- `HermesAgentBackend`: owns the execution boundary for a Hermes agent. `HermesInProcessBackend` runs in the host app; `HermesExtensionProcessBackend` launches an ExtensionKit worker over XPC on iOS 26+.
- `HermesAgentRuntime`: the Hermes-specific adapter that embeds CPython, loads Hermes, and routes Hermes callbacks into the configured AgentKit shell/model providers.
- `AgentKitMockShellEnvironment` and `AgentKitMockModelProvider`: test doubles for exercising the Hermes bridge without a full app or real model.

This gives us a clean path for future agent implementations: they should target the AgentKit protocols, while Hermes-specific Python and bootstrap code stays behind `HermesAgentRuntime`.

AgentKit does not expose package-level singleton instances. Each `HermesAgent` gets its own runtime facade and provider objects by default, and callers can inject custom shell/model implementations for tests or app-specific behavior. The embedded CPython interpreter is still process-global, so native Python calls are serialized internally; independent agent objects are supported, but true simultaneous Hermes execution needs deeper interpreter/session isolation.

The default isolation layer for supported apps is out-of-process execution. On iOS, the viable direction is an app extension process launched with ExtensionFoundation and contacted over XPC, not `fork`/`exec` child processes. AgentKit includes the backend, XPC service, sample app extension, and scaffold templates for that path. The current extension smoke proves Python, Hermes, session calls, iSH terminal commands, and file read/write tools inside the worker process.

## Distribution Shape

Use Swift Package Manager for the public integration. It is the best fit for AgentKit because it can deliver Swift source, binary XCFrameworks, resources, tests, scripts, and templates in one dependency:

```swift
.package(url: "https://github.com/achimala/AgentKit", branch: "main")
```

AgentKit already uses XCFrameworks internally for the parts that need them:

- `Python.xcframework` for BeeWare Python.
- `AgentKitISH.xcframework` for the vendored iSH native library.
- `ios_system` auxiliary XCFrameworks.

Shipping AgentKit itself as one giant XCFramework would not remove the hard part: iOS still requires the consuming app to define and embed its own ExtensionKit extension target, and Python still needs a final app-bundle processing phase so native extension modules are copied and signed as frameworks. SPM keeps those moving pieces visible and versioned while still letting app code say `import AgentKit`.

## App API

The intended app-facing API is small. Once the app has packaged the Hermes payload and, on iOS 26+, added the AgentKit worker extension, app code looks like:

```swift
import AgentKit

let configuration = HermesAgentConfiguration.openAI(
    apiKey: apiKey,
    model: "gpt-4.1-mini"
)

let agent: HermesAgent
if #available(iOS 26.0, *) {
    agent = try HermesAgent(
        configuration: configuration,
        sourceURL: HermesAgent.bundledSourceURL(),
        backend: HermesExtensionProcessBackend(appExtensionPoint: .agentKitAgentWorker)
    )
} else {
    agent = try HermesAgent(configuration: configuration)
}

let result = try agent.send("Create hello.txt and read it back") { event in
    // Stream text, reasoning, tool calls, tool output, timing, and final events.
    print(event.kind, event.payload)
}
```

For offline MLX experiments:

```swift
let agent = try HermesAgent(
    configuration: .localMLX(
        model: AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit,
        maxTokens: 128,
        temperature: 0.2
    )
)
```

By default `HermesAgent` looks for bundled Hermes source at `PythonApp/hermes` in the app bundle. Apps can pass an explicit `sourceURL` or a different `bundledSourcePath` when they package Hermes differently.

Session management is also on the facade:

```swift
let sessions = try agent.sessionState()
let newSession = try agent.newSession()
let restored = try agent.loadSession(sessionID)
```

## Existing App Adoption

There are two setup paths:

- **Recommended for iOS 26+**: run Hermes out of process in an ExtensionKit worker. Hermes, CPython, iSH, and Python dependencies can crash or be jetsammed without crashing the host app process.
- **Fallback / older OSes**: run in process. This is simpler, but Hermes/Python/iSH share the app process.

For the recommended out-of-process setup:

1. Add AgentKit with Swift Package Manager.

2. Add the AgentKit package product to the host app target.

3. Add the packaging Run Script phase to the host app target:

   ```bash
   set -euo pipefail
   "${BUILD_DIR%/Build/*}/SourcePackages/checkouts/AgentKit/Scripts/agentkit-install-hermes.sh"
   ```

4. Add an ExtensionKit extension target to the app. Link the AgentKit package product from the extension target too.

5. Create the worker boilerplate. From the repo root during local development, or from the checked-out package path in an app repo:

   ```bash
   rtk ./Scripts/agentkit-scaffold-worker-extension.sh \
     --host-bundle-id com.example.MyApp \
     --output-dir AgentKitAgentWorker
   ```

6. Add the generated files to the correct targets:

   - `AgentKitAgentWorker.swift` and `Info.plist` go in the extension target.
   - `AgentKitWorkerExtensionPoint.swift` goes in the host app target.

7. In the extension target build settings, enable ExtensionKit extension point generation:

   ```text
   EX_ENABLE_EXTENSION_POINT_GENERATION = YES
   ```

8. Add the same packaging Run Script phase to the extension target. The worker process needs its own Python stdlib, Hermes payload, and native Python dependency frameworks inside the `.appex` bundle.

9. Make sure the host app embeds the extension target in `Embed ExtensionKit Extensions`.

10. Use the extension backend from the host app on iOS 26+:

    ```swift
    if #available(iOS 26.0, *) {
        let agent = try HermesAgent(
            configuration: configuration,
            sourceURL: HermesAgent.bundledSourceURL(),
            backend: HermesExtensionProcessBackend(appExtensionPoint: .agentKitAgentWorker)
        )
    }
    ```

That is the irreducible iOS part: SPM can provide the code, binaries, resources, scripts, and templates, but the app must own the `.appex` bundle because process boundaries, extension declarations, embedding, and signing are app-level build products.

## How The Sample Is Wired

The sample app does the same thing a consuming app should do:

- `HermesAgentSample/HermesWorkerExtensionPoint.swift` defines the host app extension point with `@Definition`.
- `HermesAgentWorker/HermesAgentWorker.swift` is the extension entrypoint. It binds to the host bundle ID and extension point name, then exports `AgentKitHermesXPCService`.
- The Xcode project has a `HermesAgentWorker.appex` target and embeds it into the app.
- Both the app and extension targets run `Scripts/agentkit-install-hermes.sh`, so both bundles contain the Python runtime and Hermes payload.
- The host app chooses `HermesExtensionProcessBackend(appExtensionPoint: .agentKitHermesWorker)` on iOS 26+.

## Try the Sample

```bash
rtk cd Examples/HermesAgentSample
rtk xcodegen generate
rtk xcodebuild -project HermesAgentSample.xcodeproj -scheme HermesAgentSample -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build
rtk xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/HermesAgentSample-eqgicvlbvbqhprgqnxtyipafsxsd/Build/Products/Debug-iphonesimulator/HermesAgentSample.app
rtk xcrun simctl launch booted com.daysail.HermesAgentSample
```

Tap **Probe** to verify Python/Hermes initialization, tap **Probe Shell** to exercise the iSH-backed terminal session, or configure Base URL / API key / Model in settings and send a chat message. The app writes full probe output to `Documents/hermes-probe-output.txt` in the app container.

## Current Result

Verified in simulator and generic iOS builds:

- Embedded CPython initializes from the app bundle.
- The app imports AgentKit bootstrap resources from the Swift package bundle.
- The app imports real Hermes `run_agent.py` from bundled source.
- Hermes chat works with OpenAI-compatible endpoints and streams reasoning, tool calls, tool outputs, timing, and final responses back to Swift.
- Hermes memory/context/soul are enabled with persistent `HERMES_HOME` under Application Support.
- Hermes terminal calls route into a persistent iSH ARM64 Alpine shell session.
- The iSH guest bind-mounts the AgentKit workspace at `/workspace`, so shell-created files are visible to Python/file tooling.
- The bundled iSH rootfs includes `python3`, `rg`, `jq`, and `git` for a first useful agent shell POC.
- A local MLX/Qwen 2B provider can be wired through the same model-provider bridge as an offline proof of concept.
- The ExtensionKit/XPC backend launches in the simulator and can initialize Python, import Hermes, create a Hermes session, run iSH-backed terminal commands, and use file read/write tools out of process.

## Dependency Packaging Shape

AgentKit includes a reusable Xcode build phase helper:

```bash
set -euo pipefail
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/AgentKit/Scripts/agentkit-install-hermes.sh"
```

For local development against this repo, the sample app uses:

```bash
set -euo pipefail
"$PROJECT_DIR/../../Scripts/agentkit-install-hermes.sh"
```

The script copies the Hermes Python payload into the final app bundle, overlays the platform-specific Python packages, and runs BeeWare's `install_python` helper to copy the Python standard library and convert `.so` extension modules into signed app frameworks.

By default the script uses the checked-in sample payload at `Examples/HermesAgentSample/HermesAgentSample/PythonApp`. Apps can set `AGENTKIT_PYTHON_APP_SOURCE` to their own payload directory and `AGENTKIT_PYTHON_XCFRAMEWORK` to a custom Python framework path.

Third-party Python packages are staged with this layout:

- `PythonApp/site-packages`: pure Python/common dependencies.
- `PythonApp/site-packages-iphonesimulator`: simulator-native wheels.
- `PythonApp/site-packages-iphoneos`: device-native wheels.

SwiftPM cannot silently add this final app-bundle processing step to a consuming iOS app, so a small explicit Run Script phase is still required for the Python/Hermes backend. The app-facing Swift code stays at `import AgentKit`.

## Rebuilding Native Wheels

The native wheels currently needed for OpenAI/Pydantic are `jiter==0.13.0` and `pydantic_core==2.41.5`.

```bash
rtk ./Scripts/build-native-wheels.sh
```

That builds simulator and device wheels into `Build/wheelhouse`. Updating the checked-in sample package layers still needs a vendor step: unzip the `iphonesimulator` wheels into `Examples/HermesAgentSample/HermesAgentSample/PythonApp/site-packages-iphonesimulator` and the `iphoneos` wheels into `Examples/HermesAgentSample/HermesAgentSample/PythonApp/site-packages-iphoneos`.

## iSH Shell Backend

The iSH integration is session-based. A one-shot `ish /bin/sh -c ...` style runner works once, but is not reentrant in a single host process because the iSH kernel keeps global state. AgentKit instead boots one long-lived guest shell, writes commands over a pipe, and reads output until a private completion marker.

The current rootfs is copied from the app bundle into Application Support before first use because iSH mutates its fakefs metadata and the `/workspace` bind mount. This is packaging-heavy but keeps the POC honest: it runs real guest binaries rather than a hand-written command parser.

## Known Boundaries

- Hermes is still the only agent implementation. The package shape is ready for more, but the generic agent API is intentionally thin until a second implementation proves it.
- Many desktop-style tools remain inappropriate for iOS: browser automation, MCP stdio servers, runtime package installation outside the guest rootfs, and desktop computer-use.
- The iSH backend currently supports one embedded shell session per process. Multiple concurrent sessions need more invasive iSH state isolation.
- Out-of-process execution requires iOS 26+ and an app-owned ExtensionKit extension target. SPM cannot silently create or sign that target for a consuming app.
- The package-level `HermesAgent(configuration:)` convenience initializer still runs in process unless the app explicitly passes `HermesExtensionProcessBackend`. The sample defaults to the extension backend on iOS 26+.
- The bundled full Alpine fakefs is large; a distributable package should eventually build a smaller purpose-made rootfs.
- The local MLX model provider is a POC. The 2B model can run offline, but it is weak at tool use compared with a hosted model.
- Generic `iphoneos` build can be verified with `CODE_SIGNING_ALLOWED=NO`; real device install still needs normal Apple signing/provisioning.
