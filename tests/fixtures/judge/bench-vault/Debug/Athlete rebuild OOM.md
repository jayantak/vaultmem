---
type: debug
description: "Root cause of the nightly athlete rebuild running out of memory."
updated: 2026-09-01
---
# Athlete rebuild OOM

The nightly rebuild held every team profile in memory at once.
Fix: stream per team instead of loading the whole league.
Peak RSS dropped from 6 GB to 400 MB.
