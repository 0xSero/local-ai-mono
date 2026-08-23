# RTX 3090 alpha acceptance

Validated on 2026-08-23 on an Omarchy workstation with four 24 GB RTX 3090 GPUs, PCIe-only tensor-parallel communication, a 175 W power limit, and one display-attached GPU using roughly 566 MiB before inference.

The runtime baseline is `vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967`. CUDA graph logs reported `FULL_AND_PIECEWISE`, and runtime configuration reported `enforce_eager=False`.

## Throughput

Each concurrency-1 result is the median of three 256-output-token semantic completions after startup. Concurrency 4 is aggregate output throughput across four simultaneous copies of the same request. Every response had to begin with `SEMANTIC_OK`; `max_completion_tokens` was used and thinking was explicitly disabled for timing comparability.

| Recipe | c1 median tok/s | c4 aggregate tok/s | Result |
|---|---:|---:|---|
| `qwen36-tp1` | 137.3 | 216.2 | pass |
| `qwen36-tp2` | 169.5 | 460.4 | pass |
| `qwen36-tp4` | 177.5 | 506.9 | pass |
| `qwen38-tp1` | 16.0 | 30.9 | pass |
| `qwen38-tp2` | 29.3 | 111.2 | pass |
| `qwen38-tp4` | 63.6 | 214.9 | pass |

## Capability acceptance

Both model families passed these checks on TP4:

- Non-empty parsed reasoning content.
- Structured automatic tool call with the expected function name and JSON arguments.
- Image input through an OpenAI-compatible data URL with a non-empty grounded response.
- A normal content completion with thinking disabled.

## Constraint discovered on the live desktop

The original TP4 setting of `--gpu-memory-utilization 0.97` failed before model load because the display-attached GPU had less free VRAM than the requested reservation. The TP4 recipes use `0.94`; they then loaded, captured CUDA graphs, and passed semantic and capability acceptance. TP1 and TP2 retain `0.97` because the selector chooses the cards with the most free memory.

## Performance interpretation

These are measured alpha baselines, not generalized cross-engine claims. The pinned Qwen3.8 SGLang/DSpark image was also tested at TP4, where it keeps full prefill and decode CUDA graphs enabled. It reached 64.8 tok/s median at concurrency 1 and 149.6 tok/s aggregate at concurrency 4, versus vLLM's 63.6 and 214.9. Its first full graph capture was also substantially slower, so the alpha keeps vLLM for TP4. The SGLang TP1 and TP2 presets remain ineligible because their current entrypoint disables prefill CUDA graphs.
