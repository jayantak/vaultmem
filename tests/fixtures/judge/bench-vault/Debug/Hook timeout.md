---
description: A SessionStart hook that timed out and blocked the session.
---
# Hook timeout

The hook ran a full vault scan on every start and hit the 10 s limit.
Fix: make the hook fail-quiet and cap the scan.
