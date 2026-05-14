# HermesAgentKit

HermesAgentKit is a proof-of-concept Swift package for embedding CPython on iOS and loading the real Python Hermes agent from an app bundle.

The current POC intentionally avoids patching Hermes source. Unsupported iOS capabilities are excluded through packaging/configuration: the sample instantiates `AIAgent` with the `safe` toolset, skips memory/context files/soul identity, and uses a dummy OpenAI-compatible endpoint so construction can be tested without making a model request.

## What Is Included

- `Vendor/Python.xcframework`: BeeWare Python 3.14 for iOS.
- `Sources/CHermesPython`: a tiny C bridge around `PyConfig` initialization and Python evaluation.
- `Sources/HermesAgentKit`: a Swift runtime API that initializes Python, runs a Hermes probe, and sends chat messages into Hermes with stream callbacks.
- `Examples/HermesAgentSample`: an iOS app that bundles Hermes source plus vendored Python dependencies.
- `Scripts/build-native-wheels.sh`: a reproducible recipe for rebuilding the Rust-backed iOS wheels used by OpenAI/Pydantic.

## Try the Sample

```bash
rtk cd Examples/HermesAgentSample
rtk xcodegen generate
rtk xcodebuild -project HermesAgentSample.xcodeproj -scheme HermesAgentSample -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build
rtk xcrun simctl install booted ~/Library/Developer/Xcode/DerivedData/HermesAgentSample-eqgicvlbvbqhprgqnxtyipafsxsd/Build/Products/Debug-iphonesimulator/HermesAgentSample.app
rtk xcrun simctl launch booted com.daysail.HermesAgentSample
```

Tap **Probe** to verify initialization, or fill in Base URL / API key / Model and tap **Send** to run a Hermes chat turn. The app writes the full output to `Documents/hermes-probe-output.txt` in the simulator app container.

## Current Result

Verified on iOS Simulator 26.5:

- Embedded CPython 3.14 initializes from the app bundle.
- The app imports the package bootstrap module from the Swift package resource bundle.
- The app imports real Hermes `run_agent.py` from bundled source.
- The app constructs `run_agent.AIAgent` successfully.
- Native dependencies `jiter` and `pydantic_core` are packaged as iOS frameworks via BeeWare’s `.fwork` mechanism.

The current Hermes probe result:

```json
{
  "agent_class": "run_agent.AIAgent",
  "ok": true,
  "stage": "instantiate",
  "tool_names": []
}
```

The `tool_names` list is empty because the current probe uses the constrained `safe` toolset and only vendors enough dependencies to construct the core agent and OpenAI client. It has not yet attempted a real LLM request or any desktop/tool execution path.

The chat path has also been smoke-tested with the default dummy key against `https://api.openai.com/v1`. That proves bidirectional control and error return through Hermes:

```json
{
  "api_calls": 1,
  "bridge_ok": true,
  "completed": false,
  "error": "Error code: 401 - ... invalid_api_key ...",
  "final_response": null,
  "ok": false,
  "stage": "chat"
}
```

With a valid OpenAI-compatible endpoint, API key, and model, the same bridge should stream text deltas through the Swift callback. That still needs a live credential smoke.

## Dependency Packaging Shape

Third-party Python packages are staged in the sample app, not in the Swift package resource bundle:

- `PythonApp/site-packages`: pure Python/common dependencies.
- `PythonApp/site-packages-iphonesimulator`: simulator-native wheels.
- `PythonApp/site-packages-iphoneos`: device-native wheels.

The app target build script overlays the correct platform layer into `PythonApp/site-packages`, then runs BeeWare’s `install_python` helper to convert `.so` extension modules into signed app frameworks.

This matters because SwiftPM resource bundles are copied at a point in the Xcode build that is awkward for native Python extension post-processing. App-level staging gives the build script a stable place to process native modules.

## Rebuilding Native Wheels

The two native wheels currently needed for OpenAI/Pydantic are `jiter==0.13.0` and `pydantic_core==2.41.5`.

```bash
rtk ./Scripts/build-native-wheels.sh
```

That builds simulator and device wheels into `Build/wheelhouse`. Updating the checked-in sample package layers still needs a small vendor step: unzip the `iphonesimulator` wheels into `Examples/HermesAgentSample/HermesAgentSample/PythonApp/site-packages-iphonesimulator` and the `iphoneos` wheels into `Examples/HermesAgentSample/HermesAgentSample/PythonApp/site-packages-iphoneos`.

## Known Boundaries

- Real agent conversation requires wiring an actual OpenAI-compatible endpoint and handling network errors/timeouts on iOS.
- Many Hermes tools remain inappropriate for iOS: terminal/process execution, PTYs, subprocess browser automation, MCP stdio servers, runtime package installation, and desktop computer-use.
- Additional Hermes toolsets will pull in more dependencies. Some are pure Python; others may require more iOS-native wheels.
- Generic `iphoneos` build has been verified with `CODE_SIGNING_ALLOWED=NO`; real device install still needs normal Apple signing/provisioning.
