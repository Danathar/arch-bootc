# VM Workflow

Prerequisite: a qcow2 disk image, from either
[Path A](installation.md#path-a-quick-start-pre-built-image) or
[Path B](installation.md#path-b-customizing--building-locally) of
[Installation](installation.md).

## Create VM (User Session Track)

This is the track used here: `qemu:///session`, 8GB RAM, 10 vCPU, UEFI, Secure Boot disabled.

```bash
virt-install \
  --connect qemu:///session \
  --name arch-bootc-local \
  --memory 8192 \
  --vcpus 10 \
  --cpu host-passthrough \
  --import \
  --disk path=/absolute/path/to/arch-bootc/output/arch-bootc-100g.qcow2,format=qcow2,bus=virtio \
  --network user,model=virtio \
  --graphics spice \
  --video virtio \
  --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no,firmware.feature1.name=enrolled-keys,firmware.feature1.enabled=no \
  --osinfo linux2024 \
  --noautoconsole
```
*(Notes: `secure-boot=off` avoids UEFI boot issues with unsigned custom images. For system libvirt (`qemu:///system`), use `--network network=default,model=virtio` instead.)*

To recreate VM (Delete + Recreate):
```bash
virsh -c qemu:///session destroy arch-bootc-local || true
virsh -c qemu:///session undefine arch-bootc-local --nvram || true
```
Then run the `virt-install` command again.

## Running commands in the VM from the host (QEMU guest agent)

The image installs `qemu-guest-agent`, and `virt-install` attaches the
`org.qemu.guest_agent.0` channel by default for Linux guests. The agent is
started automatically by its udev rule once the VM boots, so you can run
commands inside the VM from the host without SSH or a console login:

```bash
# Verify the agent is connected
virsh -c qemu:///session qemu-agent-command arch-bootc-local '{"execute":"guest-ping"}'

# Run a command in the guest (returns a PID), then read its output
virsh -c qemu:///session qemu-agent-command arch-bootc-local \
  '{"execute":"guest-exec","arguments":{"path":"/usr/bin/bootc","arg":["status"],"capture-output":true}}'
virsh -c qemu:///session qemu-agent-command arch-bootc-local \
  '{"execute":"guest-exec-status","arguments":{"pid":<PID>}}'
```

(`out-data` in the result is base64-encoded.) Usermode networking (`--network
user`) has no inbound route for SSH, so the guest agent is the simplest way to
drive the VM from the host — including bootstrapping your first admin user,
since `guest-exec` runs as `root`:

```bash
# Create the user
virsh -c qemu:///session qemu-agent-command arch-bootc-local \
  '{"execute":"guest-exec","arguments":{"path":"/usr/sbin/useradd","arg":["-m","-u","1000","-G","wheel","<username>"],"capture-output":true}}'

# Set its password (input-data is base64 of "<username>:<password>\n")
virsh -c qemu:///session qemu-agent-command arch-bootc-local \
  '{"execute":"guest-exec","arguments":{"path":"/usr/sbin/chpasswd","arg":[],"capture-output":true,"input-data":"PHVzZXJuYW1lPjo8cGFzc3dvcmQ+Cg=="}}'
```

Check each command's `guest-exec-status` (as above) to confirm `"exitcode":0`.
Log in as `<username>` from here on — `sudo` already works via `wheel`.

See [First Boot](first-boot.md) for the fuller picture of first-login options
(console, guest agent, cloud-init) and post-login setup (Homebrew, etc.).
