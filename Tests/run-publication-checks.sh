#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
PUBLICATION_CHECK_DIR=$(mktemp -d /private/tmp/CleanMac-publication-build.XXXXXX)
mkdir "$PUBLICATION_CHECK_DIR/Release"
PUBLICATION_SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -O -swift-version 5 -default-isolation MainActor -sdk "$PUBLICATION_SDK_PATH" \
  CleanMac/Models/*.swift CleanMac/Engine/*.swift CleanMac/Support/*.swift \
  CleanMac/ViewModel/ScannerViewModel.swift Tests/ScanPublicationChecks.swift \
  -o "$PUBLICATION_CHECK_DIR/Release/ScanPublicationChecks"
/usr/bin/time -l "$PUBLICATION_CHECK_DIR/Release/ScanPublicationChecks"
