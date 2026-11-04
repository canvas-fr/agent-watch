#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${AGENT_WATCH_BUILD_DIR:-$project_dir/.build}"
swift build --package-path "$project_dir" --scratch-path "$build_dir"
swiftc -swift-version 6 \
  "$project_dir/Sources/AgentWatchProbe/Catalog.swift" \
  "$project_dir/Sources/AgentWatchProbe/Options.swift" \
  "$project_dir/Sources/AgentWatchProbe/Inventory.swift" \
  "$project_dir/Sources/AgentWatchProbe/Report.swift" \
  "$project_dir/Sources/AgentWatchProbe/AccessibilityProbe.swift" \
  "$project_dir/Tests/ProbeChecks.swift" \
  -o "$build_dir/probe-checks"
"$build_dir/probe-checks"
binary_dir="$(swift build --package-path "$project_dir" --scratch-path "$build_dir" --show-bin-path)"
python3 "$project_dir/Tests/check_cli.py" "$binary_dir/agent-watch-probe"
"$binary_dir/CoreChecks"
swiftc -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
  "$binary_dir/AgentWatchCore.build/"*.swift.o \
  "$project_dir/Sources/AgentWatchMonitor/WindowAdapter.swift" \
  "$project_dir/Tests/WindowRuleChecks.swift" -o "$build_dir/window-checks"
"$build_dir/window-checks"
python3 "$project_dir/Tests/check_hooks.py"
python3 "$project_dir/Tests/check_devin.py"
python3 "$project_dir/Tests/check_devin_local.py"
python3 "$project_dir/Tests/check_antigravity.py"
swiftc -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
  "$binary_dir/AgentWatchCore.build/"*.swift.o \
  "$project_dir/Sources/AgentWatchMonitor/WindowAdapter.swift" \
  "$project_dir/Sources/AgentWatchMonitor/LiveCatalog.swift" \
  "$project_dir/Sources/AgentWatchMonitor/EventInbox.swift" \
  "$project_dir/Tests/check_inbox.swift" -o "$build_dir/inbox-checks"
"$build_dir/inbox-checks"
node --test "$project_dir/adapters/dsh/test/fixture.test.mjs"
swiftc -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
  "$binary_dir/AgentWatchCore.build/"*.swift.o \
  "$project_dir/Tests/StatusSummaryChecks.swift" -o "$build_dir/status-summary-checks"
"$build_dir/status-summary-checks"
