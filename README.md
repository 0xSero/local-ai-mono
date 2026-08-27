# Omarchy Local AI

A small, native Omarchy plugin that turns the read-only [Local AI registry](https://inference-index-api.vercel.app/v1) into one honest model lifecycle.

```text
hardware → registry → model → Docker → real completion → OMP / Pi / Omarchy Agents
```

The registry remains truth. The plugin keeps one validated cache, detects NVIDIA and Intel Arc Pro B70 hardware, shows every registry model, and enables only recipes that match the machine. It never invents launch flags or scales a recipe.

## Install

```bash
omarchy plugin add https://github.com/0xSero/omarchy-local-ai.git --yes
omarchy plugin enable sero.local-ai
```

The panel resolves its CLI from its own checkout, so no files are copied into `/usr/share/omarchy`.

## Use

```bash
./bin/omarchy-local-ai sync
./bin/omarchy-local-ai hardware
./bin/omarchy-local-ai models
./bin/omarchy-local-ai run
./bin/omarchy-local-ai status
./bin/omarchy-local-ai downloads
./bin/omarchy-local-ai task "Explain this code"
./bin/omarchy-local-ai benchmark
./bin/omarchy-local-ai stop
./bin/omarchy-local-ai start
./bin/omarchy-local-ai remove
```

`run` performs the complete transaction: select exact hardware, build the registry-declared Docker command, bind the API to loopback, download as needed, wait for `/v1/models`, require a real completion, atomically record state, and wire the model into OMP and Pi. A failed model switch restores the previous managed container.

`downloads` reports image and weight-cache state. `benchmark` records three live runs and reports median output throughput. `task` sends real work and writes token usage into the existing `omarchy.agents` record directory.

## Safety contract

- Only `validated` `docker.openai-v1` recipes run.
- Images require SHA-256 digests and models require immutable revisions.
- CUDA graphs remain enabled; eager mode and graph-disabling arguments are rejected.
- The endpoint binds only to `127.0.0.1`.
- User agent JSON is validated and updated atomically.
- Removing the runtime keeps downloaded weights.
- Registry failures preserve the last good cache.

## Verify

```bash
./test/all
```

The whole repository, including tests and docs, is kept below 1,000 lines.
