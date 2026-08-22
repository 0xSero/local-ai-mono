# registry — where recipes come from.
#
# A recipe is pure data describing one run of a serving image. The registry
# owns their provenance and nothing else: it does not know what a GPU is and
# never decides what to serve. Resolution is layered so a synced catalog can
# override what ships without editing files in place.
#
#   $OMARCHY_AI_CATALOG          explicit override (tests, experiments)
#   ~/.local/state/.../catalog.json   written by registry_sync
#   <repo>/share/local-ai.json   shipped defaults
#
# Depends on: nothing.

REGISTRY_STATE_DIR="${OMARCHY_AI_STATE_DIR:-$HOME/.local/state/omarchy/local-ai}"
REGISTRY_SHIPPED="${OMARCHY_AI_SHIPPED:-$LOCAL_AI_ROOT/share/local-ai.json}"

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

# Recipes in serving preference order: the largest requirement that a machine
# can satisfy is the best model it can run, so callers take the first that
# fits. Alphabetical tie-break keeps merges from reshuffling the default.
registry_recipes() {
  jq -c '.recipes | sort_by([-.min_vram_mb, -(.min_gpus // 1), .name])' "$(registry_path)"
}

registry_names() {
  jq -r '.recipes[].name' "$(registry_path)"
}

# One recipe by name; empty output means unknown, which callers must handle.
registry_get() {
  jq -c --arg name "$1" 'first(.recipes[] | select(.name == $name)) // empty' "$(registry_path)"
}

registry_sources() {
  jq -r '.sources[]?' "$REGISTRY_SHIPPED"
}

# Publishing a recipe is pushing one omarchy-recipe.json to a repo root. Each
# source is a GitHub account; every public repo of that account carrying the
# manifest contributes a recipe. Remote wins on a shared name, so a repo can
# refine what ships without a release here.
registry_sync() {
  local api="${OMARCHY_AI_GITHUB_API:-https://api.github.com}"
  local raw="${OMARCHY_AI_GITHUB_RAW:-https://raw.githubusercontent.com}"
  local remote="[]" owner listing repos repo branch manifest

  while read -r owner; do
    [[ -n $owner ]] || continue
    echo "Scanning github.com/$owner..."
    listing=$(curl --fail --silent --max-time 30 "$api/users/$owner/repos?per_page=100" 2>/dev/null) || continue
    # A rate-limited API answers with an object, not an array; skip it rather
    # than letting jq abort the whole sync.
    jq -e 'type == "array"' <<<"$listing" >/dev/null 2>&1 || continue
    repos=$(jq -r '.[] | "\(.name) \(.default_branch)"' <<<"$listing")
    while read -r repo branch; do
      [[ -n $repo ]] || continue
      manifest=$(curl --fail --silent --max-time 10 "$raw/$owner/$repo/$branch/omarchy-recipe.json" 2>/dev/null) || continue
      if registry_valid_recipe "$manifest"; then
        remote=$(jq --argjson recipe "$(jq --arg src "github:$owner/$repo" '. + {source: $src}' <<<"$manifest")" \
          '. + [$recipe]' <<<"$remote")
        echo "  found: $(jq -r '.name' <<<"$manifest") ($owner/$repo)"
      fi
    done <<<"$repos"
  done < <(registry_sources)

  mkdir -p "$REGISTRY_STATE_DIR"
  jq --argjson remote "$remote" \
    '.recipes = ((.recipes + $remote) | group_by(.name) | map(last) | sort_by([-.min_vram_mb, -(.min_gpus // 1), .name]))' \
    "$REGISTRY_SHIPPED" >"$REGISTRY_STATE_DIR/catalog.json"

  echo "Catalog now carries $(jq '.recipes | length' "$REGISTRY_STATE_DIR/catalog.json") recipes ($(jq 'length' <<<"$remote") from GitHub)."
}

# The minimum a published manifest must carry to be worth merging.
registry_valid_recipe() {
  jq -e '.name and .label and .min_vram_mb and .image' <<<"$1" >/dev/null 2>&1
}
