#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${AGENT_WATCH_BUILD_DIR:-$project_dir/.build}"
build_target="$(uname -m)-apple-macosx14.0"
compile_check() {
  command swiftc -target "$build_target" -module-cache-path "$build_dir/swift-module-cache" "$@"
}
package_options=()
if [ "${AGENT_WATCH_NESTED_SANDBOX_UNAVAILABLE:-0}" = 1 ]; then
  package_options+=(--disable-sandbox)
fi
swift build "${package_options[@]}" --package-path "$project_dir" --scratch-path "$build_dir"
compile_check -swift-version 6 \
  "$project_dir/Sources/AgentWatchProbe/Catalog.swift" \
  "$project_dir/Sources/AgentWatchProbe/Options.swift" \
  "$project_dir/Sources/AgentWatchProbe/Inventory.swift" \
  "$project_dir/Sources/AgentWatchProbe/Report.swift" \
  "$project_dir/Sources/AgentWatchProbe/AccessibilityProbe.swift" \
  "$project_dir/Tests/ProbeChecks.swift" \
  -o "$build_dir/probe-checks"
"$build_dir/probe-checks"
binary_dir="$(swift build "${package_options[@]}" --package-path "$project_dir" --scratch-path "$build_dir" --show-bin-path)"
python3 "$project_dir/Tests/check_cli.py" "$binary_dir/agent-watch-probe"
"$binary_dir/CoreChecks"
compile_check -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
  "$binary_dir/AgentWatchCore.build/"*.swift.o \
  "$project_dir/Sources/AgentWatchMonitor/ChromiumAccessibility.swift" \
  "$project_dir/Sources/AgentWatchMonitor/WindowIdentity.swift" \
  "$project_dir/Sources/AgentWatchMonitor/WindowAdapter.swift" \
  "$project_dir/Tests/WindowRuleChecks.swift" -o "$build_dir/window-checks"
"$build_dir/window-checks"
compile_check -swift-version 6 -parse-as-library \
  -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CoreFoundation \
  "$project_dir/Sources/AgentWatchMonitor/ChromiumAccessibility.swift" \
  "$project_dir/Sources/AgentWatchMonitor/WindowIdentity.swift" \
  "$project_dir/Tests/WindowIdentityChecks.swift" \
  -o "$build_dir/window-identity-checks"
"$build_dir/window-identity-checks"
compile_check -swift-version 6 -parse-as-library \
  -framework AppKit -framework ApplicationServices -framework CoreFoundation \
  "$project_dir/Sources/AgentWatchMonitor/ChromiumAccessibility.swift" \
  "$project_dir/Tests/ChromiumAccessibilityChecks.swift" \
  -o "$build_dir/chromium-accessibility-checks"
"$build_dir/chromium-accessibility-checks"
python3 "$project_dir/Tests/check_hooks.py"
python3 "$project_dir/Tests/check_devin.py"
python3 "$project_dir/Tests/check_devin_local.py"
python3 "$project_dir/Tests/check_antigravity.py"
python3 "$project_dir/Tests/check_codex_rollouts.py"
python3 "$project_dir/Tests/check_claude_desktop.py"
python3 "$project_dir/Tests/check_claude_code_records.py"
compile_check -swift-version 6 -parse-as-library \
  "$project_dir/Sources/AgentWatchMonitor/GeminiAdapter.swift" \
  "$project_dir/Tests/GeminiAdapterChecks.swift" -o "$build_dir/gemini-checks"
"$build_dir/gemini-checks"
compile_check -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
  "$binary_dir/AgentWatchCore.build/"*.swift.o \
  "$project_dir/Sources/AgentWatchMonitor/ChromiumAccessibility.swift" \
  "$project_dir/Sources/AgentWatchMonitor/WindowIdentity.swift" \
  "$project_dir/Sources/AgentWatchMonitor/WindowAdapter.swift" \
  "$project_dir/Sources/AgentWatchMonitor/LiveCatalog.swift" \
  "$project_dir/Sources/AgentWatchMonitor/ClaudeChatAdapter.swift" \
  "$project_dir/Sources/AgentWatchMonitor/ClaudeCancellation.swift" \
  "$project_dir/Sources/AgentWatchMonitor/EventInbox.swift" \
  "$project_dir/Tests/check_inbox.swift" -o "$build_dir/inbox-checks"
"$build_dir/inbox-checks"
compile_check -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
  "$binary_dir/AgentWatchCore.build/"*.swift.o \
  "$project_dir/Sources/AgentWatchMonitor/ClaudeChatAdapter.swift" \
  "$project_dir/Tests/ClaudeChatAdapterChecks.swift" -o "$build_dir/claude-scope-checks"
"$build_dir/claude-scope-checks"
node --test "$project_dir/adapters/dsh/test/fixture.test.mjs"
compile_check -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
  "$binary_dir/AgentWatchCore.build/"*.swift.o \
  "$project_dir/Tests/StatusSummaryChecks.swift" -o "$build_dir/status-summary-checks"
"$build_dir/status-summary-checks"
