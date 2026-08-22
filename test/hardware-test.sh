#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox
source "$LOCAL_AI_ROOT/lib/hardware.sh"

OMARCHY_AI_VRAM_MB=$'24564\n11264\n24564'
assert_eq "$(hw_vram_list | head -1)" "24564" "vram list is sorted largest first"
assert_eq "$(hw_gpu_count)" "3" "gpu count counts every card"
assert_eq "$(hw_largest_vram_mb)" "24564" "largest card is reported"
assert_eq "$(hw_vram_json)" "$(jq -c . <<<'[24564,24564,11264]')" "json form is sorted"
pass "hardware reports every card, largest first"

assert_eq "$(hw_gpu_selector)" "all" "no pin means all GPUs"
OMARCHY_AI_GPUS=2,3 assert_eq "$(OMARCHY_AI_GPUS=2,3 hw_gpu_selector)" "device=2,3" "a pin narrows the selector"
pass "the GPU selector honours a pinned subset"

unset OMARCHY_AI_VRAM_MB
if OMARCHY_AI_VRAM_MB="" hw_require_gpu 2>/dev/null; then fail "no GPU must be refused"; fi
pass "a machine with no GPU is refused"
echo "# hardware: $PASS passed"
