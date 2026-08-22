# Shared test scaffolding: assertions plus a sandbox so no test touches the
# real home directory, catalog, or docker.
set -euo pipefail
LOCAL_AI_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { echo "not ok - $1" >&2; [[ -n ${2:-} ]] && echo "  $2" >&2; exit 1; }
assert_eq() { [[ $1 == "$2" ]] || fail "$3" "expected [$2] got [$1]"; }

sandbox() {
  TEST_TMP=$(mktemp -d)
  trap 'rm -rf "$TEST_TMP"' EXIT
  export HOME="$TEST_TMP/home"; mkdir -p "$HOME"
  export OMARCHY_AI_STATE_DIR="$HOME/.local/state/omarchy/local-ai"
  export PATH="$TEST_TMP/bin:$PATH"; mkdir -p "$TEST_TMP/bin"
}

# A docker that records its argv instead of running anything.
mock_docker() {
  cat > "$TEST_TMP/bin/docker" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case $1 in
  ps) [[ ${MOCK_CONTAINER_EXISTS:-false} == true ]] && echo abc123 ;;
  inspect) printf '%s\n' "${MOCK_RUNNING:-true}" ;;
esac
exit 0
SH
  chmod +x "$TEST_TMP/bin/docker"
  export DOCKER_LOG="$TEST_TMP/docker.log"; : >"$DOCKER_LOG"
}
