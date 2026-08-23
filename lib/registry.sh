# registry — where recipes come from.
#
# A recipe is pure data describing one run of a serving image. The registry
# owns their provenance and nothing else: it does not know what a GPU is and
# never decides what to serve. Resolution is layered so a synced catalog can
# override what ships without editing files in place.
#
#   $OMARCHY_AI_CATALOG          explicit override (tests, experiments)
#   ~/.local/state/.../catalog.json   written atomically by registry_sync
#   <repo>/share/registry.json        shipped defaults
#
# Depends on: nothing.

REGISTRY_STATE_DIR="${OMARCHY_AI_STATE_DIR:-$HOME/.local/state/omarchy/local-ai}"
REGISTRY_SHIPPED="${OMARCHY_AI_SHIPPED:-$LOCAL_AI_ROOT/share/registry.json}"

registry_path() {
  local cached="$REGISTRY_STATE_DIR/catalog.json"
  if [[ -n ${OMARCHY_AI_CATALOG:-} && -f ${OMARCHY_AI_CATALOG:-} ]]; then
    printf '%s' "$OMARCHY_AI_CATALOG"
  elif [[ -f $cached ]]; then
    printf '%s' "$cached"
  else
    printf '%s' "$REGISTRY_SHIPPED"
  fi
}

registry_load() {
  cat "$(registry_path)"
}

registry_port() {
  jq -r '.port' "$(registry_path)"
}

# Recipes carry an explicit preference. This keeps topology selection obvious:
# on four cards qwen36-tp4 wins, on two cards the first fitting entry is TP2.
registry_recipes() {
  jq -c '.recipes | sort_by([.priority, .name])' "$(registry_path)"
}

registry_names() {
  jq -r '.recipes[].name' "$(registry_path)"
}

# One recipe by name; empty output means unknown, which callers must handle.
registry_get() {
  jq -c --arg name "$1" 'first(.recipes[] | select(.name == $name)) // empty' "$(registry_path)"
}

# Sync exactly one versioned registry document. We do not crawl every repo in
# an account: that made provenance implicit and let partial API failures replace
# a good cache. The old cache survives every download or validation failure.
registry_sync() {
  local url="${OMARCHY_AI_REGISTRY_URL:-}" temporary
  [[ -n $url ]] || { echo "Set OMARCHY_AI_REGISTRY_URL to the registry JSON URL." >&2; return 1; }
  mkdir -p "$REGISTRY_STATE_DIR"
  temporary=$(mktemp "$REGISTRY_STATE_DIR/.catalog.json.XXXXXX")
  if ! curl --fail --silent --show-error --max-time 30 "$url" >"$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if ! registry_valid_catalog "$temporary"; then
    echo "Downloaded registry failed validation; keeping the current catalog." >&2
    rm -f "$temporary"
    return 1
  fi
  mv "$temporary" "$REGISTRY_STATE_DIR/catalog.json"
  echo "Catalog now carries $(jq '.recipes | length' "$REGISTRY_STATE_DIR/catalog.json") pinned recipes."
}

# Registry validation is intentionally strict because this JSON becomes a
# Docker command. Images and model revisions are immutable, TP is one of the
# alpha topologies, names are unique, and graph-disabling flags are rejected.
registry_valid_catalog() {
  jq -e '
    def flag($args; $name):
      ($args | index($name)) as $index
      | if $index == null then null else $args[$index + 1] end;
    .schemaVersion == 1
    and (.port | type == "number" and . >= 1 and . <= 65535)
    and (.recipes | type == "array" and length >= 6)
    and (([.recipes[].name] | unique | length) == (.recipes | length))
    and (["qwen36-tp1", "qwen36-tp2", "qwen36-tp4", "qwen38-tp1", "qwen38-tp2", "qwen38-tp4"]
      - [.recipes[].name] | length == 0)
    and all(.recipes[]; . as $recipe |
      ($recipe.name | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
      and ($recipe.label | type == "string" and length > 0)
      and ($recipe.priority | type == "number")
      and ($recipe.min_vram_mb | type == "number" and . >= 23000)
      and ($recipe.min_gpus == $recipe.tensor_parallel_size)
      and ([1, 2, 4] | index($recipe.tensor_parallel_size) != null)
      and ($recipe.image | type == "string" and test("@sha256:[0-9a-f]{64}$"))
      and ($recipe.model | type == "string" and length > 0)
      and ($recipe.served_name | type == "string" and length > 0)
      and ($recipe.revision | type == "string" and test("^[0-9a-f]{40}$"))
      and ($recipe.args | type == "array" and all(.[]; type == "string"))
      and (flag($recipe.args; "--model") == $recipe.model)
      and (flag($recipe.args; "--served-model-name") == $recipe.served_name)
      and (flag($recipe.args; "--revision") == $recipe.revision)
      and (flag($recipe.args; "--tensor-parallel-size") == ($recipe.tensor_parallel_size | tostring))
      and ($recipe | has("scale") | not)
      and ([$recipe.args[] | select(test("disable.*cuda.*graph|enforce.eager"; "i"))] | length == 0)
    )
  ' "$1" >/dev/null 2>&1
}
