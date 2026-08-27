#!/bin/bash

set -euo pipefail

AI_ROOT="${AI_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
AI_USER_HOME="${OMARCHY_AI_USER_HOME:-$HOME}"
AI_REGISTRY_REPO="${OMARCHY_AI_REGISTRY_REPO:-$AI_USER_HOME/omarchy/local-ai}"
AI_REGISTRY="${OMARCHY_AI_REGISTRY:-$AI_REGISTRY_REPO/registry}"
AI_REGISTRY_REMOTE="${OMARCHY_AI_REGISTRY_REMOTE:-https://github.com/0xSero/local-ai-registry.git}"
AI_STATE="${OMARCHY_AI_STATE:-$AI_USER_HOME/.local/state/omarchy/local-ai}"
AI_CONTAINER="${OMARCHY_AI_CONTAINER:-omarchy-local-ai}"
AI_PORT="${OMARCHY_AI_PORT:-12434}"
AI_ACTIVE="$AI_STATE/active.json"
AI_BENCHMARK="$AI_STATE/benchmark.json"
AI_CLAUDE_UNIT="omarchy-local-ai-claude.service"

fail() { printf 'local-ai: %s\n' "$*" >&2; return 1; }
notify() { true; }

registry_valid() {
  local index="$AI_REGISTRY/index.json"
  [[ -f $index ]] && jq -e '
    .schema_version == "local-ai-registry/v1"
    and (.recipes | type == "array" and length > 0)
    and (([.recipes[].id] | unique | length) == (.recipes | length))
    and (.recipes | all(.id and .model_instance_id and .hardware_id and .status and .launch_kind))
  ' "$index" >/dev/null 2>&1
}

sync_registry() {
  if [[ -n ${OMARCHY_AI_REGISTRY:-} ]]; then
    registry_valid || fail "registry failed validation at $AI_REGISTRY"
    printf 'registry · %s recipes · local override\n' "$(jq '.recipes | length' "$AI_REGISTRY/index.json")"
    return
  fi
  mkdir -p "${AI_REGISTRY_REPO%/*}"
  if [[ ! -d $AI_REGISTRY_REPO/.git ]]; then
    git clone --filter=blob:none --branch main "$AI_REGISTRY_REMOTE" "$AI_REGISTRY_REPO"
  else
    [[ -z $(git -C "$AI_REGISTRY_REPO" status --porcelain) ]] || fail "registry checkout has local changes; refusing to overwrite them"
    [[ $(git -C "$AI_REGISTRY_REPO" branch --show-current) == "main" ]] || fail "registry checkout must be on main"
    git -C "$AI_REGISTRY_REPO" fetch origin main
    git -C "$AI_REGISTRY_REPO" merge --ff-only origin/main
  fi
  registry_valid || fail "registry failed validation at $AI_REGISTRY"
  printf 'registry · %s recipes · %s\n' "$(jq '.recipes | length' "$AI_REGISTRY/index.json")" "$(git -C "$AI_REGISTRY_REPO" rev-parse --short HEAD)"
}

ensure_registry() {
  registry_valid || fail "registry missing or invalid at $AI_REGISTRY; run sync"
}

hardware_json() {
  if [[ -n ${OMARCHY_AI_HARDWARE_JSON:-} ]]; then
    jq . <<<"$OMARCHY_AI_HARDWARE_JSON"
    return
  fi
  local nvidia='[]' intel='[]' rows count disk docker=false
  if command -v nvidia-smi >/dev/null 2>&1; then
    rows=$(nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader,nounits 2>/dev/null || true)
    nvidia=$(jq -Rsc '
      split("\n") | map(select(length > 0) | split(",") | map(gsub("^ +| +$"; "")))
      | map({backend:"nvidia", index:.[0]|tonumber, product:.[1], totalMiB:.[2]|tonumber, freeMiB:.[3]|tonumber})
      | group_by(.product) | map({backend:.[0].backend, product:.[0].product, count:length,
          memoryBytesEach:(.[0].totalMiB * 1048576), devices:map({index,totalMiB,freeMiB})})
    ' <<<"$rows")
  fi
  count=$(lspci -Dnn 2>/dev/null | grep -c 'Arc Pro B70' || true)
  if ((count > 0)); then
    intel=$(jq -n --argjson count "$count" '[{backend:"intel-xpu", product:"Intel Arc Pro B70", count:$count,
      memoryBytesEach:34359738368, devices:[range(0;$count)|{index:.,totalMiB:32768,freeMiB:32768}]}]')
  fi
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && docker=true
  disk=$(df -Pk "$AI_USER_HOME" | awk 'NR == 2 {print $4 * 1024}')
  jq -n --argjson groups "$(jq -n --argjson a "$nvidia" --argjson b "$intel" '$a+$b')" \
    --argjson docker "$docker" --argjson disk "${disk:-0}" '{groups:$groups,dockerReady:$docker,diskFreeBytes:$disk}'
}

