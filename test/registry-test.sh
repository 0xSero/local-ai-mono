#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox
export OMARCHY_AI_SHIPPED="$LOCAL_AI_ROOT/share/local-ai.json"
source "$LOCAL_AI_ROOT/lib/registry.sh"

assert_eq "$(registry_path)" "$OMARCHY_AI_SHIPPED" "falls back to the shipped catalog"
[[ $(registry_port) =~ ^[0-9]+$ ]] || fail "catalog carries a port"
assert_eq "$(registry_names | sort | tr '\n' ' ')" "fast smart " "ships exactly fast and smart"
pass "registry resolves and reads the shipped catalog"

jq -e '.name == "smart"' <<<"$(registry_get smart)" >/dev/null || fail "recipes are addressable by name"
assert_eq "$(registry_get nope)" "" "an unknown name resolves to empty"
pass "recipes are addressable by name"

first=$(registry_recipes | jq -r '.[0].name')
assert_eq "$first" "smart" "the largest requirement sorts first"
pass "recipes come back in serving preference order"

# A cached catalog wins over the shipped one.
mkdir -p "$OMARCHY_AI_STATE_DIR"
jq '.recipes = [{name:"cached",label:"Cached",min_vram_mb:1,image:"x"}]' \
  "$OMARCHY_AI_SHIPPED" >"$OMARCHY_AI_STATE_DIR/catalog.json"
assert_eq "$(registry_names)" "cached" "the synced cache overrides the shipped catalog"
rm -f "$OMARCHY_AI_STATE_DIR/catalog.json"
pass "the synced cache takes precedence"

registry_valid_recipe '{"name":"a","label":"b","min_vram_mb":1,"image":"i"}' || fail "a complete manifest validates"
if registry_valid_recipe '{"name":"a"}'; then fail "an incomplete manifest is rejected"; fi
pass "published manifests are validated before merging"
echo "# registry: $PASS passed"
