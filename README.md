# Local AI Mono

One monorepo for discovering local hardware, resolving compatible model artifacts, launching validated inference recipes, and preserving the evidence behind every recommendation.

## Source of truth

[`0xSero/local-ai-registry`](https://github.com/0xSero/local-ai-registry) is the only data authority. This monorepo pins it at [`packages/local-ai-registry`](packages/local-ai-registry) as a Git submodule. [`packages/registry`](packages/registry) contains only the deterministic TypeScript reader over that pinned data; it does not copy records.

```text
packages/local-ai-registry/registry
  index.json
  hardware/<id>.json
  model/<id>.json
  model-instance/<id>.json
  recipe/<id>.json
  speed-sweeps/<id>.json
  benchmark/<id>.json
  benchmark-run/<id>.json
  price/<product-id>/<region>.json
```

Everything else is a consumer or controlled contributor:

```text
packages/
  local-ai-registry/   pinned authoritative data repository
  registry/            TypeScript read and query contract
  api/                 read-only HTTP representation
  sdk/                 typed client and provider integrations
  cli/                 local hardware detection and terminal workflow
  site/                registry browser and project wiki
  omarchy-plugin/      Omarchy-specific UI and lifecycle adapter
  submission-harness/  import, normalization, validation, and review
```

## Start

```bash
git submodule update --init --recursive
pnpm install
pnpm validate
pnpm test
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000). The wiki is at `/docs`, the registry browser is at `/`, and the read-only API is at `/api/v1`.

The published architecture and contribution wiki is available at [0xsero.github.io/local-ai-mono](https://0xsero.github.io/local-ai-mono/).

## Deployment

The `local-ai-registry` Vercel project watches `origin/main` and builds from `packages/site`. The Git repository is the deployment input; generated Vercel state and environment files remain local.

## Growth rule

New data enters through `submission-harness`, passes schema and reference validation, and lands as a reviewable pull request in `local-ai-registry`. The monorepo then advances its submodule pointer. The API, SDK, CLI, site, and Omarchy plugin never mutate registry data. See [`CONTRIBUTING.md`](CONTRIBUTING.md), [`docs/architecture/ownership.md`](docs/architecture/ownership.md), and [`docs/guides/growing-the-registry.md`](docs/guides/growing-the-registry.md).
