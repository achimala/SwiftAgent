#!/bin/sh
set -euo pipefail

if [ -z "${CODESIGNING_FOLDER_PATH:-}" ]; then
  echo "CODESIGNING_FOLDER_PATH is not set. Run this from an Xcode app target build phase."
  exit 1
fi

if [ -z "${EFFECTIVE_PLATFORM_NAME:-}" ]; then
  echo "EFFECTIVE_PLATFORM_NAME is not set. Run this from an Xcode app target build phase."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
AGENTKIT_PACKAGE_DIR="${AGENTKIT_PACKAGE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
PYTHON_APP_SOURCE="${AGENTKIT_PYTHON_APP_SOURCE:-}"
PYTHON_APP_SOURCE_IS_DEFAULT=0

if [ -z "$PYTHON_APP_SOURCE" ]; then
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR/PythonApp" ]; then
    PYTHON_APP_SOURCE="$PROJECT_DIR/PythonApp"
  elif [ -d "$AGENTKIT_PACKAGE_DIR/Payloads/Hermes/PythonApp" ]; then
    PYTHON_APP_SOURCE="$AGENTKIT_PACKAGE_DIR/Payloads/Hermes/PythonApp"
    PYTHON_APP_SOURCE_IS_DEFAULT=1
  else
    PYTHON_APP_SOURCE="$AGENTKIT_PACKAGE_DIR/Payloads/Hermes/PythonApp"
    PYTHON_APP_SOURCE_IS_DEFAULT=1
  fi
fi

PYTHON_XCFRAMEWORK="${AGENTKIT_PYTHON_XCFRAMEWORK:-$AGENTKIT_PACKAGE_DIR/Vendor/Python.xcframework}"

if [ ! -d "$PYTHON_APP_SOURCE" ]; then
  echo "AgentKit Python app payload was not found at: $PYTHON_APP_SOURCE"
  echo "Set AGENTKIT_PYTHON_APP_SOURCE to a directory containing hermes, site-packages, and platform package overlays."
  echo "For AgentKit development, run: Scripts/update-hermes.sh"
  exit 1
fi

if [ ! -d "$PYTHON_APP_SOURCE/hermes" ] &&
   [ "$PYTHON_APP_SOURCE_IS_DEFAULT" = "1" ] &&
   [ "${AGENTKIT_AUTO_FETCH_HERMES:-YES}" != "NO" ]; then
  echo "AgentKit Hermes source is missing; fetching pinned Hermes payload..."
  AGENTKIT_HERMES_PAYLOAD_DIR="$PYTHON_APP_SOURCE" "$SCRIPT_DIR/update-hermes.sh"
fi

if [ ! -d "$PYTHON_APP_SOURCE/hermes" ]; then
  echo "AgentKit Hermes source was not found at: $PYTHON_APP_SOURCE/hermes"
  echo "Run Scripts/update-hermes.sh, leave AGENTKIT_AUTO_FETCH_HERMES enabled, or set AGENTKIT_PYTHON_APP_SOURCE to a complete PythonApp payload."
  exit 1
fi

if [ ! -d "$PYTHON_XCFRAMEWORK" ]; then
  echo "AgentKit Python.xcframework was not found at: $PYTHON_XCFRAMEWORK"
  echo "Set AGENTKIT_PYTHON_XCFRAMEWORK to the vendored Python.xcframework path."
  exit 1
fi

case "$EFFECTIVE_PLATFORM_NAME" in
  -iphonesimulator)
    PLATFORM_PACKAGES="site-packages-iphonesimulator"
    ;;
  -iphoneos)
    PLATFORM_PACKAGES="site-packages-iphoneos"
    ;;
  *)
    echo "Unsupported platform for AgentKit Python packages: $EFFECTIVE_PLATFORM_NAME"
    exit 1
    ;;
esac

DESTINATION="$CODESIGNING_FOLDER_PATH/PythonApp"
echo "Installing AgentKit Python payload"
echo "  source: $PYTHON_APP_SOURCE"
echo "  destination: $DESTINATION"
echo "  platform packages: $PLATFORM_PACKAGES"

rm -rf "$DESTINATION"
mkdir -p "$DESTINATION/site-packages"

rsync -a --delete \
  --exclude "/site-packages/" \
  --exclude "/site-packages-iphoneos/" \
  --exclude "/site-packages-iphonesimulator/" \
  "$PYTHON_APP_SOURCE/" \
  "$DESTINATION/"

if [ -d "$PYTHON_APP_SOURCE/site-packages" ]; then
  rsync -a --delete \
    "$PYTHON_APP_SOURCE/site-packages/" \
    "$DESTINATION/site-packages/"
fi

if [ -d "$PYTHON_APP_SOURCE/$PLATFORM_PACKAGES" ]; then
  rsync -a \
    "$PYTHON_APP_SOURCE/$PLATFORM_PACKAGES/" \
    "$DESTINATION/site-packages/"
else
  echo "Required platform package overlay missing: $PYTHON_APP_SOURCE/$PLATFORM_PACKAGES"
  exit 1
fi

export EXPANDED_CODE_SIGN_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
export EXPANDED_CODE_SIGN_IDENTITY_NAME="${EXPANDED_CODE_SIGN_IDENTITY_NAME:-Sign to Run Locally}"
export ARCHS="${ARCHS:-${NATIVE_ARCH_ACTUAL:-$(uname -m)}}"
if [ -z "${PRODUCT_BUNDLE_IDENTIFIER:-}" ] && [ -f "$CODESIGNING_FOLDER_PATH/Info.plist" ]; then
  PRODUCT_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$CODESIGNING_FOLDER_PATH/Info.plist" 2>/dev/null || true)"
fi
export PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-com.agentkit.bundle}"

ORIGINAL_PROJECT_DIR="${PROJECT_DIR:-}"
PROJECT_DIR="$(cd "$(dirname "$PYTHON_XCFRAMEWORK")" && pwd -P)"
PYTHON_XCFRAMEWORK_NAME="$(basename "$PYTHON_XCFRAMEWORK")"

source "$PYTHON_XCFRAMEWORK/build/utils.sh"
install_python "$PYTHON_XCFRAMEWORK_NAME" "PythonApp/site-packages"

if [ -n "$ORIGINAL_PROJECT_DIR" ]; then
  PROJECT_DIR="$ORIGINAL_PROJECT_DIR"
fi

if [ -n "${BUILT_PRODUCTS_DIR:-}" ]; then
  FRAMEWORKS_DESTINATION="$CODESIGNING_FOLDER_PATH/Frameworks"
  mkdir -p "$FRAMEWORKS_DESTINATION"

  for FRAMEWORK_NAME in Python ios_system awk dash files shell text; do
    FRAMEWORK_SOURCE="$BUILT_PRODUCTS_DIR/$FRAMEWORK_NAME.framework"
    if [ -d "$FRAMEWORK_SOURCE" ]; then
      echo "Installing AgentKit binary framework: $FRAMEWORK_NAME.framework"
      rsync -a --delete "$FRAMEWORK_SOURCE/" "$FRAMEWORKS_DESTINATION/$FRAMEWORK_NAME.framework/"
      if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ "${EXPANDED_CODE_SIGN_IDENTITY:-}" != "-" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        echo "Signing AgentKit binary framework: $FRAMEWORK_NAME.framework"
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
          "$FRAMEWORKS_DESTINATION/$FRAMEWORK_NAME.framework"
      fi
    fi
  done
fi
