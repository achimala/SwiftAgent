# AgentKit

AgentKit is a proof-of-concept Swift package for embedding an agent runtime into an iOS app.

The framework-level API is intentionally not Hermes-specific. AgentKit owns the app-facing abstractions for shell execution, model completion, persistent paths, streaming events, and test doubles. Hermes is currently the first concrete agent implementation: `HermesAgentRuntime` embeds CPython, loads the bundled Python Hermes source, and adapts Hermes terminal/model callbacks to AgentKit services.

## What Is Included

- `Vendor/Python.xcframework`: BeeWare Python 3.14 for iOS.
- `Vendor/AgentKitISH.xcframework`: a local iSH ARM64 static XCFramework for the embedded Linux-like shell backend.
- `Vendor/ish-arm64`: vendored GPLv3 iSH ARM64 source plus AgentKit embedding patches.
- `Sources/CHermesPython`: a C bridge around `PyConfig`, Python evaluation, and Hermes callback plumbing.
- `Sources/AgentKit`: the Swift package target containing generic AgentKit protocols plus the Hermes implementation.
- `Examples/HermesAgentSample`: an iOS app that bundles Hermes source plus vendored Python dependencies.
- `Scripts/build-native-wheels.sh`: a reproducible recipe for rebuilding the Rust-backed iOS wheels used by OpenAI/Pydantic.

## Architecture

The public layering is:

- `AgentKitShellEnvironment`: runs shell commands for an agent. Current implementations are `AgentKitISHShellEnvironment` and the older `AgentKitIOSShellEnvironment`.
- `AgentKitModelProvider`: completes OpenAI-style model requests. Current implementations are `AgentKitMLXModelProvider` and `AgentKitMockModelProvider`.
- `HermesAgentRuntime`: the Hermes-specific adapter that embeds CPython, loads Hermes, and routes Hermes callbacks into the configured AgentKit shell/model providers.
- `AgentKitMockShellEnvironment` and `AgentKitMockModelProvider`: test doubles for exercising the Hermes bridge without a full app or real model.

This gives us a clean path for future agent implementations: they should target the AgentKit protocols, while Hermes-specific Python and bootstrap code stays behind `HermesAgentRuntime`.

## App API

The intended app-facing API is:

```swift
import AgentKit

let agent = try HermesAgent(
    configuration: .openAI(
        apiKey: apiKey,
        model: "gpt-4.1-mini"
    )
)

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

## Dependency Packaging Shape

Third-party Python packages are staged in the sample app, not in the Swift package resource bundle:

- `PythonApp/site-packages`: pure Python/common dependencies.
- `PythonApp/site-packages-iphonesimulator`: simulator-native wheels.
- `PythonApp/site-packages-iphoneos`: device-native wheels.

The app target build script overlays the correct platform layer into `PythonApp/site-packages`, then runs BeeWare’s `install_python` helper to convert `.so` extension modules into signed app frameworks.

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
- The bundled full Alpine fakefs is large; a distributable package should eventually build a smaller purpose-made rootfs.
- The local MLX model provider is a POC. The 2B model can run offline, but it is weak at tool use compared with a hosted model.
- Generic `iphoneos` build can be verified with `CODE_SIGNING_ALLOWED=NO`; real device install still needs normal Apple signing/provisioning.
