#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
AGENTKIT_PACKAGE_DIR="${AGENTKIT_PACKAGE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
LOCK_FILE="${AGENTKIT_HERMES_LOCK_FILE:-$AGENTKIT_PACKAGE_DIR/Vendor/hermes-agent.lock}"

if [ ! -f "$LOCK_FILE" ]; then
  echo "Hermes lock file was not found: $LOCK_FILE"
  exit 1
fi

# shellcheck disable=SC1090
. "$LOCK_FILE"

: "${HERMES_REPOSITORY:?HERMES_REPOSITORY is required in $LOCK_FILE}"
: "${HERMES_TAG:?HERMES_TAG is required in $LOCK_FILE}"
: "${HERMES_VERSION:?HERMES_VERSION is required in $LOCK_FILE}"
: "${HERMES_COMMIT:?HERMES_COMMIT is required in $LOCK_FILE}"

CACHE_DIR="${AGENTKIT_HERMES_CACHE_DIR:-$AGENTKIT_PACKAGE_DIR/Build/hermes-agent-src}"
STAGE_DIR="${AGENTKIT_HERMES_STAGE_DIR:-$AGENTKIT_PACKAGE_DIR/Build/hermes-agent-stage}"
PAYLOAD_DIR="${AGENTKIT_HERMES_PAYLOAD_DIR:-$AGENTKIT_PACKAGE_DIR/Payloads/Hermes/PythonApp}"

if [ ! -d "$CACHE_DIR/.git" ]; then
  rm -rf "$CACHE_DIR"
  mkdir -p "$(dirname "$CACHE_DIR")"
  git clone --filter=blob:none --no-checkout "$HERMES_REPOSITORY" "$CACHE_DIR"
fi

git -C "$CACHE_DIR" remote set-url origin "$HERMES_REPOSITORY"
git -C "$CACHE_DIR" fetch --force --tags origin "refs/tags/$HERMES_TAG:refs/tags/$HERMES_TAG"

RESOLVED_COMMIT="$(git -C "$CACHE_DIR" rev-parse "$HERMES_TAG^{commit}")"
if [ "$RESOLVED_COMMIT" != "$HERMES_COMMIT" ]; then
  echo "Hermes lock mismatch for $HERMES_TAG"
  echo "  expected: $HERMES_COMMIT"
  echo "  resolved: $RESOLVED_COMMIT"
  echo "Update $LOCK_FILE only after reviewing the upstream release."
  exit 1
fi

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" "$PAYLOAD_DIR"
git -C "$CACHE_DIR" archive "$HERMES_COMMIT" | tar -x -C "$STAGE_DIR"

ACTUAL_VERSION="$(awk -F '"' '/^version = / { print $2; exit }' "$STAGE_DIR/pyproject.toml")"
if [ "$ACTUAL_VERSION" != "$HERMES_VERSION" ]; then
  echo "Hermes version mismatch in pyproject.toml"
  echo "  lock file: $HERMES_VERSION"
  echo "  source:    $ACTUAL_VERSION"
  exit 1
fi

rm -rf "$PAYLOAD_DIR/hermes"
rsync -a --delete \
  --exclude "/.git/" \
  --exclude "/.github/" \
  --exclude "/.plans/" \
  --exclude "/AGENTS.md" \
  --exclude "/CONTRIBUTING.md" \
  --exclude "/Dockerfile" \
  --exclude "/README.zh-CN.md" \
  --exclude "/RELEASE_*.md" \
  --exclude "/SECURITY.md" \
  --exclude "/datagen-config-examples/" \
  --exclude "/docs/" \
  --exclude "/docker/" \
  --exclude "/flake.lock" \
  --exclude "/flake.nix" \
  --exclude "/nix/" \
  --exclude "/package-lock.json" \
  --exclude "/package.json" \
  --exclude "/plugins/*/dashboard/" \
  --exclude "/plugins/*/docs/" \
  --exclude "/plugins/*/tests/" \
  --exclude "tests/" \
  --exclude "/tinker-atropos/" \
  --exclude "/ui-tui/" \
  --exclude "/web/" \
  --exclude "/website/" \
  "$STAGE_DIR/" "$PAYLOAD_DIR/hermes/"

if [ ! -d "$PAYLOAD_DIR/site-packages" ]; then
  echo "Warning: $PAYLOAD_DIR/site-packages is missing."
  echo "The Hermes source was updated, but Python dependency layers still need to be staged."
fi

echo "Updated Hermes payload"
echo "  source:  $HERMES_REPOSITORY"
echo "  tag:     $HERMES_TAG"
echo "  commit:  $HERMES_COMMIT"
echo "  version: $HERMES_VERSION"
echo "  payload: $PAYLOAD_DIR/hermes"
