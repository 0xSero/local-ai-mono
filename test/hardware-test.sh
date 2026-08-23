#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox
source "$LOCAL_AI_ROOT/lib/hardware.sh"

OMARCHY_AI_GPU_INVENTORY=$'0,24564,24564\n1,11264,11264\n2,24564,24000'
assert_eq "$(hw_vram_list | head -1)" "24564" "vram list is sorted largest first"
assert_eq "$(hw_gpu_count)" "3" "gpu count counts every card"
assert_eq "$(hw_largest_vram_mb)" "24564" "largest card is reported"
assert_eq "$(hw_vram_json)" "$(jq -c . <<<'[24564,24564,11264]')" "json form is sorted"
pass "hardware reports every card, largest first"

assert_eq "$(hw_gpu_selector 1 23000)" "device=0" "one-card recipes select one card"
assert_eq "$(hw_gpu_selector 2 23000)" '"device=0,2"' "multi-card selectors are quoted for Docker"
pass "the GPU selector chooses exactly the recipe topology"

if OMARCHY_AI_GPU_INVENTORY="none" hw_require_gpu 2>/dev/null; then fail "no GPU must be refused"; fi
pass "a machine with no GPU is refused"
echo "# hardware: $PASS passed"
