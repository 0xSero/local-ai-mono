# Omarchy Local AI

An installable Omarchy bar plugin for running two pinned local models on one, two, or four RTX 3090 GPUs.

The alpha contract is intentionally literal: one JSON recipe equals one tensor-parallel topology. There is no hidden scaling step and no runtime guessing.

| Recipe | Model | GPUs | Context |
|---|---|---:|---:|
| `qwen36-tp1` | Qwen3.6-35B-A3B GPTQ INT4 | 1 | 131,072 |
| `qwen36-tp2` | Qwen3.6-35B-A3B GPTQ INT4 | 2 | 131,072 |
| `qwen36-tp4` | Qwen3.6-35B-A3B GPTQ INT4 | 4 | 131,072 |
| `qwen38-tp1` | Qwen3.8-27B AWQ INT4 | 1 | 40,960 |
| `qwen38-tp2` | Qwen3.8-27B AWQ INT4 | 2 | 131,072 |
| `qwen38-tp4` | Qwen3.8-27B AWQ INT4 | 4 | 131,072 |

Every recipe pins the serving image by digest and the Hugging Face model revision by commit. CUDA graphs stay enabled and eager mode is never forced.

## Install the private alpha

```bash
omarchy plugin add git@github.com:0xSero/omarchy-local-ai.git
omarchy plugin enable sero.local-ai
```

The bar widget invokes the checkout's own scripts through the source directory Omarchy injects into the plugin manifest. It does not depend on globally installed `omarchy-ai-*` commands.

Open the Local AI widget and choose one of the six recipes. Setup installs Docker and the NVIDIA container toolkit when needed, launches exactly the recipe's GPU count, proves a real chat completion, then wires the local OpenAI-compatible provider into Pi and OMP.

Ori is visible in Omarchy as an agent, but its current CLI does not accept this direct local OpenAI-compatible provider. The plugin does not pretend otherwise: Pi and OMP are wired today; Ori needs upstream custom-provider support before it can be pointed at this endpoint.

## Registry

[`share/registry.json`](share/registry.json) is an independent, pure-data registry. Add or change recipes there without changing the engine, model selection, or UI code.

To consume a separately hosted registry, point sync at one exact JSON document:

```bash
OMARCHY_AI_REGISTRY_URL=https://example.com/registry.json ./bin/omarchy-ai-sync
```

Sync downloads into a temporary file, validates the six required alpha recipes plus any additional pinned recipes, and atomically replaces the cached catalog. A failed download or invalid registry leaves the last good catalog untouched. Account-wide GitHub repository scanning is deliberately not part of the design.

## Code map

```text
manifest.json   third-party Omarchy plugin contract
shell/          one self-contained bar widget
share/          pinned six-recipe registry
lib/            hardware, registry, model, and engine modules
bin/            thin plugin-local commands
test/           sandboxed module and plugin tests
docs/           architecture and live RTX 3090 acceptance evidence
```

## Validate

```bash
./test/all
omarchy plugin validate .
```

Live results and the acceptance method are in [`docs/acceptance-3090.md`](docs/acceptance-3090.md).