hardware_with_registry() {
  local detected known
  detected=$(hardware_json)
  known=$(jq -s '[.[] | {id,name,vendor,accelerator_backend,memory,aliases}]' "$AI_REGISTRY"/hardware/*.json)
  jq --argjson known "$known" '
    def norm: ascii_downcase | gsub("nvidia|geforce|intel|generation|workstation|edition|[0-9]+gb|[^a-z0-9]"; "");
    .groups |= map(. as $g | ([ $known[] | select(.accelerator_backend == $g.backend)
      | select((.name|norm) == ($g.product|norm) or any(.aliases[]?; (. | norm) == ($g.product|norm)))
      | select((((.memory.vram_gb * 1024) - ($g.memoryBytesEach / 1048576)) | fabs) <= 1024) ][0]) as $match
      | . + {registryId:($match.id // ""), registryName:($match.name // "")})
  ' <<<"$detected"
}

resolved_recipe() {
  local id=$1 local=$2 recipe instance model hardware sweeps='[]' sweep out source registry_root
  registry_root=$(realpath "$AI_REGISTRY")
  recipe=$(<"$AI_REGISTRY/recipe/$id.json")
  instance=$(<"$AI_REGISTRY/model-instance/$(jq -r '.model_instance_id' <<<"$recipe").json")
  model=$(<"$AI_REGISTRY/model/$(jq -r '.model_id' <<<"$instance").json")
  hardware=$(<"$AI_REGISTRY/hardware/$(jq -r '.hardware_id' <<<"$recipe").json")
  while IFS= read -r sweep; do
    [[ -f $AI_REGISTRY/speed-sweeps/$sweep.json ]] || continue
    sweeps=$(jq -c --argjson rows "$sweeps" --slurpfile row "$AI_REGISTRY/speed-sweeps/$sweep.json" '$rows + $row' <<<null)
  done < <(jq -r '.speed_sweeps_ids[]?' <<<"$recipe")
  out=$(jq -n --argjson r "$recipe" --argjson i "$instance" --argjson m "$model" --argjson h "$hardware" \
    --argjson local "$local" --argjson sweeps "$sweeps" '
    def arg($name): (.launch.arguments | index($name)) as $p | if $p == null then null else .launch.arguments[$p+1] end;
    ($local.groups[] | select(.registryId == $r.hardware_id)) as $g
    | {
      schemaVersion:"local-ai-registry/v1", id:$r.id, status:$r.status,
      model:{id:$m.id,name:$m.name,repository:$i.repository,revision:$i.revision,
        servedName:($r|arg("--served-model-name") // $i.served_name // $i.repository), weightFormat:$i.weights.format,
        weightPrecision:$i.weights.precision,downloadBytes:((($i.weights.size_gb // 0)*1073741824)|floor)},
      compatibility:{acceleratorBackend:$h.accelerator_backend,acceleratorCount:$r.hardware_count,
        hardwareId:$h.id,minimumMemoryBytesEach:(($h.memory.vram_gb // 0)*1073741824)},
      endpoint:{protocol:"openai/v1",containerPort:$r.launch.container_port},
      engine:{name:$r.engine.name,version:$r.engine.version,graphMode:$r.engine.graph_mode},
      launch:{adapter:"docker.openai-v1",image:$r.launch.image,entrypoint:($r.launch.entrypoint // null),
        ipc:($r.launch.ipc // null),sharedMemory:($r.launch.shm_size // null),environment:($r.launch.environment // {}),
        arguments:($r.launch.arguments // []),mounts:($r.launch.mounts // []),devices:($r.launch.devices // []),
        capAdd:($r.launch.cap_add // []),securityOpt:($r.launch.security_opt // [])},
      serving:{configuredMaxContextTokens:(($r.serving.max_context_tokens // ($r|arg("--max-model-len")) // 32768)|tonumber),tensorParallel:$r.serving.tensor_parallel},
      capabilities:$r.capabilities,localProduct:$g.product,localCount:$g.count,
      compatible:($g.count >= $r.hardware_count),
      ready:($g.count >= $r.hardware_count and ([ $g.devices[] | select(.freeMiB >= (($h.memory.vram_gb*1024)*0.88)) ] | length) >= $r.hardware_count),
      registrySpeed:([$sweeps[].rows[]? | select(.decode_tok_s != null) | .decode_tok_s] | max // null)
    }
  ' | jq -ce '
    select(.status == "validated" and .launch.adapter == "docker.openai-v1")
    | select(.launch.image | test("@sha256:[0-9a-f]{64}$"))
    | select(.model.revision | test("^[0-9a-f]{40,64}$"))
    | select(.model.downloadBytes > 0)
    | select(([.launch.arguments[]? | select(test("disable.*cuda.*graph|enforce.eager"; "i"))] | length) == 0)
  ') || { fail "registry recipe $id is not safe to launch"; return; }
  while IFS= read -r source; do
    case $source in
      \~/.cache/*|/dev/dri/by-path) ;;
      /*) fail "registry recipe $id mounts an unsafe host path"; return ;;
      *) source=$(realpath "$registry_root/$source") || { fail "registry recipe $id references missing asset $source"; return; }
         [[ $source == "$registry_root/"* ]] || { fail "registry recipe $id references an asset outside the registry"; return; } ;;
    esac
  done < <(jq -r '.launch.mounts[]?.source' <<<"$out")
  printf '%s\n' "$out"
}

registry_snapshot_json() {
  ensure_registry
  local hw ids recipes='[]' id recipe active='{}'
  hw=$(hardware_with_registry)
  ids=$(jq -c '[.groups[].registryId | select(length > 0)]' <<<"$hw")
  [[ -f $AI_ACTIVE ]] && active=$(<"$AI_ACTIVE")
  while IFS= read -r id; do
    recipe=$(resolved_recipe "$id" "$hw" 2>/dev/null) || continue
    recipes=$(jq -c --argjson recipe "$recipe" '. + [$recipe]' <<<"$recipes")
  done < <(jq -r --argjson ids "$ids" '.recipes[] | select(.status=="validated" and .launch_kind=="docker") | select(.hardware_id as $h | $ids | index($h)) | .id' "$AI_REGISTRY/index.json")
  jq -n --argjson hardware "$hw" --argjson recipes "$recipes" --argjson active "$active" --arg path "$AI_REGISTRY" --argjson total "$(jq '.recipes | length' "$AI_REGISTRY/index.json")" '
    ($active.recipe.id // "") as $activeId
    | ($recipes | sort_by([(.id != $activeId), .compatibility.acceleratorCount, (.ready|not), -(.registrySpeed // 0), .model.name])) as $ranked
    | {schemaVersion:"local-ai-registry/v1",registry:{path:$path,recipeCount:($recipes|length),totalRecipeCount:$total},hardware:$hardware,active:$active,recipes:$ranked,
      models:[$ranked[] | {id:.model.id,name:.model.name,compatible:.compatible,ready:.ready,
        recipeId:.id,engine:.engine.name,precision:.model.weightPrecision,hardware:.localProduct,
        acceleratorCount:.compatibility.acceleratorCount,registrySpeed:.registrySpeed,active:(.id==$activeId)}]}
  '
}

recipe_json() {
  local wanted=$1 snapshot
  snapshot=$(registry_snapshot_json)
  jq -ce --arg wanted "$wanted" 'first(.recipes[] | select(.id==$wanted or .model.id==$wanted) | select(.compatible)) // empty' <<<"$snapshot" || fail "no compatible registry recipe for $wanted"
}

intel_nodes() {
  if [[ -n ${OMARCHY_AI_INTEL_DEVICES:-} ]]; then printf '%s\n' "$OMARCHY_AI_INTEL_DEVICES"; return; fi
  local pci node
  while read -r pci; do
    node=$(readlink -f "/dev/dri/by-path/pci-$pci-render" 2>/dev/null || true)
    [[ -n $node ]] && printf '%s\n' "$node"
  done < <(lspci -Dnn | awk '/Arc Pro B70/{print $1}')
}

plan_json() {
  local recipe=$1 backend count image entry ids='' source target mode shm value registry_root
  registry_root=$(realpath "$AI_REGISTRY")
  backend=$(jq -r '.compatibility.acceleratorBackend' <<<"$recipe")
  count=$(jq -r '.compatibility.acceleratorCount' <<<"$recipe")
  image=$(jq -r '.launch.image' <<<"$recipe")
  entry=$(jq -r '.launch.entrypoint // empty' <<<"$recipe")
  local -a argv=(docker run --detach --name "$AI_CONTAINER" --restart unless-stopped
    --label io.omarchy.local-ai=1 --label "io.omarchy.local-ai.recipe=$(jq -r '.id' <<<"$recipe")")
  if [[ $backend == "nvidia" ]]; then
    ids=$(hardware_json | jq -r --arg product "$(jq -r '.localProduct' <<<"$recipe")" --argjson need "$count" '
      [.groups[]|select(.product==$product).devices[]]|sort_by(-.freeMiB)|.[:$need]|map(.index)|join(",")')
    [[ -n $ids ]] || fail "compatible NVIDIA GPUs are busy"
    argv+=(--gpus "device=$ids")
  elif jq -e '.launch.devices | index("/dev/dri")' >/dev/null <<<"$recipe"; then
    argv+=(--device /dev/dri:/dev/dri)
  else
    mapfile -t nodes < <(intel_nodes | head -n "$count")
    ((${#nodes[@]} == count)) || fail "Intel render devices are unavailable"
    for node in "${nodes[@]}"; do argv+=(--device "$node:$node"); done
  fi
  while IFS= read -r value; do [[ $backend == intel-xpu && $value == SYS_PTRACE ]] || { fail "registry requests unsupported capability $value"; return; }; argv+=(--cap-add "$value"); done < <(jq -r '.launch.capAdd[]?' <<<"$recipe")
  while IFS= read -r value; do [[ $backend == intel-xpu && $value == seccomp=unconfined ]] || { fail "registry requests unsupported security option $value"; return; }; argv+=(--security-opt "$value"); done < <(jq -r '.launch.securityOpt[]?' <<<"$recipe")
  argv+=(--publish "127.0.0.1:$AI_PORT:$(jq -r '.endpoint.containerPort' <<<"$recipe")")
  [[ $(jq -r '.launch.ipc // ""' <<<"$recipe") == "host" ]] && argv+=(--ipc host)
  shm=$(jq -r '.launch.sharedMemory // empty' <<<"$recipe"); [[ -n $shm ]] && argv+=(--shm-size "$shm")
  while IFS=$'\t' read -r source target mode; do
    [[ -n $source && -n $target ]] || continue
    if [[ $source == \~/* ]]; then source=${source/#\~/$AI_USER_HOME}; elif [[ $source != /* ]]; then source=$(realpath "$registry_root/$source") || { fail "registry mount is missing"; return; }; fi
    [[ $source == "$AI_USER_HOME/.cache/"* || $source == "/dev/dri/by-path" || $source == "$registry_root/"* ]] || fail "registry mount is outside the local boundary"
    [[ $source == "$AI_USER_HOME/.cache/"* ]] && mkdir -p "$source"
    argv+=(--volume "$source:$target$mode")
  done < <(jq -r '.launch.mounts[]? | [.source,.target,(if .read_only then ":ro" else "" end)] | @tsv' <<<"$recipe")
  while IFS= read -r pair; do argv+=(--env "$pair"); done < <(jq -r '.launch.environment|to_entries[]?|"\(.key)=\(.value)"' <<<"$recipe")
  [[ -n $entry ]] && argv+=(--entrypoint "$entry")
  argv+=("$image")
  while IFS= read -r arg; do argv+=("$arg"); done < <(jq -r '.launch.arguments[]' <<<"$recipe")
  printf '%s\0' "${argv[@]}" | jq -Rs --argjson recipe "$recipe" --argjson port "$AI_PORT" '{recipe:$recipe,port:$port,argv:(split("\u0000")[:-1])}'
}

download_plan_json() {
  local recipe=$1 image repository revision served source target file pull fetch registry_root
  registry_root=$(realpath "$AI_REGISTRY")
  image=$(jq -r '.launch.image' <<<"$recipe")
  repository=$(jq -r '.model.repository' <<<"$recipe")
  revision=$(jq -r '.model.revision' <<<"$recipe")
  served=$(jq -r '.model.servedName' <<<"$recipe")
  local -a pull_argv=(docker pull "$image")
  local -a fetch_argv=(docker run --rm --label io.omarchy.local-ai.download=1 --entrypoint hf)
  while IFS=$'\t' read -r source target; do
    [[ -n $source && -n $target && $source != /dev/dri/by-path ]] || continue
    if [[ $source == \~/* ]]; then source=${source/#\~/$AI_USER_HOME}; elif [[ $source != /* ]]; then source=$(realpath "$registry_root/$source") || { fail "registry mount is missing"; return; }; fi
    [[ $source == "$AI_USER_HOME/.cache/"* || $source == "$registry_root/"* ]] || fail "registry cache mount is outside the local boundary"
    mkdir -p "$source"; fetch_argv+=(--volume "$source:$target")
  done < <(jq -r '.launch.mounts[]? | select(.target=="/models" or (.target|contains("huggingface"))) | [.source,.target] | @tsv' <<<"$recipe")
  fetch_argv+=("$image" download "$repository" --revision "$revision")
  if [[ $served == /models/* ]]; then
    file=${served##*/}; fetch_argv+=("$file" --local-dir /models)
  fi
  pull=$(printf '%s\0' "${pull_argv[@]}" | jq -Rs 'split("\u0000")[:-1]')
  fetch=$(printf '%s\0' "${fetch_argv[@]}" | jq -Rs 'split("\u0000")[:-1]')
  jq -n --argjson pull "$pull" --argjson fetch "$fetch" '{pull:$pull,fetch:$fetch}'
}

