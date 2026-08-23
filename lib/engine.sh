# engine — running the chosen model.
#
# Owns the container runtime and the lifecycle: build the argv, bootstrap
# Docker if it is missing, serve, wait for readiness, prove the server answers.
# It never decides *what* to run; models/ hands it a resolved recipe.
#
# There is no daemon. Docker's restart policy is the supervisor, which gives
# reboot persistence with correct stopped-stays-stopped semantics.
#
# Depends on: models.sh (for the active record), hardware.sh (GPU selector).

ENGINE_CONTAINER="${OMARCHY_AI_CONTAINER:-omarchy-local-ai}"

# ---------------------------------------------------------------- planning

# The full docker argv for a recipe. Pure: no side effects, so `--dry-run`
# prints exactly what a real run would execute.
#
# Nothing is injected into the recipe's own args — generic images own their
# entrypoints, and guessing flags for them would break them.
engine_plan() {
  local recipe=$1 port=$2
  local container_port image gpu_selector
  container_port=$(jq -r '.container_port // 8000' <<<"$recipe")
  image=$(jq -r '.image' <<<"$recipe")
  gpu_selector=$(hw_gpu_selector \
    "$(jq -r '.tensor_parallel_size' <<<"$recipe")" \
    "$(jq -r '.min_vram_mb' <<<"$recipe")") || return 1

  local -a argv=(run --detach --name "$ENGINE_CONTAINER" --restart unless-stopped
    --gpus "$gpu_selector"
    --publish "127.0.0.1:$port:$container_port")

  local pair
  while read -r pair; do [[ -n $pair ]] && argv+=("$pair"); done < <(jq -r '.run_args[]?' <<<"$recipe")
  while read -r pair; do [[ -n $pair ]] && argv+=(--env "$pair"); done \
    < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' <<<"$recipe")
  while read -r pair; do [[ -n $pair ]] && argv+=(--volume "${pair/#\~/$HOME}"); done \
    < <(jq -r '(.volumes // {}) | to_entries[] | "\(.key):\(.value)"' <<<"$recipe")

  argv+=("$image")
  while IFS= read -r pair; do argv+=("$pair"); done < <(jq -r '.args[]?' <<<"$recipe")

  printf '%s\n' "${argv[@]}"
}

# ---------------------------------------------------------------- runtime bootstrap

# Docker, a running daemon, then the NVIDIA hook that --gpus needs. Each is a
# one-time step; a fresh machine can go from nothing to serving.
engine_bootstrap() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Installing Docker..."
    omarchy-pkg-add docker
    sudo systemctl enable --now docker.service
  fi
  if ! docker info &>/dev/null; then
    sudo systemctl enable --now docker.service
    if ! docker info &>/dev/null; then
      sudo usermod -aG docker "$USER"
      echo "Added you to the docker group. Log out and back in, then rerun setup." >&2
      return 1
    fi
  fi
  if ! omarchy-pkg-present nvidia-container-toolkit 2>/dev/null; then
    echo "Installing the NVIDIA container toolkit..."
    omarchy-pkg-add nvidia-container-toolkit
    sudo systemctl restart docker
  fi
}

# ---------------------------------------------------------------- lifecycle

engine_run() {
  local recipe=$1 port=$2 plan
  local -a argv
  plan=$(engine_plan "$recipe" "$port") || return 1
  mapfile -t argv <<<"$plan"
  engine_remove_container
  docker "${argv[@]}" >/dev/null
}

engine_remove_container() {
  if [[ -n $(docker ps --all --quiet --filter "name=^$ENGINE_CONTAINER$" 2>/dev/null) ]]; then
    docker rm --force "$ENGINE_CONTAINER" >/dev/null
  fi
}

engine_running() {
  [[ $(docker inspect --format '{{.State.Running}}' "$ENGINE_CONTAINER" 2>/dev/null) == "true" ]]
}

# running | stopped | not-setup — the vocabulary every surface reports in.
engine_state() {
  if ! model_is_setup; then
    echo "not-setup"
  elif engine_running; then
    echo "running"
  else
    echo "stopped"
  fi
}

engine_start() { docker start "$ENGINE_CONTAINER" >/dev/null; }
engine_stop() { docker stop "$ENGINE_CONTAINER" >/dev/null; }
engine_logs() { exec docker logs --tail 100 --follow "$ENGINE_CONTAINER"; }

# ---------------------------------------------------------------- readiness

# Poll until the OpenAI-compatible surface answers. Two failure modes need
# distinguishing from "still loading": a container that exited, and one that
# is crash-looping — the restart policy flickers it back to Running between
# checks, so the restart count catches what a liveness check misses.
engine_wait() {
  local port=$1 timeout=${2:-7200} elapsed=0
  while :; do
    if curl --fail --silent "http://127.0.0.1:$port/v1/models" &>/dev/null; then
      return 0
    fi
    if ! engine_running; then
      sleep 6
      engine_running || { echo "The model server exited before becoming ready." >&2; return 1; }
    fi
    if (($(docker inspect --format '{{.RestartCount}}' "$ENGINE_CONTAINER" 2>/dev/null || echo 0) > 2)); then
      echo "The model server keeps crashing on startup." >&2
      engine_remove_container
      return 1
    fi
    ((elapsed += 5))
    if ((elapsed >= timeout)); then
      echo "The model server is still not ready after $((timeout / 60)) minutes." >&2
      return 1
    fi
    sleep 5
  done
}

# Health endpoints lie: a server can list models and still fail to generate.
# Nothing is wired into an agent until a real completion comes back.
engine_verify() {
  local port=$1 served=$2 reply
  reply=$(curl --fail --silent --max-time 300 "http://127.0.0.1:$port/v1/chat/completions" \
    --header "Content-Type: application/json" \
    --data "$(jq -n --arg model "$served" \
      '{model: $model,
        messages: [{role: "user", content: "Reply with the single word: ready"}],
        max_completion_tokens: 32,
        chat_template_kwargs: {enable_thinking: false}}')")
  if ! jq -e '.choices[0].message.content | length > 0' <<<"$reply" >/dev/null; then
    echo "The model server did not answer a chat completion: $reply" >&2
    return 1
  fi
}

# ---------------------------------------------------------------- teardown

# Take out exactly what setup created. The engine image is kept — it is
# expensive to pull and shared across recipes.
engine_purge() {
  local record image model
  record=$(model_active 2>/dev/null || echo '{}')
  image=$(jq -r '.image // ""' <<<"$record")
  model=$(jq -r '.model // ""' <<<"$record")
  [[ -n $model ]] && rm -rf "$HOME/.cache/huggingface/hub/models--${model//\//--}"
  rm -rf "$HOME/.cache/omarchy-local-ai"
  docker rm --force "$ENGINE_CONTAINER" &>/dev/null || true
  printf '%s' "$image"
}
