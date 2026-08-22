#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox
export OMARCHY_AI_SHIPPED="$LOCAL_AI_ROOT/share/local-ai.json"
source "$LOCAL_AI_ROOT/lib/hardware.sh"
source "$LOCAL_AI_ROOT/lib/registry.sh"
source "$LOCAL_AI_ROOT/lib/models.sh"

ONE='[24564]'; TWO='[24564,24564]'; FOUR='[24564,24564,24564,24564]'; SMALL='[16384]'
fast=$(registry_get fast); smart=$(registry_get smart)

model_fits "$fast" "$ONE" || fail "fast fits a single 24 GB card"
model_fits "$smart" "$ONE" || fail "smart also fits a single 24 GB card"
model_fits "$smart" "$TWO" || fail "smart fits two cards"
if model_fits "$fast" "$SMALL"; then fail "a 16 GB card fits nothing"; fi
pass "both tiers run on one card; a 16 GB card runs nothing"

assert_eq "$(model_qualifying_gpus "$fast" "$FOUR")" "4" "qualifying cards are counted"
pass "qualifying cards are counted"

tp() { jq -r '(.args | index("--tensor-parallel-size")) as $i | if $i then .args[$i+1] else "1" end' <<<"$1"; }
assert_eq "$(tp "$(model_scale "$fast" 1)")" "1" "one GPU takes no scale step"
assert_eq "$(tp "$(model_scale "$fast" 4)")" "4" "four GPUs take the 4-step"
assert_eq "$(tp "$(model_scale "$fast" 3)")" "2" "three GPUs take the largest step that fits"
assert_eq "$(jq -r '.scale // "gone"' <<<"$(model_scale "$fast" 4)")" "gone" "the scale map is consumed"
assert_eq "$(jq -r '.context_window' <<<"$(model_scale "$smart" 2)")" "131072" "a second card buys smart the full window"
pass "scale merges the largest step the machine reaches"

assert_eq "$(model_autopick "$ONE" | jq -r .name)" "fast" "one card auto-picks fast"
assert_eq "$(model_autopick "$FOUR" | jq -r .name)" "fast" "more cards still default to fast, scaled up"
assert_eq "$(tp "$(model_autopick "$FOUR")")" "4" "the auto-pick is scaled to the machine"
if model_autopick "$SMALL" >/dev/null 2>&1; then fail "nothing fits a small card"; fi
pass "auto-pick defaults to fast and scales it to the hardware"

assert_eq "$(model_resolve fast "$ONE" | jq -r .name)" "fast" "a named model resolves"
assert_eq "$(model_resolve smart "$ONE" | jq -r .name)" "smart" "smart is reachable on one card"
if model_resolve smart "$SMALL" 2>/dev/null; then fail "a 16 GB card is refused"; fi
if model_resolve nope "$ONE" 2>/dev/null; then fail "an unknown name is refused"; fi
pass "named models resolve and refuse honestly"

provider=$(model_provider_json "$(model_scale "$fast" 4)" "http://127.0.0.1:12434/v1")
assert_eq "$(jq -r '.api' <<<"$provider")" "openai-completions" "provider speaks the openai api"
assert_eq "$(jq -c '.models[0].input' <<<"$provider")" '["text","image"]' "a vision model gets image input"
assert_eq "$(jq -r '.models[0].maxTokens' <<<"$provider")" "$(jq -r '.models[0].contextWindow' <<<"$provider")" "generation is never capped below the context window"
pass "the provider block is shaped for the agents"

model_record "$(model_scale "$fast" 2)" 12434
assert_eq "$(model_active_name)" "fast" "the active model is recorded"
assert_eq "$(model_active_served_name)" "$(jq -r '.served_name' <<<"$fast")" "the served id clients must send is recorded"
model_is_setup || fail "recording marks the install as set up"
model_wire_agents "$(model_scale "$fast" 2)" 12434
assert_eq "$(jq -r '.providers.local.baseUrl' "$HOME/.pi/agent/models.json")" "http://127.0.0.1:12434/v1" "pi points at the local endpoint"
assert_eq "$(jq -r '.defaultProvider' "$HOME/.omp/agent/settings.json")" "local" "an agent with no default adopts local"

jq -n '{defaultProvider:"anthropic",defaultModel:"opus"}' >"$HOME/.pi/agent/settings.json"
model_wire_agents "$(model_scale "$fast" 2)" 12434
assert_eq "$(jq -r '.defaultProvider' "$HOME/.pi/agent/settings.json")" "anthropic" "an existing provider choice survives"
model_unwire_agents
assert_eq "$(jq -r '.providers.local // "gone"' "$HOME/.pi/agent/models.json")" "gone" "unwiring drops the provider"
assert_eq "$(jq -r '.defaultProvider' "$HOME/.pi/agent/settings.json")" "anthropic" "unwiring leaves a foreign default alone"
pass "agent wiring is surgical and reversible"
echo "# models: $PASS passed"
