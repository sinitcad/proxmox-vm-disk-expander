#!/usr/bin/env bash
set -euo pipefail

increment="+15G"
apply=1
include_templates=0
vm_filter=""
skip_space_check=0
auto_disable_watchdog=1
stop_timeout=300
start_timeout=300
guest_retry_attempts=4
guest_retry_delay=120
expand_windows_c=1
reserve_tail_gb=1
log_dir=""
watchdog_restore_command=""

usage() {
  cat <<'EOF'
Usage:
  proxmox_expand_vm_disks.sh [--dry-run] [--size +15G] [--include-templates] [--vmid 100,101]
                              [--only-vmid 101]
                              [--no-windows-c] [--reserve-tail-gb 1] [--skip-space-check]
                              [--no-watchdog-disable]

Expands one main QEMU disk per VM on the current Proxmox host.

Default mode is apply. Use --dry-run to preview without changes.

Apply mode runs VMs in parallel:
  - Build a full plan for selected VMs before changing anything
  - Check free space on each Proxmox storage used by selected VM disks
  - Auto-detect and disable watchdog cron/processes, leaving watchdog disabled
  - Detect VM state
  - If running, qm stop and wait until the VM is really stopped
  - qm resize selected disk by the requested increment
  - If it was running before, qm start and wait until it is running again
  - Expand C: inside Windows via QEMU guest agent and then start Steam if it is
    not already running

VMs that were already stopped are resized while stopped and then started so the
Windows partition can be expanded through guest agent and Steam can be started.

Disk selection:
  1. First boot disk from "boot: order=..." if it is a real disk
  2. Otherwise first real disk in controller order: scsi, virtio, sata, ide

Skipped disk-like entries:
  cdrom, cloudinit, efidisk, tpmstate, unused disks

Windows C: expansion, enabled by default:
  - Requires QEMU guest agent in the Windows VM
  - Removes only Recovery partitions after C: on the same disk
  - Expands C: to maximum size minus --reserve-tail-gb
  - Starts Steam after successful C: expansion if steam.exe is found
  - Waits for guest agent after VM start with 4 attempts, sleeping 2 minutes
    before each attempt
  - Re-running is safe: after each disk growth it normalizes the tail reserve,
    so a 1 GiB reserve stays 1 GiB instead of accumulating every run

Examples:
  ./proxmox_expand_vm_disks.sh
  ./proxmox_expand_vm_disks.sh --dry-run
  ./proxmox_expand_vm_disks.sh --size +20G
  ./proxmox_expand_vm_disks.sh --only-vmid 101
  ./proxmox_expand_vm_disks.sh --vmid 101
  ./proxmox_expand_vm_disks.sh --vmid 100,101
  ./proxmox_expand_vm_disks.sh --no-windows-c
EOF
}

vm_status() {
  local vmid="$1"
  qm status "$vmid" | awk -F': ' '/^status:/ {print $2; exit}'
}

wait_for_status() {
  local vmid="$1"
  local wanted="$2"
  local timeout="$3"
  local waited=0
  local status=""

  while (( waited < timeout )); do
    status="$(vm_status "$vmid" || true)"
    if [[ "$status" == "$wanted" ]]; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done

  printf 'timeout waiting for vmid=%s status=%s, current=%s\n' "$vmid" "$wanted" "${status:-unknown}" >&2
  return 1
}

