# Omarchy Local AI

One small Omarchy plugin for local inference. It reads the normalized
[`0xSero/local-ai-registry`](https://github.com/0xSero/local-ai-registry) contract at
`~/omarchy/local-ai/registry`. Its six actions are Scan, Download, Run, Unload,
Open agent, and Switch. Run requires a real completion; failed switches restore
the previous managed model.
The theme-native panel auto-detects local GPUs and lets users choose every
compatible 1, 2, 4, or larger GPU recipe in ascending order. It uses no invented data.
The toolbar popup is a compact status surface. Open its full native panel for hardware inventory, every compatible recipe, downloads, runtime state, and lifecycle controls.
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
- The registry is the only source; only validated, immutable Docker recipes run.
- CUDA graphs stay enabled; eager and graph-disabling flags are rejected.
- Serving binds to `127.0.0.1`; downloads never launch inference.
- Run and switch require a download; OMP and Pi wiring is atomic and reversible.
- A failed switch restores the previous managed container.
Run `./test/all`. The complete repository, tests and docs included, stays under 1,000 lines.
