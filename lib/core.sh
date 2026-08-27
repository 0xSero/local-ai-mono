#!/bin/bash

set -euo pipefail

AI_ROOT="${AI_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
AI_API="${OMARCHY_AI_API:-https://inference-index-api.vercel.app/v1}"
AI_STATE="${OMARCHY_AI_STATE:-$HOME/.local/state/omarchy/local-ai}"
AI_CACHE="${OMARCHY_AI_CACHE:-$HOME/.cache/omarchy-local-ai}"
AI_CONTAINER="${OMARCHY_AI_CONTAINER:-omarchy-local-ai}"
AI_PORT="${OMARCHY_AI_PORT:-12434}"
AI_CATALOG="$AI_STATE/catalog.json"
AI_ACTIVE="$AI_STATE/active.json"

fail() { echo "local-ai: $*" >&2; return 1; }
notify() { omarchy-shell -q sero.local-ai refresh 2>/dev/null || true; }

catalog_valid() {
  jq -e '
    .schemaVersion == "omarchy-local-ai/v1"
    and (.hardware | type == "array")
    and (.recipes | type == "array" and length > 0)
    and (([.recipes[].id] | unique | length) == (.recipes | length))
    and all(.recipes[];
      .schemaVersion == "omarchy-local-ai/v1"
      and .status == "validated"
      and .launch.adapter == "docker.openai-v1"
      and (.launch.image | test("@sha256:[0-9a-f]{64}$"))
      and (.model.revision | test("^[0-9a-f]{40,64}$"))
      and (.endpoint.protocol == "openai/v1")
      and ([.launch.arguments[]? | select(test("disable.*cuda.*graph|enforce.eager"; "i"))] | length == 0)
    )
  ' "$1" >/dev/null 2>&1
}

sync_catalog() {
  mkdir -p "$AI_STATE"
  local tmp
  tmp=$(mktemp "$AI_STATE/.catalog.XXXXXX")
  if ! curl --fail --silent --show-error --location --connect-timeout 10 "$AI_API/catalog.json" >"$tmp"; then
    rm -f "$tmp"
    fail "registry unavailable; the last good catalog is unchanged"
    return
  fi
  if ! catalog_valid "$tmp"; then
    rm -f "$tmp"
    fail "registry response failed validation; the last good catalog is unchanged"
    return
  fi
  mv "$tmp" "$AI_CATALOG"
  echo "$(jq '.recipes | length' "$AI_CATALOG") recipes · $(jq '[.recipes[].model.id] | unique | length' "$AI_CATALOG") models"
  notify
}

ensure_catalog() {
  [[ -f $AI_CATALOG ]] || sync_catalog >/dev/null
  catalog_valid "$AI_CATALOG" || fail "no valid registry cache; run sync"
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
  disk=$(df -Pk "$HOME" | awk 'NR == 2 {print $4 * 1024}')
  jq -n --argjson groups "$(jq -n --argjson a "$nvidia" --argjson b "$intel" '$a+$b')" \
    --argjson docker "$docker" --argjson disk "${disk:-0}" '{groups:$groups,dockerReady:$docker,diskFreeBytes:$disk}'
}

