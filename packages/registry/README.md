# Registry reader

The deterministic TypeScript read contract over the normalized JSON tree pinned at `../local-ai-registry`. The standalone [`0xSero/local-ai-registry`](https://github.com/0xSero/local-ai-registry) repository is the only data source of truth.

Records are recursive by reference: start at `../local-ai-registry/registry/index.json`, select a compact row, then resolve only its immediate model, artifact, hardware, recipe, price, speed, benchmark, or benchmark-run references. This package exports the same resolver used by the API and site without copying the records.

Do not add user credentials, local cache state, download progress, running containers, or UI preferences here. Those are runtime concerns.

See [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) for the exact record contract and validation path.
