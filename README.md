# Proxmox VM Disk Expansion

Script: `proxmox_expand_vm_disks.sh`

Run it directly on a Proxmox host as `root`.

## Quick Start

Run on the Proxmox host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh)
```

This uses the defaults:

- up to 4 VM jobs in parallel;
- Proxmox disk target: `119 GiB`;
- Windows disk/`C:` OK threshold: `118 GiB`;
- Windows command timeout: `900` seconds;
- no fixed `+15G`; each VM gets only the missing amount needed to reach the target.

## What It Does

By default the script:

- finds QEMU VMs on the current Proxmox host;
- selects the main boot disk for each VM;
- reads the current Proxmox disk size from `qm config`;
- treats a Proxmox disk as already done when it is at least `119 GiB`;
- checks free space only for VMs that still need a Proxmox disk resize;
- for `lvmthin`, also checks physical free space in the thin pool when resize is needed;
- auto-detects and disables watchdog if found;
- stops running VMs only when a Proxmox disk resize is needed;
- expands the Proxmox disk only when the current disk is below the configured threshold;
- starts the VM when Windows verification/repair is needed;
- waits for QEMU Guest Agent and uses stop/start if an already-running VM has a broken agent;
- first checks Windows `C:` and Steam without changing anything;
- expands Windows `C:` only if the Windows check fails, leaving `1 GiB` unallocated at the end;
- starts Steam only if it is not already running;
- verifies the final Windows disk layout and Steam process before marking a VM successful.

By default there is no fixed disk growth value. For every VM below the Proxmox threshold, the script calculates the exact amount needed to reach `--pve-ok-gb` and runs `qm resize` with that per-VM delta.

For example, with the default `--pve-ok-gb 119`:

- a `104 GiB` disk gets about `+15G`;
- a `113.5 GiB` disk gets about `+5632M`;
- a `119 GiB` or larger disk gets no Proxmox resize at all.

Default success thresholds are:

- Proxmox disk: `>=119 GiB`;
- Windows disk and `C:`: `>=118 GiB`;
- Steam process: running.

## Basic Usage

Run latest script directly from GitHub with `curl`. `chmod` is not needed when running through `bash`.

Production run for all VMs on a host:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh)
```

Use this when the host is overloaded or the Windows guest agents are slow:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh) --parallel 2 --windows-exec-timeout 1800
```

Retry one failed VM exactly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh) --only-vmid 108
```

Dry-run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh) --dry-run
```

This command is safe to rerun for already-expanded VMs: if the Proxmox disk is already at least `119 GiB`, the script skips `qm resize` and only verifies/repairs Windows and Steam.

Force a fixed Proxmox growth instead of auto-sizing:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh) --size +25G
```

Run with lower parallelism on overloaded hosts:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh) --parallel 2 --windows-exec-timeout 1800
```

Apply to one VM:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh) --only-vmid 101
```

If process substitution is not available, use pipe mode:

```bash
curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh | bash -s -- --dry-run
```

Pipe mode apply:

```bash
curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh | bash
```

Download latest version from GitHub and run it on the Proxmox host:

```bash
tmp=/tmp/proxmox-vm-disk-expander && \
rm -rf "$tmp" && \
git clone --depth 1 https://github.com/sinitcad/proxmox-vm-disk-expander.git "$tmp" && \
bash "$tmp/proxmox_expand_vm_disks.sh"
```

Dry-run directly from GitHub:

```bash
tmp=/tmp/proxmox-vm-disk-expander && \
rm -rf "$tmp" && \
git clone --depth 1 https://github.com/sinitcad/proxmox-vm-disk-expander.git "$tmp" && \
bash "$tmp/proxmox_expand_vm_disks.sh" --dry-run
```

If `git` is not installed, fetch only the script:

```bash
curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh \
  -o /tmp/proxmox_expand_vm_disks.sh && \
bash /tmp/proxmox_expand_vm_disks.sh --dry-run
```

Use `chmod +x` only if you want to run the downloaded file directly:

```bash
curl -fsSL https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh \
  -o /tmp/proxmox_expand_vm_disks.sh && \
chmod +x /tmp/proxmox_expand_vm_disks.sh && \
/tmp/proxmox_expand_vm_disks.sh --dry-run
```

Expand/repair all VMs on the host:

```bash
bash proxmox_expand_vm_disks.sh
```

Force all below-threshold VMs to grow by a custom fixed size:

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
bash proxmox_expand_vm_disks.sh --only-vmid 101
```

Several VMs:

```bash
bash proxmox_expand_vm_disks.sh --vmid 100,101,102
```

## Windows Behavior

Windows `C:` expansion is enabled by default.

The script first performs a read-only check inside Windows. If Windows already sees a disk and `C:` of at least `118 GiB` and Steam is running, the VM is marked OK without resizing anything inside Windows.

If that check fails, the script runs the repair step. The repair step removes only a trailing Windows Recovery partition after `C:` on the same disk, then expands `C:` to the maximum possible size minus the reserved tail and starts Steam.

The Windows operation is synchronous: the script waits for the PowerShell command to finish through QEMU Guest Agent and checks the returned `exitcode`. A VM is successful only when `exitcode` is `0` and the final JSON result confirms:

- the guest disk is visible in Windows;
- `C:` was resized or was already at the correct target;
- the requested tail reserve is present within tolerance;
- Steam is running.

Default reserved tail:

```bash
--reserve-tail-gb 1
```

Example with a larger reserved tail:

```bash
bash proxmox_expand_vm_disks.sh --reserve-tail-gb 2
```

Disable Windows `C:` expansion and Steam startup:

```bash
bash proxmox_expand_vm_disks.sh --no-windows-c
```

Change the minimum Windows OK threshold:

```bash
bash proxmox_expand_vm_disks.sh --windows-ok-gb 118
```

Change the Proxmox disk threshold used to skip another `qm resize`:

```bash
bash proxmox_expand_vm_disks.sh --pve-ok-gb 119
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

