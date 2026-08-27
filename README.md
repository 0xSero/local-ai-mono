# Omarchy Local AI

One small Omarchy plugin for local inference. It reads the public
[`0xSero/local-ai-registry`](https://github.com/0xSero/local-ai-registry) checkout at
`~/omarchy/local-ai` and presents six actions:

1. **Scan** — refresh the registry and match recipes to this computer.
2. **Download** — fetch one exact model revision without starting a server.
3. **Run** — load one downloaded model and require a real completion.
4. **Unload** — free the hardware but keep the download.
5. **Open agent** — open Omarchy's own agent picker with the local model wired in.
6. **Switch** — replace the running model; restore it if the new model fails.

The panel is deliberately quiet: text only, one level at a time, and no custom
colors, icons, cards, hardware dashboard, or invented catalog data.

## Install

```bash
omarchy plugin add https://github.com/0xSero/omarchy-local-ai.git --yes
omarchy plugin enable sero.local-ai
```

## CLI

```bash
./bin/omarchy-local-ai scan
./bin/omarchy-local-ai download <model-or-recipe>
./bin/omarchy-local-ai run <model-or-recipe>
./bin/omarchy-local-ai unload
./bin/omarchy-local-ai open-agent
./bin/omarchy-local-ai switch <model-or-recipe>
```

`status`, `snapshot`, `downloads`, `task`, and `benchmark` remain available for
diagnosis and measured acceptance. They are not extra UI features.

## Boundaries

- The registry is the only source of models and launch recipes.
- Only validated, immutable Docker recipes are accepted.
- CUDA graphs stay enabled; eager or graph-disabling flags are rejected.
- Serving binds to `127.0.0.1` only.
- Downloads do not launch an inference server.
- Run and switch require the download first.
- OMP and Pi agent settings are written atomically and removed on unload.
- A failed switch restores the previous managed container.

Run `./test/all`. The complete repository, including tests and docs, stays under
1,000 lines.
