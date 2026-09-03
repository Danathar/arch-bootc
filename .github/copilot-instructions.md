# Repository instructions

Read and follow `AGENTS.md` before proposing or changing anything. It is the
authoritative repository-wide policy, including consent gates, image and VM
safety, security invariants, validation requirements, and completion reporting.

Keep changes narrowly scoped. In particular:

- Preserve the explanatory comments in `Containerfile`; they record tested
  constraints and rejected alternatives.
- Never weaken the default-root-password safeguards, container signature
  policy, daily pacman cache bust, or systemd enablement layout.
- Treat every existing container, image, VM, pool, block device, generated file,
  and untracked file as user data.
- Do not run `just lint`, a local image build, or VM testing without the
  authorization required by `AGENTS.md`.
- Run non-privileged checks relevant to the changed files and report exactly
  what was and was not verified.