download_recipe() {
  local wanted=$1 recipe plan id
  recipe=$(recipe_json "$wanted"); id=$(jq -r '.id' <<<"$recipe")
  plan=$(download_plan_json "$recipe")
  mapfile -t argv < <(jq -r '.pull[]' <<<"$plan"); "${argv[@]}"
  if downloads_json "$(registry_snapshot_json)" | jq -e --arg id "$id" '.[]|select(.id==$id and .modelDownloaded and .imageDownloaded)' >/dev/null; then
    printf 'downloaded · %s\n' "$(jq -r '.model.name' <<<"$recipe")"; return
  fi
  mapfile -t argv < <(jq -r '.fetch[]' <<<"$plan"); "${argv[@]}"
  downloads_json "$(registry_snapshot_json)" | jq -e --arg id "$id" '.[]|select(.id==$id and .modelDownloaded and .imageDownloaded)' >/dev/null \
    || fail "download finished but the registry-declared files are incomplete"
  printf 'downloaded · %s\n' "$(jq -r '.model.name' <<<"$recipe")"
}

served_model() {
  curl -fsS --max-time 5 "http://127.0.0.1:$AI_PORT/v1/models" | jq -er '.data[0].id'
}

request_json() {
  local recipe=$1 prompt=$2 model
  model=$(served_model)
  curl -fsS --max-time 600 "http://127.0.0.1:$AI_PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$model" --arg prompt "$prompt" '{model:$model,messages:[{role:"user",content:$prompt}],stream:false}')"
}

