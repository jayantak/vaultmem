# Security Policy

vaultmem is a bash script that reads and writes files inside a local Obsidian
vault you point it at. It makes no network calls and handles no secrets or
auth. The realistic attack surface is the config TOML parser (`_parse_config`)
and `groom`'s file moves inside your vault — see AGENTS.md § The
config/registry model for why `doctor` hard-errors on malformed config rather
than guessing.

**Report a vulnerability**: use GitHub's [private vulnerability
reporting](https://github.com/jayantak/vaultmem/security/advisories/new) for
this repo (Security tab → "Report a vulnerability"). Do not open a public
issue for a security report.

Best-effort response, no SLA. Supported version: latest tag only — this
project is 0.x (see [Semantic Versioning](https://semver.org/spec/v2.0.0.html#spec-item-4)).

<!-- TODO(human): add a direct contact (email/handle) here if you want an
     alternative to the GitHub private-advisory form. -->
