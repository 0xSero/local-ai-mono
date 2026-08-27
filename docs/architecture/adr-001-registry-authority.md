# ADR-001: Registry JSON is the authority

## Status

Accepted.

## Context

The project previously mixed normalized data, a website, API handlers, CLI code, Omarchy-specific integration, and import scripts across repositories. That made ownership unclear and encouraged copied indexes.

## Decision

Use a pnpm monorepo for consumers and integrations. Keep normalized JSON and schemas in the standalone `0xSero/local-ai-registry` repository, pinned as the `packages/local-ai-registry` submodule. Keep the deterministic reader in `packages/registry`, mount API handlers from `packages/api`, consume them through `packages/sdk`, and keep every local or visual integration in its own package. All proposed writes pass through `packages/submission-harness` and land in the authority repository before the submodule pointer advances.

## Consequences

The registry can be used from disk, HTTP, the CLI, or the site without translation. The monorepo cannot silently fork the dataset because its data boundary is a Git link. Deployment must initialize the submodule and include registry JSON in the server trace. Provider credentials and runtime state cannot be committed to the data tree.