accept_model() {
  local recipe=$1 deadline reply
  deadline=$((SECONDS + ${OMARCHY_AI_TIMEOUT:-7200}))
  while ((SECONDS < deadline)); do
    if served_model >/dev/null 2>&1; then break; fi
    [[ $(docker inspect -f '{{.State.Running}}' "$AI_CONTAINER" 2>/dev/null) == true ]] || return 1
    sleep 5
  done
  reply=$(request_json "$recipe" "Reply with exactly: LOCAL_AI_READY") || return 1
  jq -e '[(.choices[0].message.content // ""),(.choices[0].message.reasoning_content // "")]|join(" ")|contains("LOCAL_AI_READY")' <<<"$reply" >/dev/null
}

omp_yaml() {
  local action=$1 model=${2:-} provider=${3:-} dir="$AI_USER_HOME/.omp/agent"
  mkdir -p "$dir"
  LOCAL_PROVIDER="$provider" ruby -ryaml -rjson -e '
    path, action = ARGV; data = File.exist?(path) ? (YAML.safe_load(File.read(path)) || {}) : {}; raise "invalid #{path}" unless data.is_a?(Hash)
    providers = data["providers"] ||= {}; action == "set" ? providers["omarchy-local"] = JSON.parse(ENV.fetch("LOCAL_PROVIDER")) : providers.delete("omarchy-local")
    tmp = "#{path}.tmp.#{$$}"; File.write(tmp, JSON.pretty_generate(data) + "\n"); File.rename(tmp, path)
  ' "$dir/models.yml" "$action"
  ruby -ryaml -rjson -e '
    path, action, model = ARGV; data = File.exist?(path) ? (YAML.safe_load(File.read(path)) || {}) : {}; raise "invalid #{path}" unless data.is_a?(Hash)
    roles = data["modelRoles"] ||= {}; current = roles["default"]
    if action == "set" && (current.nil? || current.start_with?("omarchy-local/")); roles["default"] = "omarchy-local/#{model}"
    elsif action == "del" && current&.start_with?("omarchy-local/"); roles.delete("default"); data.delete("modelRoles") if roles.empty?; end
    tmp = "#{path}.tmp.#{$$}"; File.write(tmp, JSON.pretty_generate(data) + "\n"); File.rename(tmp, path)
  ' "$dir/config.yml" "$action" "$model"
}

