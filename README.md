# Arch Linux Bootc

[![build](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml/badge.svg)](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml)

> **Note:** This repo was created primarily using directed AI, though its contents have been manually tested and inspected. I believe it's important for anyone using open-source tools on GitHub to have this context before relying on them. Special thanks to the upstream repository [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) for the foundational bootstrapping work.

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

|                                             Doc |                                                                                                                           Covers |
|------------------------------------------------:|---------------------------------------------------------------------------------------------------------------------------------:|
|        [Customizations](docs/customizations.md) |                          What's preinstalled in this image, and why it works on Arch (upstream bootc/ostree compatibility notes) |
|            [Installation](docs/installation.md) | `just quickstart` (guided VM/bare-metal install), quick start from the published image, building locally, and bare-metal install |
|              [VM Workflow](docs/vm-workflow.md) |                                                        Creating a local VM and driving it from the host via the QEMU guest agent |
|                [First Boot](docs/first-boot.md) |                                  Bootstrapping your first admin user — console, guest agent, or cloud-init — plus Homebrew setup |
|                          [CI/CD](docs/ci-cd.md) |                                                                           Enabling GitHub Actions and image signing on your fork |
|                    [Renovate](docs/renovate.md) |                                                                                    How dependency updates are tracked and merged |
| [Updating & Day-2 Operations](docs/updating.md) |                               `bootc switch`, a known composefs GC issue and its fix, and comparing packages between deployments |
