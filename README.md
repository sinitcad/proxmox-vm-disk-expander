# Proxmox VM Disk Expansion

Script: `proxmox_expand_vm_disks.sh`

Run it directly on a Proxmox host as `root`.

## What It Does

By default the script:

- finds QEMU VMs on the current Proxmox host;
- selects the main boot disk for each VM;
- checks that the target Proxmox storage has enough free space;
- auto-detects and disables watchdog if found;
- stops running VMs;
- expands the Proxmox disk;
- starts the VM;
- waits for QEMU Guest Agent;
- expands Windows `C:` while leaving `1 GiB` unallocated at the end;
- starts Steam if it is not already running.

Default disk growth is `+15G`.

## Basic Usage

Expand all VMs on the host by `+15G`:

```bash
bash proxmox_expand_vm_disks.sh
```

Expand all VMs by a custom size:

```bash
bash proxmox_expand_vm_disks.sh --size +25G
```

Preview without changes:

```bash
bash proxmox_expand_vm_disks.sh --dry-run
```

## Target Specific VMs

One VM:

```bash
bash proxmox_expand_vm_disks.sh --only-vmid 101 --size +25G
```

Several VMs:

```bash
bash proxmox_expand_vm_disks.sh --vmid 100,101,102 --size +25G
```

## Windows Behavior

Windows `C:` expansion is enabled by default.

The script removes only a trailing Windows Recovery partition after `C:` on the same disk, then expands `C:` to the maximum possible size minus the reserved tail.

Default reserved tail:

```bash
--reserve-tail-gb 1
```

Example with a larger reserved tail:

```bash
bash proxmox_expand_vm_disks.sh --size +25G --reserve-tail-gb 2
```

Disable Windows `C:` expansion and Steam startup:

```bash
bash proxmox_expand_vm_disks.sh --size +25G --no-windows-c
```

## Guest Agent Waiting

After VM start, the script waits before trying QEMU Guest Agent:

- 4 attempts by default;
- 120 seconds between attempts;
- first attempt is also after 120 seconds.

Override if needed:

```bash
bash proxmox_expand_vm_disks.sh --guest-retry-attempts 6 --guest-retry-delay 120
```

## Space Precheck

Before changing anything, the script groups selected VMs by Proxmox storage and checks required space against `pvesm status`.

Example dry-run output:

```text
Storage precheck:
  storage=nvme0-thin: required=105.00G available=340.96G
  storage=nvme1-thin: required=105.00G available=248.91G
```

Skip the precheck only if you explicitly need to:

```bash
bash proxmox_expand_vm_disks.sh --skip-space-check
```

## Watchdog

In apply mode the script automatically tries to find and disable watchdog before VM stop/start operations.

It detects watchdog by:

- root crontab entries containing `watchdog` or `monitor_vms.sh`;
- watchdog scripts under common locations such as `/root`, `/opt`, `/usr/local`, and `/home`;
- currently running watchdog-like processes.

When found, the script:

- saves the original crontab;
- removes watchdog cron entries;
- creates marker files named `watchdog.disabled`;
- kills the currently running watchdog process;
- leaves watchdog disabled after the resize run;
- prints the exact command to enable it again.

Example output:

```text
Watchdog was left disabled. To enable it again, run on this Proxmox host:
  bash /root/proxmox-expand-vm-disks-watchdog/20260709-081500/enable_watchdog.sh
```

Skip automatic watchdog handling:

```bash
bash proxmox_expand_vm_disks.sh --no-watchdog-disable
```

## Notes

- The script is in apply mode by default.
- Use `--dry-run` before running on a new host.
- VM processing is parallel after the global storage precheck passes.
- If QEMU Guest Agent does not come up, that VM job fails after the configured retries.
- Re-running is safe for Windows partition sizing: the tail reserve stays around the requested value instead of accumulating.