snapshot_json() {
  ensure_catalog
  local hw active='{}'
  hw=$(hardware_json)
  [[ -f $AI_ACTIVE ]] && active=$(<"$AI_ACTIVE")
  jq --argjson local "$hw" --argjson active "$active" '
    def norm: ascii_downcase | gsub("nvidia|geforce|generation|workstation|server|edition|[0-9]+gb|[^a-z0-9]"; "");
    .hardware as $known
    | [.recipes[] | . as $r | ($known[] | select(.id == $r.compatibility.hardwareId)) as $h
      | ([ $local.groups[] | select(.backend == $h.acceleratorBackend)
          | select((.product|norm) == ($h.product|norm))
          | select(.count >= $h.acceleratorCount and .memoryBytesEach >= $r.compatibility.minimumMemoryBytesEach) ]) as $match
      | . + {compatible:($match|length > 0), ready:([$match[].devices[]?
          | select((.freeMiB * 1048576) >= $r.compatibility.minimumMemoryBytesEach)] | length >= $h.acceleratorCount),
          localProduct:($match[0].product // ""), localCount:($match[0].count // 0)}] as $recipes
    | {schemaVersion, hardware:$local, active:$active, recipes:$recipes,
       models:[$recipes | group_by(.model.id)[] | {id:.[0].model.id,
         compatible:any(.[];.compatible), ready:any(.[];.ready),
         recipeId:(first(.[]|select(.ready)).id // first(.[]|select(.compatible)).id // .[0].id),
         engine:(first(.[]|select(.compatible)).engine.name // .[0].engine.name),
         precision:(first(.[]|select(.compatible)).model.weightPrecision // .[0].model.weightPrecision)}]}
  ' "$AI_CATALOG"
}

recipe_json() {
  local wanted=$1 snapshot
  snapshot=$(snapshot_json)
  jq -ce --arg wanted "$wanted" '
    first(.recipes[] | select(.id == $wanted or .model.id == $wanted) | select(.compatible)) // empty
  ' <<<"$snapshot" || fail "no compatible recipe for $wanted"
}

intel_nodes() {
  if [[ -n ${OMARCHY_AI_INTEL_DEVICES:-} ]]; then printf '%s\n' "$OMARCHY_AI_INTEL_DEVICES"; return; fi
  local pci node
  while read -r pci; do
    node=$(readlink -f "/dev/dri/by-path/pci-$pci-render" 2>/dev/null || true)
    [[ -n $node ]] && echo "$node"
  done < <(lspci -Dnn | awk '/Arc Pro B70/{print $1}')
}

plan_json() {
  local recipe=$1 backend count image entry cache ids=''
  backend=$(jq -r '.compatibility.acceleratorBackend' <<<"$recipe")
  count=$(jq -r '.compatibility.acceleratorCount' <<<"$recipe")
  image=$(jq -r '.launch.image' <<<"$recipe")
  entry=$(jq -r '.launch.entrypoint // empty' <<<"$recipe")
  cache="$AI_CACHE/models/$(jq -r '.id' <<<"$recipe")"
  local -a argv=(docker run --detach --name "$AI_CONTAINER" --restart unless-stopped
    --label io.omarchy.local-ai=1 --label "io.omarchy.local-ai.recipe=$(jq -r '.id' <<<"$recipe")")
  if [[ $backend == "nvidia" ]]; then
    ids=$(hardware_json | jq -r --arg product "$(jq -r '.localProduct' <<<"$recipe")" --argjson need "$count" \
      --argjson minimum "$(jq -r '.compatibility.minimumMemoryBytesEach' <<<"$recipe")" '
      [.groups[]|select(.product==$product).devices[]|select((.freeMiB*1048576)>=$minimum)]|sort_by(-.freeMiB)|.[:$need]|map(.index)|join(",")')
    [[ -n $ids ]] || fail "compatible NVIDIA GPUs are busy"
    argv+=(--gpus "device=$ids")
  else
    mapfile -t nodes < <(intel_nodes | head -n "$count")
    ((${#nodes[@]} == count)) || fail "Intel render devices are unavailable"
    for node in "${nodes[@]}"; do argv+=(--device "$node:$node"); done
  fi
  argv+=(--publish "127.0.0.1:$AI_PORT:$(jq -r '.endpoint.containerPort' <<<"$recipe")")
  [[ $(jq -r '.launch.ipc // ""' <<<"$recipe") == "host" ]] && argv+=(--ipc host)
  local shm
  shm=$(jq -r '.launch.sharedMemoryBytes // 0' <<<"$recipe")
  ((shm > 0)) && argv+=(--shm-size "$((shm / 1073741824))g")
  mkdir -p "$AI_CACHE/huggingface" "$cache"
  argv+=(--volume "$AI_CACHE/huggingface:/root/.cache/huggingface")
  argv+=(--volume "$cache:$(jq -r '.launch.modelCache.containerPath' <<<"$recipe")")
  while IFS= read -r pair; do argv+=(--env "$pair"); done < <(jq -r '.launch.environment|to_entries[]?|"\(.key)=\(.value)"' <<<"$recipe")
  [[ -n $entry ]] && argv+=(--entrypoint "$entry")
  argv+=("$image")
  while IFS= read -r arg; do argv+=("$arg"); done < <(jq -r '.launch.arguments[]' <<<"$recipe")
  printf '%s\0' "${argv[@]}" | jq -Rs --argjson recipe "$recipe" --argjson port "$AI_PORT" \
    '{recipe:$recipe,port:$port,argv:(split("\u0000")[:-1])}'
}

accept_model() {
  local recipe=$1 deadline model reply
  model=$(jq -r '.model.servedName' <<<"$recipe")
  deadline=$((SECONDS + ${OMARCHY_AI_TIMEOUT:-7200}))
  while ((SECONDS < deadline)); do
    if reply=$(curl -fsS --max-time 5 "http://127.0.0.1:$AI_PORT/v1/models" 2>/dev/null) \
      && jq -e --arg model "$model" '.data[]?.id == $model or (.data|length>0)' <<<"$reply" >/dev/null; then break; fi
    [[ $(docker inspect -f '{{.State.Running}}' "$AI_CONTAINER" 2>/dev/null) == true ]] || return 1
    sleep 5
  done
  reply=$(request_json "$recipe" "Reply with exactly: LOCAL_AI_READY") || return 1
  jq -e '.choices[0].message.content | length > 0' <<<"$reply" >/dev/null
}

request_json() {
  local recipe=$1 prompt=$2 model
  model=$(jq -r '.model.servedName' <<<"$recipe")
  curl -fsS --max-time 600 "http://127.0.0.1:$AI_PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' -d "$(jq -n --arg model "$model" --arg prompt "$prompt" \
      '{model:$model,messages:[{role:"user",content:$prompt}],stream:false}')"
}

wire_agents() {
  local recipe=$1 model provider dir current tmp
  model=$(jq -r '.model.servedName' <<<"$recipe")
  provider=$(jq -n --arg url "http://127.0.0.1:$AI_PORT/v1" --arg model "$model" \
    --arg name "$(jq -r '.model.id' <<<"$recipe")" --argjson context "$(jq -r '.serving.configuredMaxContextTokens' <<<"$recipe")" \
    '{baseUrl:$url,apiKey:"local",api:"openai-completions",models:[{id:$model,name:($name+" · local"),reasoning:false,input:["text"],contextWindow:$context,cost:{input:0,output:0,cacheRead:0,cacheWrite:0}}]}')
  for dir in "$HOME/.pi/agent" "$HOME/.omp/agent"; do
    mkdir -p "$dir"
    [[ -f $dir/models.json ]] && current=$(<"$dir/models.json") || current='{}'; jq -e 'type=="object"' <<<"$current" >/dev/null || fail "invalid $dir/models.json"
    tmp=$(mktemp "$dir/.models.XXXXXX"); jq --argjson p "$provider" '.providers.local=$p' <<<"$current" >"$tmp"; mv "$tmp" "$dir/models.json"
    [[ -f $dir/settings.json ]] && current=$(<"$dir/settings.json") || current='{}'; jq -e 'type=="object"' <<<"$current" >/dev/null || fail "invalid $dir/settings.json"
    tmp=$(mktemp "$dir/.settings.XXXXXX"); jq --arg model "$model" 'if .defaultProvider==null or .defaultProvider=="local" then .defaultProvider="local"|.defaultModel=$model else . end' <<<"$current" >"$tmp"; mv "$tmp" "$dir/settings.json"
  done
}

record_usage() {
  local recipe=$1 response=$2 usage_dir="$HOME/.local/state/omarchy/agents/usage" file day tmp
  day=$(date +%F); mkdir -p "$usage_dir"; file="$usage_dir/local-ai.json"
  tmp=$(mktemp "$usage_dir/.local-ai.XXXXXX")
  local old='{}'; [[ -f $file ]] && old=$(<"$file")
  jq -n --arg day "$day" --arg now "$(date -Is)" --arg model "$(jq -r '.model.id' <<<"$recipe")" \
    --argjson input "$(jq -r '.usage.prompt_tokens // 0' <<<"$response")" --argjson output "$(jq -r '.usage.completion_tokens // 0' <<<"$response")" \
    --argjson old "$old" '{schemaVersion:1,id:"local-ai",name:"Local AI",updatedAt:$now,ready:true,
      hasLocalStats:true,hasPromptStats:true,tierLabel:"On-device",usageStatusText:"Ready",authHelpText:"",limits:[],
      todayPrompts:(($old.todayPrompts//0)+1),todaySessions:1,totalPrompts:(($old.totalPrompts//0)+1),totalSessions:1,
      todayTotalTokens:(($old.todayTotalTokens//0)+$input+$output),activeDays:1,activeDates:[$day],
      recentDays:[{date:$day,messageCount:(($old.todayTotalTokens//0)+$input+$output)}],
      modelUsage:{($model):{inputTokens:(($old.modelUsage[$model].inputTokens//0)+$input),outputTokens:(($old.modelUsage[$model].outputTokens//0)+$output),cacheReadInputTokens:0,cacheCreationInputTokens:0}}}' >"$tmp"
  mv "$tmp" "$file"
}

run_recipe() {
  local wanted=$1 recipe plan old="${AI_CONTAINER}-previous" old_running=false
  recipe=$(recipe_json "$wanted"); [[ $(jq -r '.ready' <<<"$recipe") == true ]] || fail "compatible hardware is currently busy"
  plan=$(plan_json "$recipe")
  if docker inspect "$AI_CONTAINER" >/dev/null 2>&1; then
    [[ $(docker inspect -f '{{index .Config.Labels "io.omarchy.local-ai"}}' "$AI_CONTAINER") == 1 ]] || fail "$AI_CONTAINER exists but is not managed by this plugin"
    [[ $(docker inspect -f '{{.State.Running}}' "$AI_CONTAINER") == true ]] && old_running=true && docker stop "$AI_CONTAINER" >/dev/null
    docker rename "$AI_CONTAINER" "$old"
  fi
  mapfile -t argv < <(jq -r '.argv[]' <<<"$plan")
  if ! "${argv[@]}" >/dev/null || ! accept_model "$recipe"; then
    docker rm -f "$AI_CONTAINER" >/dev/null 2>&1 || true
    if docker inspect "$old" >/dev/null 2>&1; then docker rename "$old" "$AI_CONTAINER"; $old_running && docker start "$AI_CONTAINER" >/dev/null; fi
    fail "new model failed acceptance; previous model restored"
    return
  fi
  docker rm -f "$old" >/dev/null 2>&1 || true
  mkdir -p "$AI_STATE"; jq -n --argjson recipe "$recipe" --argjson port "$AI_PORT" '{recipe:$recipe,port:$port}' >"$AI_ACTIVE"
  wire_agents "$recipe"
  local reply; reply=$(request_json "$recipe" "Reply with exactly: LOCAL_AI_READY"); record_usage "$recipe" "$reply"
  notify; echo "ready · $(jq -r '.model.id' <<<"$recipe") · http://127.0.0.1:$AI_PORT/v1"
}

active_recipe() { [[ -f $AI_ACTIVE ]] || fail "no active model"; jq -c '.recipe' "$AI_ACTIVE"; }

status_json() {
  if [[ ! -f $AI_ACTIVE ]]; then jq -n '{state:"not-setup",ready:false}'; return; fi
  local running=false ready=false recipe model
  recipe=$(active_recipe); model=$(jq -r '.model.servedName' <<<"$recipe")
  [[ $(docker inspect -f '{{.State.Running}}' "$AI_CONTAINER" 2>/dev/null) == true ]] && running=true
  $running && curl -fsS --max-time 3 "http://127.0.0.1:$AI_PORT/v1/models" 2>/dev/null | jq -e --arg model "$model" '.data[]?.id==$model or (.data|length>0)' >/dev/null && ready=true
  jq -n --arg model "$(jq -r '.model.id' <<<"$recipe")" --argjson running "$running" --argjson ready "$ready" \
    --argjson port "$AI_PORT" '{state:(if $ready then "ready" elif $running then "loading" else "stopped" end),ready:$ready,running:$running,model:$model,port:$port}'
}

downloads_json() {
  local snapshot; snapshot=$(snapshot_json)
  jq -c '.recipes[]|select(.compatible)|[.id,.model.id,.model.downloadBytes,.launch.image]|@tsv' <<<"$snapshot" | while IFS=$'\t' read -r id model expected image; do
    local bytes=0 image_ready=false model_ready=false path="$AI_CACHE/models/$id"
    [[ -d $path ]] && bytes=$(du -sb "$path" | cut -f1)
    docker image inspect "$image" >/dev/null 2>&1 && image_ready=true
    ((expected == 0 || bytes * 100 >= expected * 95)) && model_ready=true
    jq -nc --arg id "$id" --arg model "$model" --argjson expected "$expected" --argjson bytes "$bytes" \
      --argjson image "$image_ready" --argjson downloaded "$model_ready" '{id:$id,model:$model,expectedBytes:$expected,localBytes:$bytes,imageDownloaded:$image,modelDownloaded:$downloaded}'
  done | jq -s .
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
    start=$(date +%s%N)
    reply=$(request_json "$recipe" 'Write exactly 128 numbered lines. Each line must contain one lowercase English word.')
    end=$(date +%s%N); seconds=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f",(b-a)/1000000000}')
    tokens=$(jq -r '.usage.completion_tokens // 0' <<<"$reply")
    row=$(jq -nc --argjson run "$i" --argjson seconds "$seconds" --argjson tokens "$tokens" \
      '{run:$run,seconds:$seconds,outputTokens:$tokens,tokensPerSecond:(if $seconds>0 then $tokens/$seconds else 0 end)}')
    results=$(jq --argjson row "$row" '.+[$row]' <<<"$results")
  done
  jq -n --arg model "$(jq -r '.model.id' <<<"$recipe")" --argjson runs "$results" \
    '{model:$model,runs:$runs,medianTokensPerSecond:([$runs[].tokensPerSecond]|sort|.[length/2|floor])}' | tee "$AI_STATE/benchmark.json"
}

unwire_agents() {
  local dir tmp
  for dir in "$HOME/.pi/agent" "$HOME/.omp/agent"; do
    [[ -f $dir/models.json ]] && tmp=$(mktemp "$dir/.models.XXXXXX") && jq 'del(.providers.local)' "$dir/models.json" >"$tmp" && mv "$tmp" "$dir/models.json"
    [[ -f $dir/settings.json ]] && tmp=$(mktemp "$dir/.settings.XXXXXX") && jq 'if .defaultProvider=="local" then del(.defaultProvider,.defaultModel) else . end' "$dir/settings.json" >"$tmp" && mv "$tmp" "$dir/settings.json"
  done
}
