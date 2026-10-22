#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
CLI_CHECK_ROOT=$(mktemp -d /private/tmp/CleanMac-cli-checks.XXXXXX)
mkdir "$CLI_CHECK_ROOT/Release"
CLI_CHECK_SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -O -sdk "$CLI_CHECK_SDK" -parse-as-library Tests/CLIChecks.swift -o "$CLI_CHECK_ROOT/Release/CLIChecks"
"$CLI_CHECK_ROOT/Release/CLIChecks" "$PWD/build/Build/Products/Release/cleanmac" "$CLI_CHECK_ROOT/data"
