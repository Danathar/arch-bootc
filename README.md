# Arch Linux Bootc

[![build](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml/badge.svg)](https://github.com/Danathar/arch-bootc/actions/workflows/build.yaml)

> **Note:** This repo was created primarily using directed AI, though its contents have been manually tested and inspected. I believe it's important for anyone using open-source tools on GitHub to have this context before relying on them. Special thanks to the upstream repository [bootcrew/arch-bootc](https://github.com/bootcrew/arch-bootc) for the foundational bootstrapping work.

Reference [Arch Linux](https://archlinux.org/) container image preconfigured for [bootc](https://github.com/bootc-dev/bootc) usage.

<img width="2335" height="1296" alt="image" src="https://github.com/user-attachments/assets/0a19ad09-fdb6-4b7f-96f0-28ae9df12889" />

<img width="2305" height="846" alt="image" src="https://github.com/user-attachments/assets/f496a2f4-0782-408c-b207-c7acdde2e5ac" />

## Goal

Use this repo as your own bootc image source, build locally, boot it in a VM, create your own user, and later update installed systems with `bootc switch`.

*Unlike a traditional Linux distribution where you install packages on a live system, you manage this system by editing the `Containerfile`, building a new container image, and instructing your host to boot from that image.*

> ⚠️ **First boot:** The desktop flavors boot straight to a graphical login,
> which root cannot use. Switch to a text console (e.g. Ctrl+Alt+F2) and log
> in as `root` / `changeme` — you'll be forced to set a new password
> immediately. From there, create your own admin user and give it `sudo` via
> the `wheel` group — see [First Boot](docs/first-boot.md).

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

Start with [Installation](docs/installation.md) — or jump straight in with
`just quickstart`, which walks you through a VM or bare-metal install and
creates your admin user via cloud-init so there's no first-boot console step.
Add `--dry-run` to print mutating commands without executing them; read-only
host validation still runs so collision and disk-safety checks remain real.
