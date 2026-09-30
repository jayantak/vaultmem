---
description: When to stream per item instead of batching.
---
# Streaming patterns

Stream per item when the item count is unbounded.
Batch only when every item fits in memory with room to spare.
The athlete rebuild OOM is the worked example.