wire_agents() {
  local recipe=$1 model provider dir current tmp
  model=$(served_model)
  provider=$(jq -n --arg url "http://127.0.0.1:$AI_PORT/v1" --arg model "$model" --arg name "$(jq -r '.model.name // .model.id' <<<"$recipe")" \
    --argjson context "$(jq -r '.serving.configuredMaxContextTokens // 0' <<<"$recipe")" \
    '{baseUrl:$url,apiKey:"local",api:"openai-completions",models:[{id:$model,name:($name+" · local"),reasoning:false,input:["text"],contextWindow:$context,cost:{input:0,output:0,cacheRead:0,cacheWrite:0}}]}')
  for dir in "$AI_USER_HOME/.pi/agent" "$AI_USER_HOME/.omp/agent"; do
    mkdir -p "$dir"
    [[ -f $dir/models.json ]] && current=$(<"$dir/models.json") || current='{}'; jq -e 'type=="object"' <<<"$current" >/dev/null || fail "invalid $dir/models.json"
    tmp=$(mktemp "$dir/.models.XXXXXX"); jq --argjson p "$provider" '.providers.local=$p' <<<"$current" >"$tmp"; mv "$tmp" "$dir/models.json"
    [[ -f $dir/settings.json ]] && current=$(<"$dir/settings.json") || current='{}'; jq -e 'type=="object"' <<<"$current" >/dev/null || fail "invalid $dir/settings.json"
    tmp=$(mktemp "$dir/.settings.XXXXXX"); jq --arg model "$model" 'if .defaultProvider==null or .defaultProvider=="local" then .defaultProvider="local"|.defaultModel=$model else . end' <<<"$current" >"$tmp"; mv "$tmp" "$dir/settings.json"
  done
  omp_yaml set "$model" "$(jq 'del(.apiKey) + {auth:"none"}' <<<"$provider")"
}

