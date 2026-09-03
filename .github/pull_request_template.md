## What changed

<!-- Describe the behavior change and why it is needed. -->

## Scope and risk

<!-- Name affected flavors and installed-system, boot, upgrade, signing, or storage impact. -->

- [ ] This does not weaken the root-login safeguards or image signature policy.
- [ ] `Containerfile` rationale comments remain accurate.
- [ ] No unrelated or pre-existing work is included.

## Validation

<!-- List exact commands and outcomes. Distinguish static checks, builds, and VM boots. -->

- [ ] `git diff --check`
- [ ] Relevant shell/workflow tests and linters
- [ ] Every affected flavor was validated, or the missing evidence is stated below

Skipped or inconclusive checks:

## External state

<!-- List pushed images/tags, workflow mutations, VMs, pools, loop devices, or work directories. Write "None" when applicable. -->
