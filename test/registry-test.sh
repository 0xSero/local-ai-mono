#!/bin/bash
source "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"
sandbox
export OMARCHY_AI_SHIPPED="$LOCAL_AI_ROOT/share/registry.json"
source "$LOCAL_AI_ROOT/lib/registry.sh"

assert_eq "$(registry_path)" "$OMARCHY_AI_SHIPPED" "falls back to the shipped catalog"
[[ $(registry_port) =~ ^[0-9]+$ ]] || fail "catalog carries a port"
assert_eq "$(registry_names | sort | tr '\n' ' ')" \
  "qwen36-tp1 qwen36-tp2 qwen36-tp4 qwen38-tp1 qwen38-tp2 qwen38-tp4 " \
  "ships one recipe per model and TP topology"
pass "registry resolves and reads the shipped catalog"

jq -e '.name == "qwen38-tp2"' <<<"$(registry_get qwen38-tp2)" >/dev/null || fail "recipes are addressable by name"
assert_eq "$(registry_get nope)" "" "an unknown name resolves to empty"
pass "recipes are addressable by name"

first=$(registry_recipes | jq -r '.[0].name')
assert_eq "$first" "qwen36-tp4" "explicit priority makes the fastest fitting topology lead"
pass "recipes come back in explicit serving preference order"

# A cached catalog wins over the shipped one.
mkdir -p "$OMARCHY_AI_STATE_DIR"
jq '.recipes[0].label = "Cached"' \
  "$OMARCHY_AI_SHIPPED" >"$OMARCHY_AI_STATE_DIR/catalog.json"
assert_eq "$(registry_get qwen36-tp4 | jq -r .label)" "Cached" "the synced cache overrides the shipped catalog"
rm -f "$OMARCHY_AI_STATE_DIR/catalog.json"
pass "the synced cache takes precedence"

registry_valid_catalog "$OMARCHY_AI_SHIPPED" || fail "the shipped catalog validates"
extended="$TEST_TMP/extended.json"
jq '.recipes += [(.recipes[-1] | .name = "qwen38-lab-tp1" | .priority = 70)]' "$OMARCHY_AI_SHIPPED" >"$extended"
registry_valid_catalog "$extended" || fail "additional pinned recipes must be allowed"
bad="$TEST_TMP/bad.json"
jq '.recipes[0].args += ["--disable-cuda-graph"]' "$OMARCHY_AI_SHIPPED" >"$bad"
if registry_valid_catalog "$bad"; then fail "a graph-disabling recipe is rejected"; fi
wrong_revision="$TEST_TMP/wrong-revision.json"
jq '.recipes[0].revision = "0000000000000000000000000000000000000000"' "$OMARCHY_AI_SHIPPED" >"$wrong_revision"
if registry_valid_catalog "$wrong_revision"; then fail "a revision that disagrees with argv is rejected"; fi
pass "the complete catalog is validated before replacement"

OMARCHY_AI_REGISTRY_URL="file://$OMARCHY_AI_SHIPPED" registry_sync >/dev/null
cached="$OMARCHY_AI_STATE_DIR/catalog.json"
before=$(sha256sum "$cached" | cut -d' ' -f1)
if OMARCHY_AI_REGISTRY_URL="file://$bad" registry_sync >/dev/null 2>&1; then
  fail "invalid remote registry must fail sync"
fi
after=$(sha256sum "$cached" | cut -d' ' -f1)
assert_eq "$after" "$before" "a failed sync preserves the last good registry"
pass "registry sync replaces atomically and preserves the last good catalog"
echo "# registry: $PASS passed"