harness_bin() { [[ -x $AI_USER_HOME/.local/bin/$1 ]] && printf '%s\n' "$AI_USER_HOME/.local/bin/$1" || command -v "$1"; }

claude_bridge() {
  local model config uvx deadline
  model=$(served_model); uvx=$(harness_bin uvx) || fail "uvx is required for Claude Code"
  mkdir -p "$AI_STATE"; config="$AI_STATE/claude-litellm.json"
  jq -n --arg model "$model" --arg url "http://127.0.0.1:$AI_PORT/v1" '{model_list:[{model_name:"omarchy-local",litellm_params:{model:("openai/"+$model),api_base:$url,api_key:"local"}}]}' >"$config"
  systemctl --user stop "$AI_CLAUDE_UNIT" >/dev/null 2>&1 || true
  systemd-run --user --unit="${AI_CLAUDE_UNIT%.service}" --collect --property=Restart=on-failure "$uvx" --from 'litellm[proxy]' litellm --config "$config" --host 127.0.0.1 --port 12435 >/dev/null
  deadline=$((SECONDS+120)); until curl -fsS http://127.0.0.1:12435/health/liveliness >/dev/null 2>&1; do ((SECONDS<deadline)) || fail "Claude bridge did not become ready"; sleep 1; done
}

open_harness() {
  local name=${1:-} bin
  [[ $(jq -r .ready <<<"$(status_json)") == true ]] || fail "load a model first"
  case $name in
    pi|omp) bin=$(harness_bin "$name") || fail "$name is not installed"; [[ $name == omp ]] && exec omarchy-launch-tui --app-id=org.omarchy.agent "$bin" --auto-approve || exec omarchy-launch-tui --app-id=org.omarchy.agent "$bin" ;;
    claude) bin=$(harness_bin claude) || fail "Claude Code is not installed"; claude_bridge; exec omarchy-launch-tui --app-id=org.omarchy.agent env ANTHROPIC_BASE_URL=http://127.0.0.1:12435 ANTHROPIC_AUTH_TOKEN=local ANTHROPIC_MODEL=omarchy-local ANTHROPIC_SMALL_FAST_MODEL=omarchy-local CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 "$bin" --model omarchy-local ;;
    *) fail "choose pi, omp, or claude" ;;
  esac
}

record_usage() {
  local recipe=$1 response=$2 dir="$AI_USER_HOME/.local/state/omarchy/agents/usage" file day tmp old='{}'
  day=$(date +%F); mkdir -p "$dir"; file="$dir/local-ai.json"; [[ -f $file ]] && old=$(<"$file"); tmp=$(mktemp "$dir/.local-ai.XXXXXX")
  jq -n --arg day "$day" --arg now "$(date -Is)" --arg model "$(jq -r '.model.id' <<<"$recipe")" \
    --argjson input "$(jq -r '.usage.prompt_tokens // 0' <<<"$response")" --argjson output "$(jq -r '.usage.completion_tokens // 0' <<<"$response")" --argjson old "$old" \
    '{schemaVersion:1,id:"local-ai",name:"Local AI",updatedAt:$now,ready:true,hasLocalStats:true,hasPromptStats:true,tierLabel:"On-device",usageStatusText:"Ready",authHelpText:"",limits:[],todayPrompts:(($old.todayPrompts//0)+1),todaySessions:1,totalPrompts:(($old.totalPrompts//0)+1),totalSessions:1,todayTotalTokens:(($old.todayTotalTokens//0)+$input+$output),activeDays:1,activeDates:[$day],recentDays:[{date:$day,messageCount:(($old.todayTotalTokens//0)+$input+$output)}],modelUsage:{($model):{inputTokens:(($old.modelUsage[$model].inputTokens//0)+$input),outputTokens:(($old.modelUsage[$model].outputTokens//0)+$output),cacheReadInputTokens:0,cacheCreationInputTokens:0}}}' >"$tmp"
  mv "$tmp" "$file"
}

