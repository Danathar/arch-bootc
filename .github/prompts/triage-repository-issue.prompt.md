---
description: Triage a repository issue before deciding whether code is needed
---

Triage the referenced issue against the current repository and live GitHub
state. Follow `AGENTS.md` throughout.

1. Run the mandatory preflight and preserve all existing work.
2. Read the full issue, linked discussions, relevant source and documentation,
   and recent history.
3. Search open and merged pull requests, remote branches, and current `main` for
   exact or semantic overlap. Do not duplicate an existing implementation.
4. Separate confirmed defects from stale reports, environment failures,
   documentation gaps, and behavior that still needs runtime proof.
5. Propose the smallest independently reviewable change, its non-goals, and the
   validation that can discriminate the fix from the original behavior.
6. Stop before every external or resource-consuming action that has not been
   explicitly authorized.

End with a concise verdict: no work needed with evidence, blocked with the exact
missing prerequisite, or ready for a focused implementation.
