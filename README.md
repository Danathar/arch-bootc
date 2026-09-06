[![Build container image](https://github.com/Danathar/arch-bootc/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/Danathar/arch-bootc/actions/workflows/build.yml)
[![Nightly compliance](https://github.com/Danathar/arch-bootc/actions/workflows/nightly-compliance.yml/badge.svg?branch=main)](https://github.com/Danathar/arch-bootc/actions/workflows/nightly-compliance.yml)
[![Lint workflows](https://github.com/Danathar/arch-bootc/actions/workflows/zizmor.yaml/badge.svg?branch=main)](https://github.com/Danathar/arch-bootc/actions/workflows/zizmor.yaml)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Danathar/arch-bootc)
[![Maintenance assisted by Hivecommons Hive](https://img.shields.io/badge/maintenance%20assisted%20by-Hivecommons%20Hive-1f6feb)](https://github.com/hivecommons/hive)
[![ACMM L4 Security-Aware](https://img.shields.io/badge/ACMM-L4%20Security--Aware-2da44e)](https://github.com/hivecommons/hive#acmm-levels)
[![AI assisted](https://img.shields.io/badge/AI-assisted-d29922)](#about-this-project)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

# Arch Linux Bootc

Reference [Arch Linux](https://archlinux.org/) container image preconfigured for [bootc](https://github.com/bootc-dev/bootc) usage.

<img width="2335" height="1296" alt="image" src="https://github.com/user-attachments/assets/0a19ad09-fdb6-4b7f-96f0-28ae9df12889" />

<img width="2305" height="846" alt="image" src="https://github.com/user-attachments/assets/f496a2f4-0782-408c-b207-c7acdde2e5ac" />

## Goal

Use this repo as your own bootc image source, build locally, boot it in a VM, create your own user, and later update installed systems with `bootc switch`.

*Unlike a traditional Linux distribution where you install packages on a live system, you manage this system by editing the `Containerfile`, building a new container image, and instructing your host to boot from that image.*

## Quickstart (recommended)

The guided quickstart is the easiest way to install to a VM or bare metal. It
uses either the published image or one you built locally and creates your admin
user through cloud-init, so the system is ready for you to log in on first boot.

```bash
git clone https://github.com/Danathar/arch-bootc.git
cd arch-bootc
just quickstart --dry-run
just quickstart
```

The dry run asks the same questions and performs the same read-only safety
checks, but only prints the commands that would change storage or libvirt. See
[Installation](docs/installation.md) for the enforced guardrails, required
tools, and manual alternatives.

> ⚠️ **Manual installations only:** If you skip the guided quickstart, the
> desktop flavors boot straight to a graphical login that root cannot use.
> Switch to a text console (e.g. Ctrl+Alt+F2), log in as `root` / `changeme`,
> and create your admin user as described in [First Boot](docs/first-boot.md).
> Quickstart seeds that admin user with cloud-init and skips this console step.

## Prerequisites

- Linux host with `podman`, `qemu-img`, `virt-install`, `virsh`, `git`, `just`, `gh`
- A running libvirt setup (`qemu:///session` or `qemu:///system`)
- Optional for image signing: `cosign`

## Documentation

|                                                Doc |                                                                                                                           Covers |
|---------------------------------------------------:|---------------------------------------------------------------------------------------------------------------------------------:|
|           [Customizations](docs/customizations.md) |                          What's preinstalled in this image, and why it works on Arch (upstream bootc/ostree compatibility notes) |
|               [Installation](docs/installation.md) | `just quickstart` (guided VM/bare-metal install), quick start from the published image, building locally, and bare-metal install |
|                 [VM Workflow](docs/vm-workflow.md) |                                                        Creating a local VM and driving it from the host via the QEMU guest agent |
|                   [First Boot](docs/first-boot.md) |                                  Bootstrapping your first admin user — console, guest agent, or cloud-init — plus Homebrew setup |
|                             [CI/CD](docs/ci-cd.md) |                                                                           Enabling GitHub Actions and image signing on your fork |
|                       [Renovate](docs/renovate.md) |                                                                                    How dependency updates are tracked and merged |
|    [Updating & Day-2 Operations](docs/updating.md) |                               `bootc switch`, a known composefs GC issue and its fix, and comparing packages between deployments |
|                 [Quality signals](docs/quality.md) |                                               Every automated check this repo runs, what each one proves, and where the gaps are |
|          [PR review rubric](docs/review-rubric.md) |                                                                What a reviewer checks on a pull request, in the order it matters |
|            [Change risk tiers](docs/risk-tiers.md) |                                                How a change is classified before it is written, and the evidence each tier needs |
| [AI security policy](docs/security/SECURITY-AI.md) |                          What agent-assisted changes defend, which inputs are untrusted, and the invariants that hold regardless |
|                         [Metrics](docs/metrics.md) |                                                PR acceptance, time to merge, and CI health — with the `gh` commands to recompute |
|                   [Reflections](docs/reflections/) |                                  Durable write-ups of what went wrong here, how it was caught, and what would catch it next time |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to run the checks, what not to
change casually, and what a pull request needs to say. [AGENTS.md](AGENTS.md)
is the authoritative policy behind it.

## About this project

> **Note:** This repo was created primarily using directed AI, though its contents have been manually tested and inspected. I believe it's important for anyone using open-source tools on GitHub to have this context before relying on them. Special thanks to the upstream repository [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) for the foundational bootstrapping work.

> [!NOTE]
> **Maintenance on this repository is assisted by [Hivecommons Hive](https://github.com/hivecommons/hive) at ACMM level 4.**
>
> Hive orchestrates a fleet of AI agents that continuously review this codebase and file what they find as issues and pull requests.
>
> At **L4 (Security-Aware)** all agents may file issues, and the quality, security and CI agents may additionally open pull requests that carry a `hold` label. The rest stay advisory: they report, they do not act. Every change is still reviewed and merged by a human maintainer.
>
> Learn more: [Hive](https://github.com/hivecommons/hive) · [Hive Hub](https://hive.kubestellar.io) · [full ACMM policy matrix](https://github.com/hivecommons/hive/blob/v4/src/docs/acmm-policy-matrix.md)
