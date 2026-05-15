# AgentKit Technical Details

This document collects the lower-level architecture, packaging, and boundary notes for AgentKit. The README stays focused on app adoption.

## Package Contents

- `Vendor/Python.xcframework`: BeeWare Python 3.14 for iOS.
- `Vendor/AgentKitISH.xcframework`: a local iSH ARM64 static XCFramework for the embedded Linux-like shell backend.
- `Vendor/ish-arm64`: vendored GPLv3 iSH ARM64 source plus AgentKit embedding patches.
- `Vendor/hermes-agent.lock`: the reviewed upstream Hermes release pin.
- `Payloads/Hermes/PythonApp`: checked-in Python dependency layers plus a generated `hermes/` source directory fetched from the lock file.
- `Sources/CHermesPython`: a C bridge around `PyConfig`, Python evaluation, and Hermes callback plumbing.
- `Sources/AgentKitCore`: the lightweight protocol/path layer and test doubles.
- `Sources/AgentKit`: the batteries-included iOS POC target that re-exports `AgentKitCore` and includes Hermes, iSH shell, and iOS shell support.
- `Packages/AgentKitMLX`: an optional local-model add-on package that carries the MLX/Hugging Face dependencies and `AgentKitMLXModelProvider`.
- `Examples/HermesAgentSample`: an iOS app that consumes the canonical AgentKit Hermes payload through the build script.
- `Scripts/update-hermes.sh`: fetches the pinned upstream Hermes release and stages it into ignored `Payloads/Hermes/PythonApp/hermes`.
- `Scripts/build-native-wheels.sh`: a reproducible recipe for rebuilding the Rust-backed iOS wheels used by OpenAI/Pydantic.
- `Scripts/agentkit-scaffold-worker-extension.sh` and `Templates/AgentKitWorkerExtension`: boilerplate for adding the out-of-process AgentKit worker extension to a host app.

## Architecture

The public layering is:

- `AgentKitShellEnvironment`: runs shell commands for an agent. Current implementations are `AgentKitISHShellEnvironment` and the older `AgentKitIOSShellEnvironment`.
- `AgentKitModelProvider`: completes OpenAI-style model requests. Current implementations are the optional `AgentKitMLXModelProvider` add-on and `AgentKitMockModelProvider`.
- `HermesAgentBackend`: owns the execution boundary for a Hermes agent. `HermesInProcessBackend` runs in the host app; `HermesExtensionProcessBackend` launches an ExtensionKit worker over XPC on iOS 26+.
- `HermesAgentRuntime`: the Hermes-specific adapter that embeds CPython, loads Hermes, and routes Hermes callbacks into the configured AgentKit shell/model providers.
- `AgentKitMockShellEnvironment` and `AgentKitMockModelProvider`: test doubles for exercising the Hermes bridge without a full app or real model.

This gives us a clean path for future agent implementations: they should target the AgentKit protocols, while Hermes-specific Python and bootstrap code stays behind `HermesAgentRuntime`.

AgentKit does not expose package-level singleton instances. Each `HermesAgent` gets its own runtime facade and provider objects by default, and callers can inject custom shell/model implementations for tests or app-specific behavior. The embedded CPython interpreter is still process-global, so native Python calls are serialized internally; independent agent objects are supported, but true simultaneous Hermes execution needs deeper interpreter/session isolation.

The default isolation layer for supported apps is out-of-process execution. On iOS, the viable direction is an app extension process launched with ExtensionFoundation and contacted over XPC, not `fork`/`exec` child processes. AgentKit includes the backend, XPC service, sample app extension, and scaffold templates for that path. The current extension smoke proves Python, Hermes, session calls, iSH terminal commands, and file read/write tools inside the worker process.

## Distribution Shape

Use Swift Package Manager for the public integration. It is the best fit for AgentKit because it can deliver Swift source, binary XCFrameworks, resources, tests, scripts, and templates in one dependency.

AgentKit already uses XCFrameworks internally for the parts that need them:

- `Python.xcframework` for BeeWare Python.
- `AgentKitISH.xcframework` for the vendored iSH native library.
- `ios_system` auxiliary XCFrameworks.

Shipping AgentKit itself as one giant XCFramework would not remove the hard part: iOS still requires the consuming app to define and embed its own ExtensionKit extension target, and Python still needs a final app-bundle processing phase so native extension modules are copied and signed as frameworks. SPM keeps those moving pieces visible and versioned while still letting app code say `import AgentKit`.

## How The Sample Is Wired

The sample app does the same thing a consuming app should do:

- `HermesAgentSample/HermesWorkerExtensionPoint.swift` defines the host app extension point with `@Definition`.
- `HermesAgentWorker/HermesAgentWorker.swift` is the extension entrypoint. It binds to the host bundle ID and extension point name, then exports `AgentKitHermesXPCService`.
- The Xcode project has a `HermesAgentWorker.appex` target and embeds it into the app.
- Both the app and extension targets run `Scripts/agentkit-install-hermes.sh`, so both bundles contain the Python runtime and Hermes payload.
- The host app chooses `HermesExtensionProcessBackend(appExtensionPoint: .agentKitHermesWorker)` on iOS 26+.

## Dependency Packaging

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

The script ensures the pinned Hermes source exists, copies the Hermes Python payload into the final app bundle, overlays the platform-specific Python packages, and runs BeeWare's `install_python` helper to copy the Python standard library and convert `.so` extension modules into signed app frameworks.

