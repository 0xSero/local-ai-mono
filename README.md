# Omarchy Local AI

One small Omarchy plugin for local inference. It reads the normalized
[`0xSero/local-ai-registry`](https://github.com/0xSero/local-ai-registry) contract at
`~/omarchy/local-ai/registry`. Its six actions are Scan, Download, Run, Unload,
Open agent, and Switch. Run requires a real completion; failed switches restore
the previous managed model.

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

Diagnostic commands remain available for measured acceptance, not as extra UI.

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
