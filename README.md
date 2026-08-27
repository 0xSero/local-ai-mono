# Omarchy Local AI

A small, native Omarchy plugin that turns the read-only [0xSero Local AI Registry](https://github.com/0xSero/local-ai-registry) into one honest model lifecycle.

```text
hardware → registry → model → Docker → real completion → OMP / Pi / Omarchy Agents
```

The registry remains truth. It is checked out at `~/omarchy/local-ai`, and the plugin reads its normalized `registry/index.json` discovery document before resolving the exact referenced model, artifact, hardware, launch, and speed records. It detects NVIDIA and Intel Arc Pro B70 hardware, displays only validated Docker recipes that match the machine, and never invents models, labels, launch flags, or benchmark results.

## Install

```bash
omarchy plugin add https://github.com/0xSero/omarchy-local-ai.git --yes
omarchy plugin enable sero.local-ai
~/.config/omarchy/plugins/sero.local-ai/bin/omarchy-local-ai sync
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

`sync` clones or fast-forwards the public registry on `main`. It refuses to overwrite a dirty registry checkout. `run` performs the complete transaction: select exact hardware, build the registry-declared Docker command, bind the API to loopback, download as needed, wait for `/v1/models`, require a real completion, atomically record state, and wire the model into OMP and Pi. A failed model switch restores the previous managed container.

`downloads` reports image and weight-cache state. `benchmark` records three live runs and reports median output throughput. `task` sends real work and writes token usage into the existing `omarchy.agents` record directory.

## Safety contract

- Only `validated` `docker.openai-v1` recipes run.
- Images require SHA-256 digests and models require immutable revisions.
- CUDA graphs remain enabled; eager mode and graph-disabling arguments are rejected.
- The endpoint binds only to `127.0.0.1`.
- User agent JSON is validated and updated atomically.
- Removing the runtime keeps downloaded weights.
- Registry reads are local and fail closed when the checkout is missing or invalid.

## Verify

```bash
./test/all
```

The whole repository, including tests and docs, is kept below 1,000 lines.
