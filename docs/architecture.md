# Architecture

Four small modules keep policy separate from execution.

```text
hardware ──┐
           ├──> models ──> engine
registry ──┘
```

`hardware` is the only module that talks to the NVIDIA driver. It preserves physical GPU indices, ranks eligible cards by free memory, and gives Docker exactly the number of devices declared by a recipe. Multi-device requests carry the literal quoting Docker needs for comma-separated device IDs.

`registry` reads one JSON document. The shipped file, an explicit override, and an atomically synced cache all use the same schema. Validation requires the six alpha recipes while allowing more to be added, immutable image digests, immutable model revisions, matching `min_gpus` and `tensor_parallel_size`, and rejects graph-disabling or eager-mode arguments.

`models` decides whether a concrete recipe fits. It never scales or mutates recipes. It records the successfully deployed recipe and surgically merges a local provider into Pi and OMP, refusing malformed existing JSON instead of overwriting it.

`engine` turns the selected recipe into a Docker argument vector, owns the container lifecycle, waits for readiness, and requires a real non-thinking chat completion before model state or agent configuration is changed.

The QML bar widget calls the plugin checkout's own scripts through `manifest.__sourceDir`. This makes the Git repository installable through `omarchy plugin add` without copying commands into Omarchy itself or relying on a second global installation.

## Data flow

```text
share/registry.json
        |
        v
model_resolve(recipe id) --> hw_gpu_selector(exact TP count)
        |                              |
        +--------------+---------------+
                       v
                 engine_plan
                       |
                       v
              Docker + vLLM endpoint
                       |
             real completion acceptance
                       |
             recipe record + Pi/OMP wiring
```

## State

The active recipe record lives at `~/.local/state/omarchy/local-ai/recipe.json`. A synced registry cache lives beside it as `catalog.json`; forgetting an active model removes only the recipe record, not the last known-good registry.

The server binds to loopback. The provider endpoint is not exposed to the LAN or Tailnet by this plugin.
