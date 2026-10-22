#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /private/tmp/CleanMac-overview-checks.XXXXXX)
mkdir "$CHECK_DIR/Release"
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
xcrun swiftc -O -sdk "$SDK_PATH" \
  CleanMac/Models/DiskModels.swift CleanMac/Models/CleanupModels.swift CleanMac/Models/OverviewModels.swift \
  CleanMac/Engine/ParallelCore.swift CleanMac/Engine/DirectoryScanner.swift CleanMac/Engine/CleanupEngine.swift \
  CleanMac/Engine/AppInventory.swift CleanMac/Engine/UsageEvidenceCollector.swift \
  CleanMac/Engine/OverviewAttribution.swift CleanMac/Engine/OverviewReportEngine.swift \
  CleanMac/Support/ScanToken.swift CleanMac/Support/CleanMacFormat.swift \
  CleanMac/Support/CleanMacPath.swift CleanMac/Support/ScanCacheStore.swift \
  CleanMac/Support/AgentAnalysisHandoff.swift Tests/OverviewChecks.swift \
  -o "$CHECK_DIR/Release/OverviewChecks"
"$CHECK_DIR/Release/OverviewChecks"
