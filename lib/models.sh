# models — choosing a model for this machine, and how agents see it.
#
# This is where hardware meets registry. It answers three questions:
#   does this recipe fit?          model_fits
#   which one should we serve?     model_autopick / model_resolve
# and then owns the record of what is active and the agent wiring that points
# at it.
#
# Depends on: hardware.sh, registry.sh.

MODELS_STATE_DIR="${OMARCHY_AI_STATE_DIR:-$HOME/.local/state/omarchy/local-ai}"
MODELS_RECORD="$MODELS_STATE_DIR/recipe.json"

# A recipe fits when at least min_gpus cards each carry min_vram_mb. Counting
# qualifying cards — rather than summing VRAM — is what makes multi-GPU
# recipes honest: two 24 GB cards are not one 48 GB card.
model_fits() {
  local recipe=$1 vrams=$2
  jq -e --argjson vrams "$vrams" \
    '. as $r | ([$vrams[] | select(. >= $r.min_vram_mb)] | length) >= ($r.min_gpus // 1)' \
    <<<"$recipe" >/dev/null
}

# The best model this machine can run: recipes are already in preference
# order, so the first that fits wins.
model_autopick() {
  local vrams=$1 recipe
  while read -r recipe; do
    [[ -n $recipe ]] || continue
    if model_fits "$recipe" "$vrams"; then
      printf '%s\n' "$recipe"
      return 0
    fi
  done < <(registry_recipes | jq -c '.[]')
  return 1
}

# A named immutable recipe. Fails loudly when its exact topology cannot fit.
model_resolve() {
  local name=$1 vrams=$2 recipe
  recipe=$(registry_get "$name")
  if [[ -z $recipe ]]; then
    echo "No recipe named \"$name\". Known recipes:" >&2
    registry_names | sed 's/^/  /' >&2
    return 1
  fi
  if ! model_fits "$recipe" "$vrams"; then
    echo "\"$name\" needs $(jq -r '.min_gpus // 1' <<<"$recipe")× $(($(jq -r '.min_vram_mb' <<<"$recipe") / 1024)) GB GPUs; this machine has $(jq 'length' <<<"$vrams")× up to $(($(jq 'max // 0' <<<"$vrams") / 1024)) GB." >&2
    return 1
  fi
  printf '%s\n' "$recipe"
}

# ---------------------------------------------------------------- active record