wait_for_guest_agent_after_start() {
  local vmid="$1"
  local attempts="$2"
  local delay="$3"
  local attempt

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    log "VM vmid=${vmid}: sleeping ${delay}s before guest agent attempt ${attempt}/${attempts}"
    sleep "$delay"
    if qm guest exec "$vmid" -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Output ready" >/dev/null 2>&1; then
      log "VM vmid=${vmid}: guest agent is ready on attempt ${attempt}/${attempts}"
      return 0
    fi
    log "VM vmid=${vmid}: guest agent attempt ${attempt}/${attempts} failed"
  done

  printf 'timeout waiting for vmid=%s guest agent after %s attempts\n' "$vmid" "$attempts" >&2
  return 1
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

print_watchdog_restore_command() {
  if [[ -n "$watchdog_restore_command" ]]; then
    printf '\nWatchdog was left disabled. To enable it again, run on this Proxmox host:\n'
    printf '  %s\n\n' "$watchdog_restore_command"
  fi
}

trap print_watchdog_restore_command EXIT

is_watchdog_cron_line() {
  local line="$1"
  [[ "$line" =~ ^[[:space:]]*$ ]] && return 1
  [[ "$line" =~ ^[[:space:]]*# ]] && return 1
  [[ "${line,,}" =~ (watchdog|monitor_vms).*\.sh|monitor_vms\.sh ]]
}

extract_watchdog_paths() {
  local cron_lines="$1"

  {
    printf '%s\n' "$cron_lines" |
      grep -Eo '/[^[:space:];|&"'"'"']*(monitor_vms|watchdog)[^[:space:];|&"'"'"']*\.sh' || true
    find /root /opt /usr/local /home -maxdepth 5 \
      \( -path '/root/proxmox-expand-vm-disks-watchdog' -o -path '/root/proxmox-expand-vm-disks-watchdog/*' \) -prune -o \
      -type f \( -name 'monitor_vms.sh' -o -iname '*watchdog*.sh' \) -print 2>/dev/null || true
  } | sort -u
}

disable_watchdog_if_found() {
  local base_dir="/root/proxmox-expand-vm-disks-watchdog"
  local run_dir="$base_dir/$(date +%Y%m%d-%H%M%S)"
  local current_cron watchdog_lines watchdog_paths path dir marker
  local found=0

  current_cron="$(crontab -l 2>/dev/null || true)"
  watchdog_lines="$(
    while IFS= read -r line; do
      if is_watchdog_cron_line "$line"; then
        printf '%s\n' "$line"
      fi
    done <<< "$current_cron"
  )"
  watchdog_paths="$(extract_watchdog_paths "$watchdog_lines")"

  if [[ -n "$watchdog_lines" || -n "$watchdog_paths" ]]; then
    found=1
  elif pgrep -af 'monitor_vms\.sh|watchdog.*/.*\.sh' >/dev/null 2>&1; then
    found=1
  fi

  if [[ "$found" -eq 0 ]]; then
    log "Watchdog auto-disable: no watchdog cron/process/script found"
    return 0
  fi

  mkdir -p "$run_dir"
  printf '%s\n' "$current_cron" > "$run_dir/crontab.before"
  : > "$run_dir/disabled_cron_lines"
  : > "$run_dir/watchdog_paths"
  [[ -n "$watchdog_lines" ]] && printf '%s\n' "$watchdog_lines" > "$run_dir/disabled_cron_lines"
  [[ -n "$watchdog_paths" ]] && printf '%s\n' "$watchdog_paths" > "$run_dir/watchdog_paths"

  if [[ -n "$watchdog_lines" ]]; then
    while IFS= read -r line; do
      if ! is_watchdog_cron_line "$line"; then
        printf '%s\n' "$line"
      fi
    done <<< "$current_cron" | crontab -
    log "Watchdog auto-disable: removed watchdog cron entries"
  fi

  : > "$run_dir/marker_files"
  marker="$base_dir/watchdog.disabled"
  touch "$marker"
  printf '%s\n' "$marker" >> "$run_dir/marker_files"

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    dir="$(dirname "$path")"
    if [[ -d "$dir" && -w "$dir" ]]; then
      marker="$dir/watchdog.disabled"
      touch "$marker" 2>/dev/null || true
      [[ -f "$marker" ]] && printf '%s\n' "$marker" >> "$run_dir/marker_files"
    fi
  done <<< "$watchdog_paths"
  sort -u "$run_dir/marker_files" -o "$run_dir/marker_files"

  pkill -f 'monitor_vms\.sh|watchdog.*/.*\.sh' 2>/dev/null || true

  cat > "$run_dir/enable_watchdog.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

state_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
disabled="$state_dir/disabled_cron_lines"
markers="$state_dir/marker_files"
tmp="$(mktemp)"

if [[ -s "$disabled" ]]; then
  crontab -l 2>/dev/null | grep -vxF -f "$disabled" > "$tmp" || true
  cat "$disabled" >> "$tmp"
  crontab "$tmp"
else
  crontab -l >/dev/null 2>&1 || true
fi
rm -f "$tmp"

if [[ -s "$markers" ]]; then
  while IFS= read -r marker; do
    [[ -n "$marker" ]] && rm -f "$marker"
  done < "$markers"
fi

echo "watchdog enable command completed from $state_dir"
crontab -l 2>/dev/null | grep -Ei 'watchdog|monitor_vms' || true
EOS
  chmod +x "$run_dir/enable_watchdog.sh"
  ln -sfn "$run_dir" "$base_dir/latest"

  watchdog_restore_command="bash $run_dir/enable_watchdog.sh"
  log "Watchdog auto-disable: disabled and left disabled"
  log "Watchdog auto-disable: restore command will be printed at exit"
}

increment_to_kib() {
  local size="$1"
  local value unit

  [[ "$size" =~ ^\+([0-9]+)([KMGTP]?)$ ]] || return 1
  value="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"

  case "$unit" in
    K) printf '%s\n' "$value" ;;
    M) printf '%s\n' $((value * 1024)) ;;
    ""|G) printf '%s\n' $((value * 1024 * 1024)) ;;
    T) printf '%s\n' $((value * 1024 * 1024 * 1024)) ;;
    P) printf '%s\n' $((value * 1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
}

kib_to_gib() {
  local kib="$1"
  awk -v kib="$kib" 'BEGIN { printf "%.2f", kib / 1024 / 1024 }'
}

disk_storage_from_config() {
  local config="$1"
  local disk="$2"
  local line value volid

  line="$(printf '%s\n' "$config" | grep -E "^${disk}: " || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*: }"
  volid="${value%%,*}"
  [[ "$volid" == *:* ]] || return 1
  printf '%s\n' "${volid%%:*}"
}

storage_available_kib() {
  local storage="$1"
  pvesm status --storage "$storage" 2>/dev/null | awk 'NR == 2 {print $6; exit}'
}

precheck_storage_space() {
  local -n storages_ref="$1"
  local increment_kib="$2"
  local -A required_by_storage=()
  local storage avail_kib required_kib ok=1

  for storage in "${storages_ref[@]}"; do
    [[ -n "$storage" ]] || continue
    required_by_storage["$storage"]=$(( ${required_by_storage["$storage"]:-0} + increment_kib ))
  done

  log "Storage precheck:"
  for storage in "${!required_by_storage[@]}"; do
    required_kib="${required_by_storage[$storage]}"
    avail_kib="$(storage_available_kib "$storage" || true)"
    if [[ -z "$avail_kib" || ! "$avail_kib" =~ ^[0-9]+$ ]]; then
      log "  storage=${storage}: unable to read available space via pvesm"
      ok=0
      continue
    fi

    log "  storage=${storage}: required=$(kib_to_gib "$required_kib")G available=$(kib_to_gib "$avail_kib")G"
    if (( avail_kib < required_kib )); then
      log "  storage=${storage}: not enough free space"
      ok=0
    fi
  done

  [[ "$ok" -eq 1 ]] || return 1
}

expand_windows_c_partition() {
  local vmid="$1"
  local ps

  ps='
$ErrorActionPreference = "Stop"
$reserveBytes = [int64]([double]'"$reserve_tail_gb"' * 1GB)
Update-HostStorageCache | Out-Null

$c = Get-Partition -DriveLetter C
$diskNumber = $c.DiskNumber
$trailing = @(Get-Partition -DiskNumber $diskNumber |
  Where-Object { $_.PartitionNumber -gt $c.PartitionNumber -and $_.Type -eq "Recovery" } |
  Sort-Object Offset)

$removed = @()
if ($trailing.Count -gt 0) {
  reagentc /disable | Out-Null
  foreach ($partition in $trailing) {
    $removed += [pscustomobject]@{
      PartitionNumber = $partition.PartitionNumber
      Type = $partition.Type
      SizeGB = [math]::Round($partition.Size/1GB,4)
    }
    Remove-Partition -DiskNumber $diskNumber -PartitionNumber $partition.PartitionNumber -Confirm:$false
  }
  Update-HostStorageCache | Out-Null
}

$beforeC = Get-Partition -DriveLetter C
$supported = Get-PartitionSupportedSize -DriveLetter C
$target = $supported.SizeMax - $reserveBytes
$target = [int64]([math]::Floor($target / 1MB) * 1MB)

if ($target -gt ($beforeC.Size + 100MB)) {
  Resize-Partition -DriveLetter C -Size $target
  $action = "resized"
} else {
  $action = "already-ok"
}

Update-HostStorageCache | Out-Null
$afterC = Get-Partition -DriveLetter C
$disk = Get-Disk -Number $diskNumber
$tailFree = $disk.Size - ($afterC.Offset + $afterC.Size)
$afterSupported = Get-PartitionSupportedSize -DriveLetter C
[pscustomobject]@{
  ReserveRequestedGB = [math]::Round($reserveBytes/1GB,4)
  RemovedTrailingRecovery = $removed
  BeforeCSizeGB = [math]::Round($beforeC.Size/1GB,4)
  SupportedMaxGB = [math]::Round($supported.SizeMax/1GB,4)
  TargetCSizeGB = [math]::Round($target/1GB,4)
  Action = $action
  TailFreeGB = [math]::Round($tailFree/1GB,4)
  After = [pscustomobject]@{
    Disk = $disk | Select-Object Number,FriendlyName,PartitionStyle,@{Name="SizeGB";Expression={[math]::Round($_.Size/1GB,4)}}
    Partitions = Get-Partition -DiskNumber $diskNumber | Sort-Object PartitionNumber | Select-Object DiskNumber,PartitionNumber,DriveLetter,Type,@{Name="OffsetGB";Expression={[math]::Round($_.Offset/1GB,4)}},@{Name="SizeGB";Expression={[math]::Round($_.Size/1GB,4)}}
    CSupportedMaxGB = [math]::Round($afterSupported.SizeMax/1GB,4)
    CVolume = Get-Volume -DriveLetter C | Select-Object DriveLetter,FileSystem,@{Name="SizeGB";Expression={[math]::Round($_.Size/1GB,4)}},@{Name="FreeGB";Expression={[math]::Round($_.SizeRemaining/1GB,4)}}
  }
} | ConvertTo-Json -Compress -Depth 6
'

  qm guest exec "$vmid" -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps"
}

start_steam_in_windows() {
  local vmid="$1"
  local ps

  ps='
$ErrorActionPreference = "Stop"
$proc = Get-Process -Name steam -ErrorAction SilentlyContinue | Select-Object -First 1 Id,ProcessName,Path
$paths = @(
  "C:\Program Files (x86)\Steam\steam.exe",
  "C:\Program Files\Steam\steam.exe",
  "D:\Steam\steam.exe"
)
$steamExe = $paths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $steamExe) {
  $reg = Get-ItemProperty -Path "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue
  if ($reg -and $reg.InstallPath) {
    $candidate = Join-Path $reg.InstallPath "steam.exe"
    if (Test-Path $candidate) { $steamExe = $candidate }
  }
}
$action = "already-running"
if (-not $proc) {
  if ($steamExe) {
    Start-Process -FilePath $steamExe -ArgumentList "-silent" -WorkingDirectory (Split-Path $steamExe)
    Start-Sleep -Seconds 8
    $proc = Get-Process -Name steam -ErrorAction SilentlyContinue | Select-Object -First 1 Id,ProcessName,Path
    if ($proc) { $action = "started" } else { $action = "start-command-sent-but-not-detected" }
  } else {
    $action = "steam-exe-not-found"
  }
}
[pscustomobject]@{
  Action = $action
  SteamExe = $steamExe
  Process = $proc
} | ConvertTo-Json -Compress -Depth 4
'

  qm guest exec "$vmid" -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps"
}

