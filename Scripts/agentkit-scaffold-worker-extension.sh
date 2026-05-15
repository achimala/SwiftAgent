#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  agentkit-scaffold-worker-extension.sh --host-bundle-id com.example.MyApp [options]

Options:
  --output-dir PATH              Directory to create. Default: ./AgentKitAgentWorker
  --extension-point-name NAME    Extension point name. Default: agentkit-agent-worker
  --host-bundle-id ID            Host app bundle identifier. Required.

This creates the Swift/Info.plist boilerplate for an AgentKit ExtensionKit
worker. It does not edit your Xcode project; add the generated files to a new
ExtensionKit extension target, link AgentKit, and embed that extension in the
host app.
EOF
}

output_dir="AgentKitAgentWorker"
extension_point_name="agentkit-agent-worker"
host_bundle_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)
      output_dir="${2:?missing value for --output-dir}"
      shift 2
      ;;
    --extension-point-name)
      extension_point_name="${2:?missing value for --extension-point-name}"
      shift 2
      ;;
    --host-bundle-id)
      host_bundle_id="${2:?missing value for --host-bundle-id}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$host_bundle_id" ]]; then
  echo "--host-bundle-id is required" >&2
  usage >&2
  exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
template_dir="$(cd "$script_dir/../Templates/AgentKitWorkerExtension" && pwd)"
mkdir -p "$output_dir"

for file in AgentKitAgentWorker.swift AgentKitWorkerExtensionPoint.swift Info.plist; do
  sed \
    -e "s/__AGENTKIT_HOST_BUNDLE_ID__/$host_bundle_id/g" \
    -e "s/__AGENTKIT_EXTENSION_POINT_NAME__/$extension_point_name/g" \
    "$template_dir/$file" > "$output_dir/$file"
done

cat <<EOF
Created AgentKit worker boilerplate in:
  $output_dir

Next steps:
  1. Add an ExtensionKit extension target to your iOS app.
  2. Add $output_dir/AgentKitAgentWorker.swift and $output_dir/Info.plist to that extension target.
  3. Add $output_dir/AgentKitWorkerExtensionPoint.swift to the host app target.
  4. Link AgentKit from both targets.
  5. Add the AgentKit Python packaging run script to both the app and extension targets.
EOF
