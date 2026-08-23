#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox
export OMARCHY_AI_SHIPPED="$LOCAL_AI_ROOT/share/registry.json"
source "$LOCAL_AI_ROOT/lib/hardware.sh"
source "$LOCAL_AI_ROOT/lib/registry.sh"
source "$LOCAL_AI_ROOT/lib/models.sh"

ONE='[24564]'; TWO='[24564,24564]'; FOUR='[24564,24564,24564,24564]'; SMALL='[16384]'
fast1=$(registry_get qwen36-tp1); fast2=$(registry_get qwen36-tp2); fast4=$(registry_get qwen36-tp4)
smart2=$(registry_get qwen38-tp2)

model_fits "$fast1" "$ONE" || fail "TP1 fits one 24 GB card"
if model_fits "$fast2" "$ONE"; then fail "TP2 must not collapse onto one card"; fi
model_fits "$smart2" "$TWO" || fail "smart TP2 fits two cards"
if model_fits "$fast1" "$SMALL"; then fail "a 16 GB card fits nothing"; fi
pass "each immutable topology enforces its own card count"

assert_eq "$(model_autopick "$ONE" | jq -r .name)" "qwen36-tp1" "one card auto-picks the fast TP1 recipe"
assert_eq "$(model_autopick "$TWO" | jq -r .name)" "qwen36-tp2" "two cards auto-pick the fast TP2 recipe"
assert_eq "$(model_autopick "$FOUR" | jq -r .name)" "qwen36-tp4" "four cards auto-pick the fast TP4 recipe"
if model_autopick "$SMALL" >/dev/null 2>&1; then fail "nothing fits a small card"; fi
pass "auto-pick chooses a concrete recipe instead of scaling one"

assert_eq "$(model_resolve qwen36-tp1 "$ONE" | jq -r .name)" "qwen36-tp1" "a named recipe resolves"
assert_eq "$(model_resolve qwen38-tp1 "$ONE" | jq -r .name)" "qwen38-tp1" "smart TP1 is reachable on one card"
if model_resolve qwen38-tp1 "$SMALL" 2>/dev/null; then fail "a 16 GB card is refused"; fi
if model_resolve nope "$ONE" 2>/dev/null; then fail "an unknown name is refused"; fi
pass "named models resolve and refuse honestly"

provider=$(model_provider_json "$fast4" "http://127.0.0.1:12434/v1")
assert_eq "$(jq -r '.api' <<<"$provider")" "openai-completions" "provider speaks the openai api"
assert_eq "$(jq -c '.models[0].input' <<<"$provider")" '["text","image"]' "a vision model gets image input"
assert_eq "$(jq -r '.models[0].maxTokens' <<<"$provider")" "$(jq -r '.models[0].contextWindow' <<<"$provider")" "generation is never capped below the context window"
assert_eq "$(jq -r '.models[0].compat.maxTokensField' <<<"$provider")" "max_completion_tokens" "agents use the current completion limit field"
pass "the provider block is shaped for the agents"

model_record "$fast2" 12434
assert_eq "$(model_active_name)" "qwen36-tp2" "the active recipe is recorded"
assert_eq "$(model_active_served_name)" "$(jq -r '.served_name' <<<"$fast2")" "the served id clients must send is recorded"
model_is_setup || fail "recording marks the install as set up"
model_wire_agents "$fast2" 12434
assert_eq "$(jq -r '.providers.local.baseUrl' "$HOME/.pi/agent/models.json")" "http://127.0.0.1:12434/v1" "pi points at the local endpoint"
assert_eq "$(jq -r '.defaultProvider' "$HOME/.omp/agent/settings.json")" "local" "an agent with no default adopts local"

jq -n '{defaultProvider:"anthropic",defaultModel:"opus"}' >"$HOME/.pi/agent/settings.json"
model_wire_agents "$fast2" 12434
assert_eq "$(jq -r '.defaultProvider' "$HOME/.pi/agent/settings.json")" "anthropic" "an existing provider choice survives"
model_unwire_agents
assert_eq "$(jq -r '.providers.local // "gone"' "$HOME/.pi/agent/models.json")" "gone" "unwiring drops the provider"
assert_eq "$(jq -r '.defaultProvider' "$HOME/.pi/agent/settings.json")" "anthropic" "unwiring leaves a foreign default alone"
pass "agent wiring is surgical and reversible"

printf '{broken' >"$HOME/.pi/agent/models.json"
if model_wire_agents "$fast1" 12434 2>/dev/null; then fail "malformed agent JSON must be refused"; fi
assert_eq "$(cat "$HOME/.pi/agent/models.json")" '{broken' "malformed agent JSON survives byte-for-byte"
pass "agent wiring refuses to destroy malformed user config"
echo "# models: $PASS passed"