is_real_disk_line() {
  local key="$1"
  local value="$2"

  [[ "$key" =~ ^(scsi|virtio|sata|ide)[0-9]+$ ]] || return 1
  [[ "$value" == *"media=cdrom"* ]] && return 1
  [[ "$value" == *"cloudinit"* ]] && return 1
  [[ "$value" == *"none"* ]] && return 1
  return 0
}

disk_exists_in_config() {
  local config="$1"
  local disk="$2"
  local line value

  line="$(printf '%s\n' "$config" | grep -E "^${disk}: " || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*: }"
  is_real_disk_line "$disk" "$value"
}

select_disk() {
  local config="$1"
  local boot_line boot_order candidate key value
  local line

  boot_line="$(printf '%s\n' "$config" | awk -F': ' '/^boot:/ {print $2; exit}')"
  if [[ "$boot_line" == order=* ]]; then
    boot_order="${boot_line#order=}"
    IFS=';' read -r -a boot_items <<< "$boot_order"
    for candidate in "${boot_items[@]}"; do
      if disk_exists_in_config "$config" "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  while IFS= read -r key; do
    line="$(printf '%s\n' "$config" | grep -E "^${key}: " || true)"
    [[ -n "$line" ]] || continue
    value="${line#*: }"
    if is_real_disk_line "$key" "$value"; then
      printf '%s\n' "$key"
      return 0
    fi
  done < <(
    printf '%s\n' "$config" |
      awk -F': ' '/^(scsi|virtio|sata|ide)[0-9]+:/ {print $1}' |
      sort -V
  )

  return 1
}

