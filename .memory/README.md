# Correction capture

This directory is the repository-local place for durable, reviewed corrections
to agent guidance. It is not a transcript store and must never contain prompts,
credentials, personal data, command output, or host inventory.

When a review or validation result proves an instruction wrong or incomplete,
update the authoritative document (`AGENTS.md`, `CLAUDE.md`, or the relevant
page under `docs/`) in the same pull request. Add a short JSON object as one line
to `corrections.jsonl` only when the correction also needs a searchable history:

```json
{"date":"YYYY-MM-DD","area":"short-name","correction":"What changed and why","evidence":"PR or test reference"}
```

Keep entries factual, repository-specific, and safe to publish. A proposed
lesson is not a correction until review or a discriminating test confirms it.