run_recipe() {
  local wanted=$1 recipe plan old="${AI_CONTAINER}-previous" old_running=false reply id
  recipe=$(recipe_json "$wanted")
  id=$(jq -r '.id' <<<"$recipe")
  downloads_json "$(registry_snapshot_json)" | jq -e --arg id "$id" '.[]|select(.id==$id and .modelDownloaded and .imageDownloaded)' >/dev/null \
    || fail "model is not downloaded; run download first"
  if docker inspect "$AI_CONTAINER" >/dev/null 2>&1; then
    [[ $(docker inspect -f '{{index .Config.Labels "io.omarchy.local-ai"}}' "$AI_CONTAINER") == 1 ]] || fail "$AI_CONTAINER exists but is not managed by this plugin"
    [[ $(docker inspect -f '{{.State.Running}}' "$AI_CONTAINER") == true ]] && old_running=true && docker stop "$AI_CONTAINER" >/dev/null
    docker rename "$AI_CONTAINER" "$old"
  fi
  recipe=$(recipe_json "$wanted")
  if [[ $(jq -r '.ready' <<<"$recipe") != true ]] || ! plan=$(plan_json "$recipe"); then
    if docker inspect "$old" >/dev/null 2>&1; then docker rename "$old" "$AI_CONTAINER"; $old_running && docker start "$AI_CONTAINER" >/dev/null; fi
    fail "compatible hardware is currently busy; previous model restored"; return
  fi
  mapfile -t argv < <(jq -r '.argv[]' <<<"$plan")
  if ! "${argv[@]}" >/dev/null || ! accept_model "$recipe"; then
    docker rm -f "$AI_CONTAINER" >/dev/null 2>&1 || true
    if docker inspect "$old" >/dev/null 2>&1; then docker rename "$old" "$AI_CONTAINER"; $old_running && docker start "$AI_CONTAINER" >/dev/null; fi
    fail "new model failed acceptance; previous model restored"; return
  fi
  docker rm -f "$old" >/dev/null 2>&1 || true
  mkdir -p "$AI_STATE"; jq -n --argjson recipe "$recipe" --argjson port "$AI_PORT" '{recipe:$recipe,port:$port}' >"$AI_ACTIVE"
  wire_agents "$recipe"; reply=$(request_json "$recipe" "Reply with exactly: LOCAL_AI_READY"); record_usage "$recipe" "$reply"
  notify; printf 'ready · %s · http://127.0.0.1:%s/v1\n' "$(jq -r '.model.name // .model.id' <<<"$recipe")" "$AI_PORT"
}

active_recipe() { [[ -f $AI_ACTIVE ]] || fail "no active model"; jq -c '.recipe' "$AI_ACTIVE"; }

status_json() {
  if [[ ! -f $AI_ACTIVE ]]; then jq -n '{state:"not-setup",ready:false,running:false}'; return; fi
  local running=false ready=false recipe
  recipe=$(active_recipe)
  [[ $(docker inspect -f '{{.State.Running}}' "$AI_CONTAINER" 2>/dev/null) == true ]] && running=true
  $running && served_model >/dev/null 2>&1 && ready=true
  jq -n --arg model "$(jq -r '.model.name // .model.id' <<<"$recipe")" --arg recipe "$(jq -r '.id' <<<"$recipe")" \
    --arg engine "$(jq -r '.engine.name' <<<"$recipe")" --argjson running "$running" --argjson ready "$ready" --argjson port "$AI_PORT" \
    '{state:(if $ready then "ready" elif $running then "loading" else "stopped" end),ready:$ready,running:$running,model:$model,recipeId:$recipe,engine:$engine,port:$port}'
}