is_template() {
  local config="$1"
  printf '%s\n' "$config" | grep -qx 'template: 1'
}

vmid_allowed() {
  local vmid="$1"
  [[ -z "$vm_filter" ]] && return 0
  [[ ",${vm_filter}," == *",${vmid},"* ]]
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        apply=0
        shift
        ;;
      --size)
        [[ $# -ge 2 ]] || die "--size requires a value, e.g. +15G"
        increment="$2"
        shift 2
        ;;
      --include-templates)
        include_templates=1
        shift
        ;;
      --vmid|--only-vmid)
        [[ $# -ge 2 ]] || die "--vmid requires comma-separated VMIDs"
        vm_filter="$2"
        shift 2
        ;;
      --skip-space-check)
        skip_space_check=1
        shift
        ;;
      --no-watchdog-disable)
        auto_disable_watchdog=0
        shift
        ;;
      --stop-timeout)
        [[ $# -ge 2 ]] || die "--stop-timeout requires seconds"
        stop_timeout="$2"
        shift 2
        ;;
      --start-timeout)
        [[ $# -ge 2 ]] || die "--start-timeout requires seconds"
        start_timeout="$2"
        shift 2
        ;;
      --guest-retry-attempts)
        [[ $# -ge 2 ]] || die "--guest-retry-attempts requires a count"
        guest_retry_attempts="$2"
        shift 2
        ;;
      --guest-retry-delay)
        [[ $# -ge 2 ]] || die "--guest-retry-delay requires seconds"
        guest_retry_delay="$2"
        shift 2
        ;;
      --expand-windows-c)
        expand_windows_c=1
        shift
        ;;
      --no-windows-c)
        expand_windows_c=0
        shift
        ;;
      --reserve-tail-gb)
        [[ $# -ge 2 ]] || die "--reserve-tail-gb requires gigabytes"
        reserve_tail_gb="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ "$increment" =~ ^\+[0-9]+[KMGTP]?$ ]] || die "--size must look like +15G"
  [[ "$stop_timeout" =~ ^[0-9]+$ ]] || die "--stop-timeout must be seconds"
  [[ "$start_timeout" =~ ^[0-9]+$ ]] || die "--start-timeout must be seconds"
  [[ "$guest_retry_attempts" =~ ^[0-9]+$ ]] || die "--guest-retry-attempts must be a count"
  [[ "$guest_retry_delay" =~ ^[0-9]+$ ]] || die "--guest-retry-delay must be seconds"
  [[ "$guest_retry_attempts" -ge 1 ]] || die "--guest-retry-attempts must be at least 1"
  [[ "$reserve_tail_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--reserve-tail-gb must be numeric"
}

process_vm() {
  local vmid="$1"
  local name="$2"
  local disk="$3"
  local initial_status=""
  local start_after_resize=0

  initial_status="$(vm_status "$vmid" || true)"
  [[ -n "$initial_status" ]] || initial_status="unknown"

  if [[ "$apply" -eq 0 ]]; then
    log "VM vmid=${vmid} name=${name}: would resize ${disk} by ${increment}; current_status=${initial_status}; apply_plan=stop-if-running,resize$(if [[ "$expand_windows_c" -eq 1 ]]; then printf ',start-after-resize,guest-agent-4x-after-2min,expand-windows-c-leave-%sGiB-tail,start-steam' "$reserve_tail_gb"; else printf ',start-if-was-running'; fi)"
    return 0
  fi

  log "VM vmid=${vmid} name=${name}: status=${initial_status}, disk=${disk}, increment=${increment}"

  if [[ "$initial_status" == "running" ]]; then
    log "VM vmid=${vmid}: stopping"
    qm stop "$vmid"
    wait_for_status "$vmid" "stopped" "$stop_timeout"
    start_after_resize=1
  elif [[ "$initial_status" != "stopped" ]]; then
    die "vmid=${vmid} is in unsupported status '${initial_status}'"
  fi

  if [[ "$expand_windows_c" -eq 1 ]]; then
    start_after_resize=1
  fi

  log "VM vmid=${vmid}: resizing ${disk} by ${increment}"
  qm resize "$vmid" "$disk" "$increment"

  if [[ "$start_after_resize" -eq 1 ]]; then
    log "VM vmid=${vmid}: starting"
    qm start "$vmid"
    wait_for_status "$vmid" "running" "$start_timeout"
  fi

  if [[ "$expand_windows_c" -eq 1 ]]; then
    log "VM vmid=${vmid}: waiting for Windows guest agent"
    wait_for_guest_agent_after_start "$vmid" "$guest_retry_attempts" "$guest_retry_delay"
    log "VM vmid=${vmid}: expanding Windows C: leaving ${reserve_tail_gb} GiB unallocated tail"
    expand_windows_c_partition "$vmid"
    log "VM vmid=${vmid}: starting Steam if needed"
    start_steam_in_windows "$vmid"
  fi

  log "VM vmid=${vmid}: done"
}

main() {
  parse_args "$@"

  local vmids=()
  local config name disk vmid
  local storage increment_kib
  local selected_vmids=()
  local selected_names=()
  local selected_disks=()
  local selected_storages=()
  local resized=0
  local skipped=0
  local pids=()
  local pid failed file

  command -v qm >/dev/null 2>&1 || die "qm command not found; run this on a Proxmox host"

  if [[ "$apply" -eq 0 ]]; then
    log "Mode: dry-run. Nothing will be changed."
  else
    log "Mode: apply. VMs are processed in parallel. Running VMs will be stopped, resized by ${increment}, then started again."
    if [[ "$expand_windows_c" -eq 1 ]]; then
      log "Windows C: expansion enabled. Each VM will leave ${reserve_tail_gb} GiB unallocated at the end of the disk, then Steam will be started if needed. Guest agent attempts=${guest_retry_attempts}, delay=${guest_retry_delay}s."
    fi
  fi

  mapfile -t vmids < <(qm list | awk 'NR > 1 {print $1}' | sort -n)
  [[ "${#vmids[@]}" -gt 0 ]] || die "no QEMU VMs found on this host"

  for vmid in "${vmids[@]}"; do
    vmid_allowed "$vmid" || continue

    config="$(qm config "$vmid")"
    name="$(printf '%s\n' "$config" | awk -F': ' '/^name:/ {print $2; exit}')"
    [[ -n "$name" ]] || name="vm-${vmid}"

    if [[ "$include_templates" -eq 0 ]] && is_template "$config"; then
      log "SKIP vmid=${vmid} name=${name}: template"
      skipped=$((skipped + 1))
      continue
    fi

    if ! disk="$(select_disk "$config")"; then
      log "SKIP vmid=${vmid} name=${name}: no resizable disk found"
      skipped=$((skipped + 1))
      continue
    fi

    if ! storage="$(disk_storage_from_config "$config" "$disk")"; then
      log "SKIP vmid=${vmid} name=${name}: unable to detect Proxmox storage for ${disk}"
      skipped=$((skipped + 1))
      continue
    fi

    selected_vmids+=("$vmid")
    selected_names+=("$name")
    selected_disks+=("$disk")
    selected_storages+=("$storage")
    resized=$((resized + 1))
  done

  [[ "${#selected_vmids[@]}" -gt 0 ]] || die "no selected VMs with resizable disks found"

  increment_kib="$(increment_to_kib "$increment")" || die "unable to parse increment ${increment}"
  if [[ "$skip_space_check" -eq 0 ]]; then
    precheck_storage_space selected_storages "$increment_kib" || die "storage precheck failed; not starting VM changes"
  else
    log "Storage precheck skipped by --skip-space-check"
  fi

  if [[ "$apply" -eq 1 && "$auto_disable_watchdog" -eq 1 ]]; then
    disable_watchdog_if_found
  elif [[ "$apply" -eq 1 ]]; then
    log "Watchdog auto-disable skipped by --no-watchdog-disable"
  fi

  for idx in "${!selected_vmids[@]}"; do
    vmid="${selected_vmids[$idx]}"
    name="${selected_names[$idx]}"
    disk="${selected_disks[$idx]}"

    if [[ "$apply" -eq 1 ]]; then
      mkdir -p "${log_dir}"
      (
        process_vm "$vmid" "$name" "$disk"
      ) >"${log_dir}/${vmid}.log" 2>&1 &
      pids+=("$!")
    else
      process_vm "$vmid" "$name" "$disk"
    fi
  done

  if [[ "$apply" -eq 1 ]]; then
    failed=0
    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        failed=1
      fi
    done

    for file in "${log_dir}"/*.log; do
      [[ -e "$file" ]] || continue
      cat "$file"
    done

    if [[ "$failed" -ne 0 ]]; then
      die "one or more VM resize jobs failed; logs are in ${log_dir}"
    fi
  fi

  log "Done. planned_or_resized=${resized} skipped=${skipped}"
}

log_dir="/tmp/proxmox-expand-vm-disks.$(date +%Y%m%d-%H%M%S).$$"
main "$@"
