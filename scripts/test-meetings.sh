#!/bin/bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${REPOSE_TEST_BUILD_DIR:-${TMPDIR:-/tmp/}repose-meeting-tests}"
SDK_PATH="${REPOSE_SDK_PATH:-$(xcrun --show-sdk-path)}"
mkdir -p "$BUILD_DIR"
swiftc -swift-version 5 -parse-as-library -D TESTING -sdk "$SDK_PATH" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$ROOT_DIR/Repose/MeetingDetector.swift" \
    "$ROOT_DIR/Repose/TimerManager.swift" \
    "$ROOT_DIR/Tests/MeetingRegressionTests.swift" -o "$BUILD_DIR/meeting-tests"
"$BUILD_DIR/meeting-tests"
