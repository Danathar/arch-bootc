# Reflections

Durable, dated write-ups of something that went wrong here and what actually
caught it. One file per episode, named `YYYY-MM-DD-short-topic.md`.

This is the third place this repository keeps knowledge, so the first thing it
owes you is a reason to exist rather than to be one of the other two.

| Where | Shape | Lifetime |
| --- | --- | --- |
| [`.memory/corrections.jsonl`](../../.memory/corrections.jsonl) | One line of JSON: an instruction was wrong, here is the correction | Permanent, greppable index |
| [`.claude/session-summary.md`](../../.claude/session-summary.md) | What is in flight *right now* | Volatile; pruned aggressively, entries deleted when the work merges |
| **`docs/reflections/`** | Why a mistake was possible, how it was caught, and what would catch it next time | Permanent, and readable as prose |

The split is about **shape**, not importance. A correction compresses to one
line because the lesson is the line. Some lessons do not: the interesting part
is the *chain* — what looked fine, what the check said, why the check was
wrong — and compressing that to one line throws away the part that transfers.

## What belongs here

- A near-miss: something that passed review, or passed a check, and should not
  have.
- A false result — a test that reported a problem that was not real, or
  reported no problem when there was one.
- A rule that turned out to be load-bearing in a way nobody expected.

## What does not

- **The rule itself.** If a reflection produces a durable rule, that rule goes
  in [`AGENTS.md`](../../AGENTS.md), [`CLAUDE.md`](../../CLAUDE.md), a
  `Containerfile` comment, or a page under [`docs/`](../) — wherever someone
  will be standing when they need it. A reflection is the *evidence and
  reasoning*, and it links to where the rule landed. A rule that lives only
  here has been filed in the wrong place.
- Anything volatile. If it stops being true when the current work merges, it
  belongs in the session summary.
- Prompts, transcripts, credentials, personal data, or host inventory — no VM
  names, pool names, disk paths, or IP addresses. Same risks as
  [`.memory/README.md`](../../.memory/README.md).

  Command output is the one place this differs from `.memory/`, and the
  difference is deliberate rather than an oversight: quoted output is the
  evidence a reflection stands on, and the Standards section below requires it.
  So **sanitised** output — a command, its exit status, a diff, a sequence of
  statuses — is not merely allowed but expected. What stays out is raw or
  unreviewed output, and anything carrying the host-specific detail listed
  above. Read the snippet before pasting it; if it needs redacting, redact it
  rather than dropping the evidence.

## Standards

A reflection is written **after** the thing is settled, not while it is still a
theory. Quote the evidence — the command, the exit status, the diff — because a
reflection without evidence is a story, and stories drift.

If it turns out to be wrong later, correct the file in place and say what
changed. Do not delete it: a lesson that was believed for a while and then
overturned is itself worth knowing about.

## Template

```markdown
# YYYY-MM-DD — <short topic>

**What happened.** The sequence, briefly.

**Why it was possible.** The actual mechanism, not the proximate mistake.

**What caught it.** Name it. If nothing did, say that — a lesson learned from a
near-miss that no check would have caught is the most valuable kind here.

**What changed.** The rule, the check, or the code, with a link.

**What still would not be caught.** The honest limit.
```
