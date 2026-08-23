#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox; mock_docker
export OMARCHY_AI_SHIPPED="$LOCAL_AI_ROOT/share/registry.json"
source "$LOCAL_AI_ROOT/lib/hardware.sh"
source "$LOCAL_AI_ROOT/lib/registry.sh"
source "$LOCAL_AI_ROOT/lib/models.sh"
source "$LOCAL_AI_ROOT/lib/engine.sh"

export OMARCHY_AI_GPU_INVENTORY=$'0,24564,24564\n1,24564,24564'
fast=$(registry_get qwen36-tp2)
plan=$(engine_plan "$fast" 12434 | tr '\n' ' ')
for expected in "--name omarchy-local-ai" "--restart unless-stopped" '--gpus "device=0,1"' \
                "--publish 127.0.0.1:12434:8000" "--shm-size 32g" "--tensor-parallel-size 2" "--kv-cache-dtype fp8"; do
  [[ $plan == *"$expected"* ]] || fail "plan carries [$expected]" "plan: $plan"
done
[[ $plan == *"--volume $HOME/.cache"* ]] || fail "a ~ volume expands to \$HOME" "plan: $plan"
pass "the run plan is built verbatim from the recipe"

OMARCHY_AI_GPU_INVENTORY=$'1,24564,24000\n3,24564,24500'
pinned=$(engine_plan "$fast" 12434 | tr '\n' ' ')
[[ $pinned == *'--gpus "device=3,1"'* ]] || fail "free-memory ordering reaches the plan" "plan: $pinned"
pass "the plan pins exactly two physical device IDs"

engine_run "$fast" 12434
grep -q "^run --detach" "$DOCKER_LOG" || fail "run launches the container"
pass "the engine launches what it planned"

: >"$DOCKER_LOG"
OMARCHY_AI_GPU_INVENTORY='0,24564,24564'
if engine_run "$fast" 12434 2>/dev/null; then fail "an undersized topology must not launch"; fi
[[ ! -s $DOCKER_LOG ]] || fail "a failed plan must not remove the current container"
pass "the engine preserves the current container when planning fails"
OMARCHY_AI_GPU_INVENTORY=$'0,24564,24564\n1,24564,24564'

assert_eq "$(engine_state)" "not-setup" "no record means not set up"
model_record "$fast" 12434
assert_eq "$(engine_state)" "running" "a live container reports running"
assert_eq "$(MOCK_RUNNING=false engine_state)" "stopped" "a dead container reports stopped"
pass "engine state is the vocabulary every surface reports"

: >"$DOCKER_LOG"; engine_stop; grep -q "^stop omarchy-local-ai" "$DOCKER_LOG" || fail "stop stops"
: >"$DOCKER_LOG"; engine_start; grep -q "^start omarchy-local-ai" "$DOCKER_LOG" || fail "start starts"
pass "lifecycle verbs drive the container"

: >"$DOCKER_LOG"
image=$(engine_purge)
grep -q "^rm --force omarchy-local-ai" "$DOCKER_LOG" || fail "purge removes the container"
assert_eq "$image" "$(jq -r '.image' <<<"$fast")" "purge reports the image it kept"
pass "purge removes the container and keeps the image"
echo "# engine: $PASS passed"
