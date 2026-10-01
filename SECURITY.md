# Security Policy

## Reporting a vulnerability

Please report security vulnerabilities privately through GitHub's
[Security Advisories](https://github.com/Danathar/arch-bootc/security/advisories/new)
feature ("Report a vulnerability" on the repository's Security tab), rather
than opening a public issue. This lets maintainers confirm and fix the problem
before details are public.

Include, where relevant:

- the affected commit, tag, or published image digest
- steps to reproduce, or a minimal example
- the impact you believe the issue has

## Scope

This covers the image build (`Containerfile`, packaging, signing) and the
repository's CI/CD pipeline. For the AI-agent-specific security gate — what it
defends against and which inputs it treats as untrusted — see
[`docs/security/SECURITY-AI.md`](docs/security/SECURITY-AI.md); that document
is about agent-assisted changes, not vulnerability reporting.