For slow or heavily loaded hosts, increase the Windows command timeout:

```bash
bash proxmox_expand_vm_disks.sh --windows-exec-timeout 1800
```

The script no longer treats "guest-exec pid was created" as success. If QEMU Guest Agent loses the command, times out, returns a non-zero `exitcode`, or returns no `exitcode` at all, that VM is failed in the final summary.

## Parallelism

VMs are processed in bounded parallel batches. The default is:

```bash
--parallel 4
```

This means up to 4 VM jobs run at the same time.

One VM job includes the whole per-VM pipeline:

- Proxmox size check;
- optional stop;
- optional `qm resize`;
- optional start;
- QEMU Guest Agent wait;
- Windows check;
- Windows repair if needed;
- Steam check/start;
- final verification.

Steps inside one VM are not parallelized. They run in order, because each step depends on the previous check. `--parallel 4` only means four different VMs can be in that pipeline at once. When one VM finishes, the next VM from the host starts.

Use a lower value if the host is storage/CPU constrained or the thin pool is close to full:

```bash
bash proxmox_expand_vm_disks.sh --parallel 2
```

Use a higher value only when the host has enough IO headroom and Guest Agent is stable:

```bash
bash proxmox_expand_vm_disks.sh --parallel 8
```

Every VM streams progress live to stdout with a VM prefix and also writes a per-VM log under `/tmp/proxmox-expand-vm-disks.*`.

## Space Precheck

Before changing anything, the script groups selected VMs by Proxmox storage and checks required space against `pvesm status`.

Only VMs whose current Proxmox disk is below `--pve-ok-gb` are included in the required-space calculation. Each VM contributes only its own calculated delta to reach the target. If all selected VM disks are already above the threshold, the storage precheck reports that no Proxmox resize is needed.

For `lvmthin` storage that will actually be resized, it also reads the backing thin pool through `pvesm config` and `lvs`, then checks physical free space. This catches cases where logical storage looks acceptable but the thin pool is already overcommitted or nearly full.

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
- leaves watchdog disabled after a fully successful resize run;
- prints the exact command to enable it again;
- automatically tries to restore watchdog if the script fails or is interrupted.

Example output:

```text
Watchdog was left disabled. To enable it again, run on this Proxmox host:
  bash /root/proxmox-expand-vm-disks-watchdog/20260709-081500/enable_watchdog.sh
```

Skip automatic watchdog handling:

```bash
bash proxmox_expand_vm_disks.sh --no-watchdog-disable
```

## Final Summary

At the end, the script prints a VM-by-VM summary:

```text
VM result summary:
  OK   vmid=100 name=example step=success log=/tmp/proxmox-expand-vm-disks.../100.log
  FAIL vmid=101 name=example step=windows-repair rc=255 log=/tmp/proxmox-expand-vm-disks.../101.log
       rerun: bash proxmox_expand_vm_disks.sh --only-vmid 101
Summary: total=2 ok=1 fail=1 logs=/tmp/proxmox-expand-vm-disks...
```

The `step` value is the last known stage:

- `stop`
- `pve-resize`
- `start`
- `guest-agent`
- `windows-check`
- `windows-repair`
- `windows-final-check`
- `success`

This makes it clear whether the failure was Proxmox-side, Guest Agent-side, Windows-side, or Steam verification.

If a worker exits before writing its status file, the VM is still listed as `FAIL ... step=no-status` instead of disappearing from the summary.

## Success Criteria And Reruns

A VM is treated as successful only after all requested layers are confirmed:

- Proxmox disk is already at least `--pve-ok-gb`, or the Proxmox resize command completed;
- VM was started when Windows work was requested;
- QEMU Guest Agent became reachable after the configured retries;
- Windows PowerShell command finished with `exitcode: 0`;
- final Windows JSON says `Success=true`, `DiskOk=true`, `COk=true`, and `Steam=true`.

Reruns are expected to be safe:

- Proxmox receives only the calculated missing amount while the current Proxmox disk is below `--pve-ok-gb`;
- `--size` is optional and should be used only when you intentionally want a fixed manual growth instead of auto-sizing to the target;
- Windows `C:` is normalized to use the disk while keeping exactly the configured tail reserve;
- the reserved tail does not accumulate on reruns;
- if `C:` is already at the correct target, Windows reports `Action=already-ok`;
- failed VMs can be rerun individually with `--only-vmid`.

Example retry for one failed VM:

```bash
bash proxmox_expand_vm_disks.sh --only-vmid 108 --parallel 1 --windows-exec-timeout 1800
```

## Practical Failure Cases

These are known real-world failure classes the script now handles or exposes clearly:

- VM stays `stopped` after `qm start`: not a Windows resize problem; inspect Proxmox task logs, VM config, GPU/vGPU assignment, storage, and host errors.
- QEMU Guest Agent answers readiness but dies during Windows command: rerun that VM later, or debug/reinstall Guest Agent inside Windows.
- Windows command is slow under IO pressure: lower `--parallel` and increase `--windows-exec-timeout`.
- Thin pool is physically tight despite logical free space: fix storage capacity/overcommit before running.
- Steam cannot be found or started: VM fails verification because Steam is part of the requested post-resize state.

## Notes

- The script is in apply mode by default.
- Use `--dry-run` before running on a new host.
- VM processing is bounded-parallel after the global storage precheck passes.
- If QEMU Guest Agent does not come up, that VM job fails after the configured retries.
- Re-running is safe for Windows partition sizing: the tail reserve stays around the requested value instead of accumulating.
