#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_XCFRAMEWORK="${PYTHON_XCFRAMEWORK:-$ROOT_DIR/Vendor/Python.xcframework}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/Build/native-wheels}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/Build/wheelhouse}"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-17.0}"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

prepare_pyo3_config() {
  local platform="$1"
  local slice="$2"
  local platform_config="$3"
  local ext_suffix="$4"
  local config_dir="$BUILD_DIR/pyo3-$platform"

  rm -rf "$config_dir"
  mkdir -p "$config_dir/lib"
  cp "$PYTHON_XCFRAMEWORK/$slice/lib/libpython3.14.dylib" "$config_dir/lib/"
  cp "$PYTHON_XCFRAMEWORK/$slice/platform-config/$platform_config" "$config_dir/lib/"
  cp "$PYTHON_XCFRAMEWORK/$slice/include/python3.14/pyconfig.h" "$config_dir/lib/"

  cat > "$config_dir/pyo3-config.txt" <<EOF
implementation=CPython
version=3.14
shared=true
abi3=false
lib_name=python3.14
lib_dir=$config_dir/lib
executable=$PYTHON_XCFRAMEWORK/$slice/bin/python3.14
pointer_width=64
build_flags=
suppress_build_script_link_lines=false
ext_suffix=$ext_suffix
EOF
}

download_sdist() {
  local name="$1"
  local version="$2"
  local dest="$BUILD_DIR/$name-$version"

  if [ ! -d "$dest" ]; then
    rm -rf "$BUILD_DIR/download-$name"
    mkdir -p "$BUILD_DIR/download-$name"
    python3 -m pip download --no-binary=:all: --no-deps --dest "$BUILD_DIR/download-$name" "$name==$version"
    tar -xzf "$BUILD_DIR/download-$name/$name-$version.tar.gz" -C "$BUILD_DIR/download-$name"
    mv "$BUILD_DIR/download-$name/$name-$version" "$dest"
  fi

  echo "$dest"
}

build_rust_wheel() {
  local package_dir="$1"
  local platform="$2"
  local target="$3"
  local linker="$4"
  local ar="$5"
  local config_dir="$BUILD_DIR/pyo3-$platform"
  local target_env="${target//-/_}"
  target_env="${target_env^^}"

  (
    cd "$package_dir"
    env \
      PYO3_CONFIG_FILE="$config_dir/pyo3-config.txt" \
      IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" \
      "CARGO_TARGET_${target_env}_LINKER=$linker" \
      "AR_${target//-/_}=$ar" \
      RUSTFLAGS="-L native=$config_dir/lib -l dylib=python3.14" \
      uvx maturin build --release --target "$target" --out "$OUT_DIR/$platform"
  )
}

prepare_pyo3_config \
  iphonesimulator \
  ios-arm64_x86_64-simulator \
  arm64-iphonesimulator/_sysconfigdata__ios_arm64-iphonesimulator.py \
  .cpython-314-iphonesimulator.so

prepare_pyo3_config \
  iphoneos \
  ios-arm64 \
  arm64-iphoneos/_sysconfigdata__ios_arm64-iphoneos.py \
  .cpython-314-iphoneos.so

JITER_DIR="$(download_sdist jiter 0.13.0)"
PYDANTIC_CORE_DIR="$(download_sdist pydantic_core 2.41.5)"

build_rust_wheel \
  "$JITER_DIR" \
  iphonesimulator \
  aarch64-apple-ios-sim \
  "$PYTHON_XCFRAMEWORK/ios-arm64_x86_64-simulator/bin/arm64-apple-ios-simulator-clang" \
  "$PYTHON_XCFRAMEWORK/ios-arm64_x86_64-simulator/bin/arm64-apple-ios-simulator-ar"

build_rust_wheel \
  "$PYDANTIC_CORE_DIR" \
  iphonesimulator \
  aarch64-apple-ios-sim \
  "$PYTHON_XCFRAMEWORK/ios-arm64_x86_64-simulator/bin/arm64-apple-ios-simulator-clang" \
  "$PYTHON_XCFRAMEWORK/ios-arm64_x86_64-simulator/bin/arm64-apple-ios-simulator-ar"

build_rust_wheel \
  "$JITER_DIR" \
  iphoneos \
  aarch64-apple-ios \
  "$PYTHON_XCFRAMEWORK/ios-arm64/bin/arm64-apple-ios-clang" \
  "$PYTHON_XCFRAMEWORK/ios-arm64/bin/arm64-apple-ios-ar"

build_rust_wheel \
  "$PYDANTIC_CORE_DIR" \
  iphoneos \
  aarch64-apple-ios \
  "$PYTHON_XCFRAMEWORK/ios-arm64/bin/arm64-apple-ios-clang" \
  "$PYTHON_XCFRAMEWORK/ios-arm64/bin/arm64-apple-ios-ar"

echo "Built wheels in $OUT_DIR"