# What is deployed right now. Written after a successful serve so every other
# surface (status, panel, agent wiring) reads one source of truth.
model_record() {
  local recipe=$1 port=$2 temporary
  mkdir -p "$MODELS_STATE_DIR"
  temporary=$(mktemp "$MODELS_STATE_DIR/.recipe.json.XXXXXX")
  jq -n --argjson r "$recipe" --argjson port "$port" '{
    name: $r.name, label: $r.label, model: ($r.model // ""),
    served_name: ($r.served_name // ""), image: $r.image,
    port: $port, context_window: ($r.context_window // 8192),
    tensor_parallel_size: $r.tensor_parallel_size
  }' >"$temporary"
  mv "$temporary" "$MODELS_RECORD"
}

model_active() {
  [[ -f $MODELS_RECORD ]] && cat "$MODELS_RECORD"
}

model_active_name() {
  jq -r '.name // empty' "$MODELS_RECORD" 2>/dev/null || true
}

# The id the server actually answers to. Clients must send this rather than
# the recipe name — vLLM rejects unknown model ids outright.
model_active_served_name() {
  jq -r '.served_name // empty' "$MODELS_RECORD" 2>/dev/null || true
}

model_is_setup() {
  [[ -f $MODELS_RECORD ]]
}

model_forget() {
  rm -f "$MODELS_RECORD"
}

# ---------------------------------------------------------------- agent wiring

MODELS_AGENTS=(pi omp)

# The provider block an agent needs to reach a served model. Kept as a pure
# function so its shape is testable without touching a filesystem.
#
# maxTokens deliberately equals the context window: generation is never capped
# here, the server clamps per request.
model_provider_json() {
  local recipe=$1 endpoint=$2
  jq -n --argjson r "$recipe" --arg url "$endpoint" '{
    baseUrl: $url,
    apiKey: "local",
    api: "openai-completions",
    models: [{
      id: $r.served_name,
      name: "\($r.label) (local)",
      reasoning: ($r.reasoning // false),
      input: (if ($r.vision // false) then ["text", "image"] else ["text"] end),
      contextWindow: ($r.context_window // 8192),
      maxTokens: ($r.context_window // 8192),
      cost: {input: 0, output: 0, cacheRead: 0, cacheWrite: 0},
      compat: {
        supportsDeveloperRole: false,
        supportsReasoningEffort: false,
        thinkingFormat: ($r.thinking_format // "openai"),
        maxTokensField: "max_completion_tokens",
        supportsStore: false,
        supportsStrictMode: false,
        supportsUsageInStreaming: false
      }
    }]
  }'
}

# Merge the local provider into each agent's config. An existing provider
# choice survives: we claim defaultProvider only when the agent has none, and
# keep our own default current across model switches.
model_wire_agents() {
  local recipe=$1 port=$2
  local served endpoint provider agent dir current temporary
  served=$(jq -r '.served_name // ""' <<<"$recipe")
  [[ -n $served ]] || return 0
  endpoint="http://127.0.0.1:$port/v1"
  provider=$(model_provider_json "$recipe" "$endpoint")

  # Validate every user-owned file before changing any of them. A malformed
  # file therefore fails the whole operation without partially wiring agents.
  for agent in "${MODELS_AGENTS[@]}"; do
    dir="$HOME/.$agent/agent"
    current=$(cat "$dir/models.json" 2>/dev/null || echo '{}')
    jq -e 'type == "object"' <<<"$current" >/dev/null || {
      echo "Refusing to overwrite malformed JSON: $dir/models.json" >&2
      return 1
    }
    current=$(cat "$dir/settings.json" 2>/dev/null || echo '{}')
    jq -e 'type == "object"' <<<"$current" >/dev/null || {
      echo "Refusing to overwrite malformed JSON: $dir/settings.json" >&2
      return 1
    }
  done

  for agent in "${MODELS_AGENTS[@]}"; do
    dir="$HOME/.$agent/agent"
    mkdir -p "$dir"
    current=$(cat "$dir/models.json" 2>/dev/null || echo '{}')
    temporary=$(mktemp "$dir/.models.json.XXXXXX")
    jq --argjson provider "$provider" '.providers.local = $provider' \
      <<<"$current" >"$temporary"
    mv "$temporary" "$dir/models.json"

    current=$(cat "$dir/settings.json" 2>/dev/null || echo '{}')
    temporary=$(mktemp "$dir/.settings.json.XXXXXX")
    jq --arg model "$served" \
      'if .defaultProvider == null or .defaultProvider == "local"
       then .defaultProvider = "local" | .defaultModel = $model else . end' \
      <<<"$current" >"$temporary"
    mv "$temporary" "$dir/settings.json"
  done
}

# Reverse exactly what wiring did, and nothing else: a foreign default
# provider is left alone.
model_unwire_agents() {
  local agent dir
  for agent in "${MODELS_AGENTS[@]}"; do
    dir="$HOME/.$agent/agent"
    if [[ -f $dir/models.json ]]; then
      jq 'del(.providers.local)' "$dir/models.json" >"$dir/models.json.tmp"
      mv "$dir/models.json.tmp" "$dir/models.json"
    fi
    if [[ -f $dir/settings.json ]]; then
      jq 'if .defaultProvider == "local" then del(.defaultProvider, .defaultModel) else . end' \
        "$dir/settings.json" >"$dir/settings.json.tmp"
      mv "$dir/settings.json.tmp" "$dir/settings.json"
    fi
  done
}
