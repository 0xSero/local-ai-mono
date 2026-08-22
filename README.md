# omarchy-local-ai

Turn a big-GPU machine into its own inference server, and wire it into the
coding agents you already use.

One command reads the GPUs, picks the best model that fits, serves it on
loopback, proves it generates, and gives `pi` and `omp` a `local` provider
pointing at it. A bar panel exposes the same lifecycle to the desktop.

```bash
omarchy ai setup          # probe, serve, wire the agents
omarchy ai list           # what fits this machine, what is serving
omarchy ai stop / start   # free the VRAM for games, get it back
```

## Models

Two, named for what they are to the person choosing. Quantization, engine,
tensor parallelism and context window are recipe internals that can change
without the choice changing.

| Tier | Model | Why | Context on 1× 24 GB |
|---|---|---|---|
| `fast` | Qwen3.6-35B-A3B (GPTQ-INT4) | MoE — only ~3B parameters fire per token, so it decodes quickest | 131,072 |
| `smart` | Qwen3.8-27B (AWQ-INT4) | dense — every parameter works on every token | 40,960 |

The bigger model is the *faster* one: a mixture-of-experts activates a fraction
of its weights per token. Measured on 2× 3090, the 35B ran 136 tok/s against
the dense 27B's ~92.

Both run on a **single 24 GB card** and scale themselves up as you add cards —
tensor parallelism rises and `smart` gains the full 131k window at two GPUs.
The context gap on one card is arithmetic, not preference: dense attention needs
4.16 GiB of KV at 131k where the MoE needs 1.32 GiB.

Both serve on vLLM with FP8 KV cache and identical flag patterns, so the two
recipes differ only in which weights they load. Both carry tool-call and
reasoning parsers — agents get real `tool_calls` JSON and clean content — and
both accept images, so the agent can screenshot your desktop and act on what it
sees.

A single recipe covers 1, 2 and 4 GPUs: a `scale` map keyed by card count is
merged over the base, raising tensor parallelism and context as the hardware
allows.

## Layout

```
lib/        the four modules — hardware, registry, models, engine
bin/        thin CLI wrappers, no logic
share/      the shipped recipe catalog
shell/      the Local AI and Fable bar panels
test/       one suite per module
docs/       architecture
```

`docs/architecture.md` is the map: what each module owns, why the dependencies
point the way they do, and the two or three decisions that are not obvious from
the code.

## Publishing a recipe

Push an `omarchy-recipe.json` to the root of any public repo owned by an account
the catalog lists as a source, then:

```bash
omarchy ai sync
```

Remote recipes override shipped ones that share a name, so a repo can refine
what ships without a release here.

## Tests

```bash
./test/all
```

Every suite runs sandboxed — a temporary `HOME`, a mock docker, hardware
described as JSON — so nothing touches a real machine and the whole thing runs
in a second.

## Requirements

An NVIDIA GPU with 24 GB or more, Docker, `jq`, and `curl`. Setup installs
Docker and the NVIDIA container toolkit if they are missing.
