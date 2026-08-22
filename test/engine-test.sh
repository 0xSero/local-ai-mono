#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox; mock_docker
export OMARCHY_AI_SHIPPED="$LOCAL_AI_ROOT/share/local-ai.json"
source "$LOCAL_AI_ROOT/lib/hardware.sh"
source "$LOCAL_AI_ROOT/lib/registry.sh"
source "$LOCAL_AI_ROOT/lib/models.sh"
source "$LOCAL_AI_ROOT/lib/engine.sh"

export OMARCHY_AI_VRAM_MB=$'24564\n24564'
fast=$(model_scale "$(registry_get fast)" 2)
plan=$(engine_plan "$fast" 12434 | tr '\n' ' ')
for expected in "--name omarchy-local-ai" "--restart unless-stopped" "--gpus all" \
                "--publish 127.0.0.1:12434:8000" "--shm-size 32g" "--env TP=2"; do
  [[ $plan == *"$expected"* ]] || fail "plan carries [$expected]" "plan: $plan"
done
[[ $plan == *"--volume $HOME/.cache"* ]] || fail "a ~ volume expands to \$HOME" "plan: $plan"
pass "the run plan is built verbatim from the recipe"

pinned=$(OMARCHY_AI_GPUS=1,3 engine_plan "$fast" 12434 | tr '\n' ' ')
[[ $pinned == *"--gpus device=1,3"* ]] || fail "a GPU pin reaches the plan"
pass "a pinned GPU subset reaches the container"

engine_run "$fast" 12434
grep -q "^run --detach" "$DOCKER_LOG" || fail "run launches the container"
pass "the engine launches what it planned"

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
