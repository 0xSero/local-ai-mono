# hardware — what accelerators does this machine have?
#
# The only module that talks to the driver. Everything downstream asks
# questions here instead of shelling out to nvidia-smi itself, so a second
# vendor (ROCm, oneAPI) is added by teaching this file alone.
#
# Depends on: nothing.

# index,total MiB,free MiB — one GPU per line. Keeping the index attached is
# important: sorting a bare VRAM list and later launching "all" can size a
# recipe against one set of cards while Docker receives another.
hw_gpu_inventory() {
  if [[ -n ${OMARCHY_AI_GPU_INVENTORY:-} ]]; then
    printf '%s\n' "$OMARCHY_AI_GPU_INVENTORY"
  elif hw_has_nvidia; then
    nvidia-smi ${OMARCHY_AI_GPUS:+-i "$OMARCHY_AI_GPUS"} \
      --query-gpu=index,memory.total,memory.free --format=csv,noheader,nounits 2>/dev/null \
      | tr -d ' '
  elif [[ -n ${OMARCHY_AI_VRAM_MB:-} ]]; then
    awk 'NF { print NR - 1 "," $1 "," $1 }' <<<"$OMARCHY_AI_VRAM_MB"
  fi | grep -E '^[0-9]+,[0-9]+,[0-9]+$' || true
}

# Every GPU's total VRAM in MiB, largest first, one per line.
hw_vram_list() {
  hw_gpu_inventory | cut -d, -f2 | sort -rn || true
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

# Select exactly the card count the recipe declares. Cards with the most free
# memory win, which naturally leaves a display-attached 3090 until last. Docker
# treats commas inside --gpus as option separators unless the device request is
# itself quoted, so multi-card selectors deliberately include literal quotes.
hw_gpu_selector() {
  local count=$1 min_vram_mb=$2 ids
  ids=$(hw_gpu_inventory \
    | awk -F, -v minimum="$min_vram_mb" '$2 >= minimum { print $1 "," $3 }' \
    | sort -t, -k2,2nr -k1,1n \
    | head -n "$count" \
    | cut -d, -f1 \
    | paste -sd, -)

  if (( $(tr -cd ',' <<<"$ids" | wc -c) + (${#ids} > 0) != count )); then
    echo "Unable to select $count GPUs with at least $min_vram_mb MiB each." >&2
    return 1
  fi

  if ((count == 1)); then
    printf 'device=%s' "$ids"
  else
    printf '"device=%s"' "$ids"
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
