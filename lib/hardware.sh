# hardware — what accelerators does this machine have?
#
# The only module that talks to the driver. Everything downstream asks
# questions here instead of shelling out to nvidia-smi itself, so a second
# vendor (ROCm, oneAPI) is added by teaching this file alone.
#
# Depends on: nothing.

# Every qualifying GPU's VRAM in MiB, largest first, one per line.
#
# OMARCHY_AI_VRAM_MB overrides the probe entirely (tests, dry runs).
# OMARCHY_AI_GPUS confines the probe to a subset ("0,2"), which is also the
# subset the engine will be pinned to — the two must agree or a recipe would
# be sized against cards it cannot use.
hw_vram_list() {
  if [[ -n ${OMARCHY_AI_VRAM_MB:-} ]]; then
    printf '%s\n' "$OMARCHY_AI_VRAM_MB"
  elif hw_has_nvidia; then
    nvidia-smi ${OMARCHY_AI_GPUS:+-i "$OMARCHY_AI_GPUS"} \
      --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null
  fi | grep -E '^[0-9]+$' | sort -rn || true
}

hw_has_nvidia() {
  command -v nvidia-smi >/dev/null 2>&1
}

# The same list as JSON, which is what models/ and the CLI contract speak.
hw_vram_json() {
  hw_vram_list | jq -Rnc '[inputs | select(. != "") | tonumber]'
}

hw_gpu_count() {
  hw_vram_list | grep -c . || true
}

# Largest single card, or 0 when there is no supported GPU. Callers use this
# for human-facing sizing messages; fit decisions belong to models/.
hw_largest_vram_mb() {
  hw_vram_list | head -1 | grep -E '^[0-9]+$' || echo 0
}

# The GPU argument for the container runtime: a pinned subset when the user
# asked for one, otherwise every visible card.
hw_gpu_selector() {
  if [[ -n ${OMARCHY_AI_GPUS:-} ]]; then
    printf 'device=%s' "$OMARCHY_AI_GPUS"
  else
    printf 'all'
  fi
}

# Refuse early and legibly rather than letting a recipe fail mysteriously
# later. AMD and Intel serving images are not wired up yet.
hw_require_gpu() {
  if (($(hw_gpu_count) == 0)); then
    echo "No NVIDIA GPU found. Local AI currently needs an NVIDIA GPU with at least 24 GB of VRAM." >&2
    return 1
  fi
}
