# Architecture

Four modules, each with one job, arranged so the dependencies only ever point
one way.

```
   hardware ──┐
              ├──► models ──► engine
   registry ──┘
```

`hardware` and `registry` know nothing about anything else. `models` is the
only place the two meet — it decides *what to serve on this machine*. `engine`
takes that decision and runs it. There are no cycles, so any module can be
tested, replaced, or read on its own.

The CLI in `bin/` holds no logic. Every command is a thin wrapper that sources
`lib/local-ai.sh` and calls into the modules, which is what keeps the four
surfaces (terminal, menu, bar panel, agent) behaving identically.

## hardware

*What accelerators does this machine have?*

The only module that talks to the driver. Everything downstream asks questions
here rather than shelling out to `nvidia-smi`, so adding a second vendor means
teaching this one file.

| Function | Answers |
|---|---|
| `hw_vram_list` | every qualifying card's VRAM in MiB, largest first |
| `hw_vram_json` | the same list as JSON — the contract `models` speaks |
| `hw_gpu_count` / `hw_largest_vram_mb` | how many, and how big is the biggest |
| `hw_gpu_selector` | the `--gpus` argument the container runtime needs |
| `hw_require_gpu` | refuse early and legibly on unsupported hardware |

`OMARCHY_AI_VRAM_MB` replaces the probe outright (tests, dry runs).
`OMARCHY_AI_GPUS` confines both the probe and the container to a subset — the
two must agree, or a model would be sized against cards it cannot use.

## registry

*Where do recipes come from?*

A recipe is pure data describing one run of a serving image. The registry owns
provenance and nothing else: it does not know what a GPU is and never decides
what to serve.

Resolution is layered, so a synced catalog overrides what ships without
editing files in place:

1. `$OMARCHY_AI_CATALOG` — explicit override
2. `~/.local/state/omarchy/local-ai/catalog.json` — written by `registry_sync`
3. `share/local-ai.json` — shipped defaults

`registry_recipes` returns recipes in **serving preference order** — largest
requirement first, alphabetical tie-break — so callers can take the first that
fits and be right. Publishing is pushing one `omarchy-recipe.json` to a repo
root; remote wins on a shared name, which is the upgrade path for pushing a new
quant to every machine without a release here.

## models

*Which model should this machine serve, in what shape, and how do agents see it?*

Where hardware meets registry.

| Function | Answers |
|---|---|
| `model_fits` | does this recipe fit these cards? |
| `model_scale` | what shape does it take on this many cards? |
| `model_autopick` / `model_resolve` | which one do we serve? |
| `model_record` / `model_active` | what is deployed right now? |
| `model_provider_json` / `model_wire_agents` | how do agents reach it? |

Two decisions worth knowing:

**Fit counts qualifying cards, it does not sum VRAM.** A recipe fits when at
least `min_gpus` cards *each* carry `min_vram_mb`. Two 24 GB cards are not one
48 GB card, and pretending otherwise produces recipes that pass the gate and
then fail to load.

**`scale` collapses per-GPU-count variants into one recipe.** The map is keyed
by card count; the largest key the machine reaches is merged over the base
(objects merge, scalars and arrays replace). One `fast` entry covers TP1, TP2
and TP4 instead of three near-identical recipes.

Agent wiring is surgical: the `local` provider is merged in, `defaultProvider`
is claimed only when the agent has none, and `model_unwire_agents` reverses
exactly that and nothing else.

## engine

*Run it.*

Owns the container runtime and the lifecycle. It never decides what to run —
`models` hands it a resolved recipe.

| Function | Does |
|---|---|
| `engine_plan` | build the full docker argv — pure, so `--dry-run` is honest |
| `engine_bootstrap` | install Docker, the daemon, the NVIDIA hook |
| `engine_run` / `start` / `stop` / `logs` | lifecycle |
| `engine_state` | `running` \| `stopped` \| `not-setup` |
| `engine_wait` | poll to readiness, distinguishing crash-loops from loading |
| `engine_verify` | prove the server generates before anything is wired |
| `engine_purge` | reverse setup, keep the expensive image |

There is no daemon. Docker's `--restart unless-stopped` is the supervisor,
which gives reboot persistence with correct stopped-stays-stopped semantics.

Nothing is injected into a recipe's `args`. Generic images own their
entrypoints and guessing flags for them breaks them.

Two guards exist because real hardware taught them: `engine_wait` treats a
container that flickers back to Running as a crash-loop by watching the restart
count, and `engine_verify` insists on a real chat completion because health
endpoints lie — a server can list models and still fail to generate.

## State

One record, `~/.local/state/omarchy/local-ai/recipe.json`, written after a
successful serve. Every surface keys off it: menu guards test its existence,
the bar panel hides without it, `status` exits 2 when it is missing.

It carries `served_name` — the id the server actually answers to — separately
from `name`, the tier the user picked. Clients must send the former; vLLM
rejects unknown model ids outright.

## Testing

One suite per module, each sandboxed into a temporary `HOME` with a mock
docker, so no test touches a real machine:

```bash
./test/all
```

The module boundaries are what make this possible — `models` is tested against
JSON hardware descriptions rather than a GPU, and `engine` is tested by
inspecting the argv it plans rather than by running containers.
