# Loader — the one entry point. Sourcing this brings the four modules in
# dependency order and fixes LOCAL_AI_ROOT so share/ and lib/ resolve
# regardless of where the CLI was invoked from.

LOCAL_AI_ROOT="${LOCAL_AI_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

source "$LOCAL_AI_ROOT/lib/hardware.sh"   # no dependencies
source "$LOCAL_AI_ROOT/lib/registry.sh"   # no dependencies
source "$LOCAL_AI_ROOT/lib/models.sh"     # hardware + registry
source "$LOCAL_AI_ROOT/lib/engine.sh"     # models + hardware

# Panels and CLI commands poke the shell so the bar reflects state changes
# immediately instead of waiting for its poll.
local_ai_notify_shell() {
  omarchy-shell -q sero.local-ai refresh 2>/dev/null || true
}
