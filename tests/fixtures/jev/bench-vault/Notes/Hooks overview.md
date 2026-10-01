# Hooks overview

SessionStart and Stop hooks run vaultmem status, sessions, and nudge.
Every hook is fail-quiet: a missing vault prints nothing and exits 0.
Timeouts: keep each hook under a second.
