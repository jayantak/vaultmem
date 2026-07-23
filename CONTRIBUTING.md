# Contributing

vaultmem is a single bash script by design (see README § Why bash). Read it
top to bottom before a non-trivial change — that's the point of it being one
file.

## Before you open a PR

```bash
bats tests/vaultmem.bats            # CLI behavior
./tests/subcommand-lint.sh          # every subcommand skills/**/*.md references must exist
shellcheck vaultmem install.sh tests/subcommand-lint.sh
shfmt --diff vaultmem install.sh tests/subcommand-lint.sh   # must be empty; `shfmt -w` to fix
```

These four are exactly what CI runs (`.github/workflows/ci.yml`:
`lint` / `test` / `subcommand-lint`).

Tests never touch a real vault — see AGENTS.md § Build/test/validate for the
isolated-fixture pattern (`VAULTMEM_CONFIG` pointed at a `bats` tempdir); new
tests must follow it.

## What kind of PR fits

vaultmem's whole bet is no daemon, no database, no vector index, no build
step. A PR that reintroduces any of those (a persistent process, an
embeddings layer, a compiled rewrite) is very likely a "no" regardless of
execution quality — open an issue first to discuss before investing time.
Bug fixes, new `vaultmem` subcommands that stay in the bash+ripgrep model,
docs, and test coverage are all welcome.

## Where things live

- CLI surface: `vaultmem` (dispatch table at the bottom, `case
  "${ARGS[0]:-}" in`)
- Vault schema/frontmatter contract: `SCHEMA.md`
- Config/registry contract: `docs/config.md`
- Agent skills (generated payload synced from a private source — see
  AGENTS.md § Non-obvious gotchas): `skills/`