downloads_json() {
  local snapshot=${1:-} recipe id model repository expected image bytes image_ready model_ready source size repo_cache
  [[ -n $snapshot ]] || snapshot=$(registry_snapshot_json)
  while IFS= read -r recipe; do
    id=$(jq -r '.id' <<<"$recipe"); model=$(jq -r '.model.name' <<<"$recipe"); repository=$(jq -r '.model.repository' <<<"$recipe"); expected=$(jq -r '.model.downloadBytes' <<<"$recipe"); image=$(jq -r '.launch.image' <<<"$recipe")
    bytes=0
    repo_cache="$AI_USER_HOME/.cache/huggingface/hub/models--${repository//\//--}"
    if [[ -d $repo_cache ]]; then bytes=$(du -skL "$repo_cache" | awk '{print $1 * 1024}'); fi
    while IFS= read -r source; do
      source=${source/#\~/$AI_USER_HOME}; [[ -d $source ]] || continue; size=$(du -skL "$source" | awk '{print $1 * 1024}'); bytes=$((bytes + size))
    done < <(jq -r '.launch.mounts[]? | select((.source|startswith("~/.cache/")) and (.target|test("/models$"))) | .source' <<<"$recipe")
    image_ready=false; docker image inspect "$image" >/dev/null 2>&1 && image_ready=true
    model_ready=false; ((expected > 0 && bytes * 100 >= expected * 85)) && model_ready=true
    jq -nc --arg id "$id" --arg model "$model" --argjson expected "$expected" --argjson bytes "$bytes" --argjson image "$image_ready" --argjson downloaded "$model_ready" \
      '{id:$id,model:$model,expectedBytes:$expected,localBytes:$bytes,imageDownloaded:$image,modelDownloaded:$downloaded}'
  done < <(jq -c '.recipes[]' <<<"$snapshot") | jq -s .
}

task_model() {
  local prompt=${1:-'Explain in three short bullets why loopback-only model serving is safer than LAN exposure.'} recipe reply
  recipe=$(active_recipe); reply=$(request_json "$recipe" "$prompt"); record_usage "$recipe" "$reply"
  jq -r '.choices[0].message.content // .choices[0].message.reasoning_content // ""' <<<"$reply"; notify
}

benchmark_model() {
  local recipe reply start end seconds tokens row runs=${OMARCHY_AI_BENCH_RUNS:-3} results='[]'
  recipe=$(active_recipe)
  for ((i=1;i<=runs;i++)); do
    start=$(date +%s%N); reply=$(request_json "$recipe" 'Write exactly 128 numbered lines. Each line must contain one lowercase English word.'); end=$(date +%s%N)
    seconds=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f",(b-a)/1000000000}'); tokens=$(jq -r '.usage.completion_tokens // 0' <<<"$reply")
    row=$(jq -nc --argjson run "$i" --argjson seconds "$seconds" --argjson tokens "$tokens" '{run:$run,seconds:$seconds,outputTokens:$tokens,tokensPerSecond:(if $seconds>0 then $tokens/$seconds else 0 end)}')
    results=$(jq --argjson row "$row" '.+[$row]' <<<"$results")
  done
  mkdir -p "$AI_STATE"; jq -n --arg recipeId "$(jq -r '.id' <<<"$recipe")" --arg model "$(jq -r '.model.name // .model.id' <<<"$recipe")" --arg measuredAt "$(date -Is)" --argjson runs "$results" \
    '{recipeId:$recipeId,model:$model,measuredAt:$measuredAt,runs:$runs,medianTokensPerSecond:([$runs[].tokensPerSecond]|sort|.[length/2|floor])}' | tee "$AI_BENCHMARK"
}

snapshot_json() {
  local snapshot status downloads benchmark='null'
  snapshot=$(registry_snapshot_json); status=$(status_json); downloads=$(downloads_json "$snapshot")
  if [[ -f $AI_BENCHMARK ]] && [[ $(jq -r '.recipeId // ""' "$AI_BENCHMARK") == $(jq -r '.recipeId // ""' <<<"$status") ]]; then benchmark=$(<"$AI_BENCHMARK"); fi
  jq --argjson status "$status" --argjson downloads "$downloads" --argjson benchmark "$benchmark" '
    . + {status:$status,downloads:$downloads,benchmark:$benchmark}
    | .models |= map(. as $m | ([ $downloads[] | select(.id==$m.recipeId) ][0] // {}) as $d | . + {downloaded:(($d.modelDownloaded // false) and ($d.imageDownloaded // false))})
    | .status.model = ([.recipes[] | select(.id==$status.recipeId) | .model.name][0] // $status.model)
  ' <<<"$snapshot"
}

unwire_agents() {
  local dir tmp
  for dir in "$AI_USER_HOME/.pi/agent" "$AI_USER_HOME/.omp/agent"; do
    [[ -f $dir/models.json ]] && tmp=$(mktemp "$dir/.models.XXXXXX") && jq 'del(.providers.local)' "$dir/models.json" >"$tmp" && mv "$tmp" "$dir/models.json"
    [[ -f $dir/settings.json ]] && tmp=$(mktemp "$dir/.settings.XXXXXX") && jq 'if .defaultProvider=="local" then del(.defaultProvider,.defaultModel) else . end' "$dir/settings.json" >"$tmp" && mv "$tmp" "$dir/settings.json"
  done
  omp_yaml del
}

unload_model() {
  systemctl --user stop "$AI_CLAUDE_UNIT" >/dev/null 2>&1 || true
  docker rm -f "$AI_CONTAINER" >/dev/null 2>&1 || true
  rm -f "$AI_ACTIVE" "$AI_USER_HOME/.local/state/omarchy/agents/usage/local-ai.json"
  unwire_agents; notify; echo 'unloaded · downloads kept'
}