By default the script uses `Payloads/Hermes/PythonApp`. If `Payloads/Hermes/PythonApp/hermes` is missing, it runs `Scripts/update-hermes.sh` to fetch the pinned source before copying the payload. Apps can set `AGENTKIT_PYTHON_APP_SOURCE` to their own payload directory and `AGENTKIT_PYTHON_XCFRAMEWORK` to a custom Python framework path. Set `AGENTKIT_AUTO_FETCH_HERMES=NO` to make missing Hermes source a hard build error.

Third-party Python packages are staged with this layout:

- `PythonApp/site-packages`: pure Python/common dependencies.
- `PythonApp/site-packages-iphonesimulator`: simulator-native wheels.
- `PythonApp/site-packages-iphoneos`: device-native wheels.

SwiftPM cannot silently add this final app-bundle processing step to a consuming iOS app, so a small explicit Run Script phase is still required for the Python/Hermes backend. The app-facing Swift code stays at `import AgentKit`.

Local MLX support lives in the separate `Packages/AgentKitMLX` add-on package. The main `AgentKit` package intentionally has no MLX, Hugging Face, or tokenizer package dependencies, so hosted-model apps do not resolve that graph. Apps that want offline local-model experiments can add the add-on package and inject `AgentKitMLXModelProvider` explicitly.

## Updating Hermes

Hermes is intentionally not a Git submodule and is not checked into this repository. The build phase fetches the pinned release on demand when the generated payload is missing. CI can either pre-run `./Scripts/update-hermes.sh` for an explicit bootstrap step or set `AGENTKIT_AUTO_FETCH_HERMES=NO` to prevent network access during builds.

The source pin lives in `Vendor/hermes-agent.lock`:

- `HERMES_REPOSITORY`: upstream Git repository.
- `HERMES_TAG`: reviewed upstream release tag.
- `HERMES_VERSION`: expected Python package version.
- `HERMES_COMMIT`: peeled release-tag commit.

To update Hermes:

1. Review the upstream release.
2. Update `Vendor/hermes-agent.lock` to the new tag/version/commit.
3. Run `./Scripts/update-hermes.sh`.
4. Run the host tests and simulator build.

`Scripts/update-hermes.sh` fetches the tagged source into `Build/hermes-agent-src`, verifies that the tag resolves to the pinned commit, verifies `pyproject.toml` matches the pinned version, and replaces only the ignored generated directory at `Payloads/Hermes/PythonApp/hermes`. It stages runtime-relevant Hermes files while excluding obvious upstream repo furniture like CI config, Docker/Nix files, tests, website docs, and release-note archives. It leaves the pure-Python and platform-native dependency layers in place. The script uses a simple lock directory so parallel app/extension build phases do not race while generating the payload.

## Rebuilding Native Wheels

The native wheels currently needed for OpenAI/Pydantic are `jiter==0.13.0` and `pydantic_core==2.41.5`.

```bash
./Scripts/build-native-wheels.sh
```

That builds simulator and device wheels into `Build/wheelhouse`. Updating the checked-in package layers still needs a vendor step: unzip the `iphonesimulator` wheels into `Payloads/Hermes/PythonApp/site-packages-iphonesimulator` and the `iphoneos` wheels into `Payloads/Hermes/PythonApp/site-packages-iphoneos`.

## iSH Shell Backend

The iSH integration is session-based. A one-shot `ish /bin/sh -c ...` style runner works once, but is not reentrant in a single host process because the iSH kernel keeps global state. AgentKit instead boots one long-lived guest shell, writes commands over a pipe, and reads output until a private completion marker.

The current rootfs is copied from the app bundle into Application Support before first use because iSH mutates its fakefs metadata and the `/workspace` bind mount. This is packaging-heavy but keeps the POC honest: it runs real guest binaries rather than a hand-written command parser.

The iSH guest bind-mounts the AgentKit workspace at `/workspace`. Hermes file tools run through a direct iOS host-file bridge constrained to the same workspace, so shell-created files and Python-created files are visible to each other without pretending host absolute paths exist inside the guest.

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
- A local MLX/Qwen 2B provider can be wired through the optional add-on package and the same model-provider bridge as an offline proof of concept.
- The ExtensionKit/XPC backend launches in the simulator and can initialize Python, import Hermes, create a Hermes session, run iSH-backed terminal commands, and use file read/write tools out of process.

## Known Boundaries

- Hermes is still the only agent implementation. The package shape is ready for more, but the generic agent API is intentionally thin until a second implementation proves it.
- Many desktop-style tools remain inappropriate for iOS: browser automation, MCP stdio servers, runtime package installation outside the guest rootfs, and desktop computer-use.
- The iSH backend currently supports one embedded shell session per process. Multiple concurrent sessions need more invasive iSH state isolation.
- Out-of-process execution requires iOS 26+ and an app-owned ExtensionKit extension target. SPM cannot silently create or sign that target for a consuming app.
- The package-level `HermesAgent(configuration:)` convenience initializer still runs in process unless the app explicitly passes `HermesExtensionProcessBackend`. The sample defaults to the extension backend on iOS 26+.
- The bundled full Alpine fakefs is large; a distributable package should eventually build a smaller purpose-made rootfs.
- The optional local MLX model provider is a POC. The 2B model can run offline, but it is weak at tool use compared with a hosted model.
- Generic `iphoneos` build can be verified with `CODE_SIGNING_ALLOWED=NO`; real device install still needs normal Apple signing/provisioning.
