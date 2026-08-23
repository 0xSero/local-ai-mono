#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

manifest="$LOCAL_AI_ROOT/manifest.json"
jq -e '
  .schemaVersion == 1
  and (.id | startswith("omarchy.") | not)
  and (.kinds == ["bar-widget"])
  and (.entryPoints.barWidget | type == "string")
' "$manifest" >/dev/null || fail "root manifest follows the third-party plugin contract"
entry_point=$(jq -r '.entryPoints.barWidget' "$manifest")
[[ -f "$LOCAL_AI_ROOT/$entry_point" ]] || fail "bar widget entry point exists"
pass "the repository root is an installable third-party plugin"

panel="$LOCAL_AI_ROOT/$entry_point"
grep -q 'manifest.__sourceDir' "$panel" || fail "the panel resolves plugin-local commands"
grep -q 'Component.onDestruction: enabled = false' "$panel" || fail "the IPC handler shuts down before hot reload destruction"
if grep -q 'command: \["omarchy-ai-' "$panel"; then fail "the panel depends on global plugin commands"; fi
pass "the panel is self-contained and guards IPC teardown"

while read -r command; do
  grep -q '^# omarchy:summary=' "$command" || fail "missing command summary: $command"
  grep -q '^# omarchy:group=ai$' "$command" || fail "missing command group: $command"
done < <(find "$LOCAL_AI_ROOT/bin" -maxdepth 1 -type f -name 'omarchy-ai-*' | sort)
pass "every plugin command carries discoverable metadata"

if rg -n 'omarchy\.local-ai|omarchy\.fable' "$LOCAL_AI_ROOT" -g '!test/plugin-test.sh' >/dev/null; then
  fail "the third-party plugin still claims a reserved Omarchy id"
fi
pass "the plugin claims no reserved first-party identity"

echo "# plugin: $PASS passed"
