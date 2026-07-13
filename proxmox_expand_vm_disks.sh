#!/usr/bin/env bash
set -euo pipefail

increment=""
apply=1
include_templates=0
vm_filter=""
skip_space_check=0
auto_disable_watchdog=1
detach=1
stop_timeout=300
start_timeout=300
guest_retry_attempts=4
guest_retry_delay=120
max_parallel=4
windows_exec_timeout=900
expand_windows_c=1
reserve_tail_gb=1
pve_ok_gb=119
windows_ok_gb=117.5
manage_vgpu=1
shutdown_timeout=300
log_dir=""
watchdog_restore_command=""
watchdog_restore_script=""
watchdog_restored=0
interrupted=0
current_step="init"
script_source_url="https://raw.githubusercontent.com/sinitcad/proxmox-vm-disk-expander/main/proxmox_expand_vm_disks.sh"

usage() {
  cat <<'EOF'
Usage:
  proxmox_expand_vm_disks.sh [--dry-run] [--include-templates] [--vmid 100,101]
                              [--only-vmid 101]
                              [--no-windows-c] [--reserve-tail-gb 1] [--skip-space-check]
                              [--parallel 4] [--windows-exec-timeout 900]
                              [--pve-ok-gb 119] [--windows-ok-gb 117.5]
                              [--size +15G]
                              [--no-detach] [--no-watchdog-disable]
                              [--no-vgpu-manage] [--shutdown-timeout 300]

Expands one main QEMU disk per VM on the current Proxmox host.

Default mode is apply. Use --dry-run to preview without changes.

Apply mode runs VMs in bounded parallel batches:
  - Build a full plan for selected VMs before changing anything
  - Read current Proxmox disk size from qm config
  - Check free space only for disks below --pve-ok-gb
  - For lvmthin storages that need resize, also check physical thin-pool free space
  - Auto-detect and disable watchdog cron/processes
  - Leave watchdog disabled after full success, auto-restore on failure/interrupt
  - Detect VM state
  - If the Proxmox disk is already >= --pve-ok-gb, skip qm resize and only
    verify/repair Windows and Steam
  - If the Proxmox disk is below --pve-ok-gb, stop if needed and resize by
    the automatically calculated amount needed to reach --pve-ok-gb
  - If Windows work is enabled, start the VM, wait for guest agent, and first
    run a read-only Windows/Steam check
  - If Windows disk/C: is below --windows-ok-gb or Steam is not running,
    repair C: and Steam, then verify again

VMs that were already stopped are started when Windows verification/repair is
enabled, because QEMU Guest Agent is needed for the Windows-side work.

vGPU handling (enabled by default, disable with --no-vgpu-manage):
  Some Windows VMs with a passed-through vGPU (hostpciN) leave the QEMU guest
  agent unresponsive after a stop/start until the vGPU is detached and
  re-attached. To make Windows work reliable, this script, while the VM is
  stopped, detaches all hostpciN devices, starts the VM WITHOUT the vGPU (the
  guest agent then responds), performs the Windows/Steam work, then stops the
  VM again, re-attaches the exact hostpciN lines it saved, and starts the VM
  with the vGPU restored. The saved hostpci lines are written to
  <log_dir>/<vmid>.hostpci and auto-restored on failure or interrupt so a VM is
  never left without its vGPU. Graceful ACPI shutdown is tried first
  (--shutdown-timeout, default 300s) before any hard stop.

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
  - Job logs are streamed live to stdout and saved under /tmp
  - Apply runs start through nohup by default so the job survives closing SSH
  - Use --no-detach for foreground output in the current SSH session

Examples:
  ./proxmox_expand_vm_disks.sh
  ./proxmox_expand_vm_disks.sh --no-detach
  ./proxmox_expand_vm_disks.sh --dry-run
  ./proxmox_expand_vm_disks.sh --parallel 2 --windows-exec-timeout 1800
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

vgpu_state_file() {
  local vmid="$1"
  printf '%s/%s.hostpci' "$log_dir" "$vmid"
}

# Detach all hostpciN (vGPU / passthrough) lines from a STOPPED VM and persist
# them to disk so they can always be restored, even after a crash or interrupt.
detach_vgpu_if_present() {
  local vmid="$1"
  local config statefile hostpci_lines key value

  [[ "$manage_vgpu" -eq 1 ]] || return 0

  statefile="$(vgpu_state_file "$vmid")"

  # If a state file already exists with content, vGPU was already detached in a
  # previous step or a prior interrupted run; do not overwrite it.
  if [[ -s "$statefile" ]]; then
    log "VM vmid=${vmid}: vGPU state already saved; skipping re-detach"
    return 0
  fi

  config="$(qm config "$vmid")"
  hostpci_lines="$(printf '%s\n' "$config" | grep -E '^hostpci[0-9]+: ' || true)"

  if [[ -z "$hostpci_lines" ]]; then
    log "VM vmid=${vmid}: no hostpci/vGPU devices in config; nothing to detach"
    # Write an empty marker so restore is a no-op and we do not re-scan later.
    : > "$statefile"
    return 0
  fi

  mkdir -p "$log_dir"
  printf '%s\n' "$hostpci_lines" > "$statefile"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%:*}"
    value="${line#*: }"
    log "VM vmid=${vmid}: detaching ${key} (${value}) before starting without vGPU"
    qm set "$vmid" "--delete" "$key" >/dev/null
  done <<< "$hostpci_lines"

  log "VM vmid=${vmid}: vGPU/passthrough detached and saved to ${statefile}"
}

# Restore previously detached hostpciN lines onto a STOPPED VM.
# Safe to call multiple times: it clears the state file on success.
restore_vgpu_if_needed() {
  local vmid="$1"
  local statefile key value line

  [[ "$manage_vgpu" -eq 1 ]] || return 0

  statefile="$(vgpu_state_file "$vmid")"
  [[ -f "$statefile" ]] || return 0

  # Empty marker means there was nothing to restore.
  if [[ ! -s "$statefile" ]]; then
    rm -f "$statefile"
    return 0
  fi

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    key="${line%%:*}"
    value="${line#*: }"
    log "VM vmid=${vmid}: restoring ${key} (${value})"
    qm set "$vmid" "--${key}" "$value" >/dev/null
  done < "$statefile"

  rm -f "$statefile"
  log "VM vmid=${vmid}: vGPU/passthrough restored"
}

# Failure/interrupt path: ensure the VM gets its vGPU back so it is never left
# unusable for the end user. Called from the per-VM EXIT trap on non-zero rc.
restore_vgpu_on_failure() {
  local vmid="$1"
  local statefile

  [[ "$manage_vgpu" -eq 1 ]] || return 0
  statefile="$(vgpu_state_file "$vmid")"
  [[ -s "$statefile" ]] || return 0

  log "VM vmid=${vmid}: failure/interrupt detected; restoring vGPU before exit"
  # Restoring hostpci requires a stopped VM. Force-stop is acceptable here
  # because the final boot with vGPU re-initializes the guest agent cleanly.
  if [[ "$(vm_status "$vmid" || true)" != "stopped" ]]; then
    qm stop "$vmid" >/dev/null 2>&1 || true
    wait_for_status "$vmid" "stopped" "$stop_timeout" || true
  fi
  restore_vgpu_if_needed "$vmid" || log "VM vmid=${vmid}: WARNING: vGPU restore failed; restore manually from ${statefile}"
  # Try to bring the VM back up for the user.
  qm start "$vmid" >/dev/null 2>&1 || true
}

# Bring a VM to 'stopped' as gently as possible: try ACPI shutdown first,
# fall back to hard stop only if it does not power off in time.
graceful_stop_vm() {
  local vmid="$1"
  local status

  status="$(vm_status "$vmid" || true)"
  [[ "$status" == "stopped" ]] && return 0

  log "VM vmid=${vmid}: attempting graceful shutdown (timeout ${shutdown_timeout}s)"
  if qm shutdown "$vmid" --timeout "$shutdown_timeout" >/dev/null 2>&1 \
      && wait_for_status "$vmid" "stopped" "$shutdown_timeout"; then
    log "VM vmid=${vmid}: shut down gracefully"
    return 0
  fi

  log "VM vmid=${vmid}: graceful shutdown did not complete; forcing stop"
  qm stop "$vmid"
  wait_for_status "$vmid" "stopped" "$stop_timeout"
}

wait_for_guest_agent_after_start() {
  local vmid="$1"
  local attempts="$2"
  local delay="$3"
  local attempt

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    log "VM vmid=${vmid}: sleeping ${delay}s before guest agent attempt ${attempt}/${attempts}"
    sleep "$delay"
    if timeout 75s qm guest exec "$vmid" --synchronous 1 --timeout 60 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Output ready" >/dev/null 2>&1; then
      log "VM vmid=${vmid}: guest agent is ready on attempt ${attempt}/${attempts}"
      return 0
    fi
    log "VM vmid=${vmid}: guest agent attempt ${attempt}/${attempts} failed"
  done

  printf 'timeout waiting for vmid=%s guest agent after %s attempts\n' "$vmid" "$attempts" >&2
  return 1
}

guest_agent_ready_now() {
  local vmid="$1"
  timeout 75s qm guest exec "$vmid" --synchronous 1 --timeout 60 -- powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Write-Output ready" >/dev/null 2>&1
}

# Run the Windows repair, retrying only on transport-level failures (QMP /
# guest-agent timeouts, rc=255/1 with no exitcode), which are transient. A
# logical failure (rc=2, i.e. the guest ran the command but Success=false) is
# returned as-is and NOT retried here.
windows_repair_with_retries() {
  local vmid="$1"
  local attempts="${2:-3}"
  local delay="${3:-30}"
  local attempt rc=0

  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    rc=0
    windows_resize_verify_and_steam "$vmid" || rc="$?"

    if [[ "$rc" -eq 0 || "$rc" -eq 2 ]]; then
      # 0 = success, 2 = guest ran but reported not-ok (a real logical result,
      # not a transport error). Either way, stop retrying and return it.
      return "$rc"
    fi

    log "VM vmid=${vmid}: repair transport failure (rc=${rc}) on attempt ${attempt}/${attempts}"
    if (( attempt < attempts )); then
      log "VM vmid=${vmid}: re-checking guest agent before retry in ${delay}s"
      sleep "$delay"
      guest_agent_ready_now "$vmid" || log "VM vmid=${vmid}: guest agent still not responding; retrying anyway"
    fi
  done

  return "$rc"
}

stop_start_vm_for_guest_agent() {
  local vmid="$1"

  set_step "guest-agent-stop-start"
  log "VM vmid=${vmid}: guest agent is not usable; doing stop/start"
  qm stop "$vmid"
  wait_for_status "$vmid" "stopped" "$stop_timeout"
  qm start "$vmid"
  wait_for_status "$vmid" "running" "$start_timeout"
  wait_for_guest_agent_after_start "$vmid" "$guest_retry_attempts" "$guest_retry_delay"
}

ensure_guest_agent_ready() {
  local vmid="$1"
  local allow_stop_start="${2:-1}"

  set_step "guest-agent"
  log "VM vmid=${vmid}: checking Windows guest agent"
  if guest_agent_ready_now "$vmid"; then
    log "VM vmid=${vmid}: guest agent is ready"
    return 0
  fi

  if [[ "$allow_stop_start" -eq 1 ]]; then
    stop_start_vm_for_guest_agent "$vmid"
    return 0
  fi

  wait_for_guest_agent_after_start "$vmid" "$guest_retry_attempts" "$guest_retry_delay"
}

log() {
  printf '%s\n' "$*"
}

set_step() {
  current_step="$1"
  log "STEP: ${current_step}"
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

restore_watchdog_if_needed() {
  if [[ -z "$watchdog_restore_script" || "$watchdog_restored" -eq 1 ]]; then
    return 0
  fi

  log "Watchdog auto-restore: running ${watchdog_restore_script}"
  if bash "$watchdog_restore_script"; then
    watchdog_restored=1
    log "Watchdog auto-restore: completed"
    return 0
  fi

  log "Watchdog auto-restore: failed; run manually: bash ${watchdog_restore_script}"
  return 1
}

on_exit() {
  local rc="$?"
  if [[ -n "$watchdog_restore_command" ]]; then
    if (( rc != 0 || interrupted == 1 )); then
      restore_watchdog_if_needed || true
    else
      print_watchdog_restore_command
    fi
  fi
}

on_signal() {
  local job_pids=()

  interrupted=1
  log "Interrupted; stopping outstanding work and restoring watchdog if possible"
  trap - INT TERM
  mapfile -t job_pids < <(jobs -pr)
  if [[ "${#job_pids[@]}" -gt 0 ]]; then
    kill "${job_pids[@]}" 2>/dev/null || true
  fi
  exit 130
}

trap on_exit EXIT
trap on_signal INT TERM

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
  watchdog_restore_script="$run_dir/enable_watchdog.sh"
  log "Watchdog auto-disable: disabled and left disabled"
  log "Watchdog auto-disable: restore command will be printed on success; auto-restore will be attempted on failure or interrupt"
}

increment_to_kib() {
  local size="$1"
  local value unit

  [[ "$size" =~ ^\+([0-9]+)([KMGTPkmgpt]?)$ ]] || return 1
  value="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]^^}"

  case "$unit" in
    K) printf '%s\n' "$value" ;;
    M) printf '%s\n' $((value * 1024)) ;;
    ""|G) printf '%s\n' $((value * 1024 * 1024)) ;;
    T) printf '%s\n' $((value * 1024 * 1024 * 1024)) ;;
    P) printf '%s\n' $((value * 1024 * 1024 * 1024 * 1024)) ;;
    *) return 1 ;;
  esac
}

resize_mib_to_target() {
  local current_gb="$1"
  local target_gb="$2"

  awk -v current="$current_gb" -v target="$target_gb" '
    BEGIN {
      diff = target - current
      if (diff <= 0) {
        print 0
        exit
      }
      mib = diff * 1024
      rounded = int(mib)
      if (mib > rounded) {
        rounded += 1
      }
      if (rounded < 1) {
        rounded = 1
      }
      print rounded
    }'
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

size_to_gib() {
  local size="$1"
  local value unit

  [[ "$size" =~ ^([0-9]+([.][0-9]+)?)([KMGTPkmgpt]?)$ ]] || return 1
  value="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[3]^^}"

  case "$unit" in
    K) awk -v v="$value" 'BEGIN { printf "%.4f\n", v / 1024 / 1024 }' ;;
    M) awk -v v="$value" 'BEGIN { printf "%.4f\n", v / 1024 }' ;;
    ""|G) awk -v v="$value" 'BEGIN { printf "%.4f\n", v }' ;;
    T) awk -v v="$value" 'BEGIN { printf "%.4f\n", v * 1024 }' ;;
    P) awk -v v="$value" 'BEGIN { printf "%.4f\n", v * 1024 * 1024 }' ;;
    *) return 1 ;;
  esac
}

float_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'
}

float_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'
}

disk_size_gib_from_config() {
  local config="$1"
  local disk="$2"
  local line value size_token raw_size

  line="$(printf '%s\n' "$config" | grep -E "^${disk}: " || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*: }"
  size_token="$(printf '%s\n' "$value" | grep -Eio '(^|,)size=[0-9.]+[KMGTP]?' | tail -n 1 || true)"
  [[ -n "$size_token" ]] || return 1
  raw_size="${size_token##*size=}"
  size_to_gib "$raw_size"
}

storage_available_kib() {
  local storage="$1"
  pvesm status --storage "$storage" 2>/dev/null | awk 'NR == 2 {print $6; exit}'
}

thin_pool_free_kib() {
  local storage="$1"
  local cfg type vg thinpool data_percent lv_size_kib

  cfg="$(pvesm config "$storage" 2>/dev/null || true)"
  type="$(printf '%s\n' "$cfg" | awk -F': ' 'NR == 1 {print $1; exit}')"
  [[ "$type" == "lvmthin" ]] || return 1

  vg="$(printf '%s\n' "$cfg" | awk '/^[[:space:]]+vgname[[:space:]]+/ {print $2; exit}')"
  thinpool="$(printf '%s\n' "$cfg" | awk '/^[[:space:]]+thinpool[[:space:]]+/ {print $2; exit}')"
  [[ -n "$vg" && -n "$thinpool" ]] || return 2
  command -v lvs >/dev/null 2>&1 || return 2

  read -r data_percent lv_size_kib < <(
    lvs --noheadings --units k --nosuffix -o data_percent,lv_size "$vg/$thinpool" 2>/dev/null |
      awk '{gsub(",", ".", $1); printf "%s %s\n", $1, int($2)}'
  )
  [[ -n "${data_percent:-}" && -n "${lv_size_kib:-}" ]] || return 2

  awk -v size="$lv_size_kib" -v used="$data_percent" 'BEGIN { printf "%d\n", size * (100 - used) / 100 }'
}

precheck_storage_space() {
  local -n storages_ref="$1"
  local -n required_ref="$2"
  local -A required_by_storage=()
  local idx storage avail_kib required_kib thin_free_kib thin_rc ok=1

  for idx in "${!storages_ref[@]}"; do
    storage="${storages_ref[$idx]}"
    [[ -n "$storage" ]] || continue
    required_by_storage["$storage"]=$(( ${required_by_storage["$storage"]:-0} + ${required_ref[$idx]} ))
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

    set +e
    thin_free_kib="$(thin_pool_free_kib "$storage")"
    thin_rc="$?"
    set -e
    if [[ "$thin_rc" -eq 0 ]]; then
      log "  storage=${storage}: lvmthin physical_free=$(kib_to_gib "$thin_free_kib")G"
      if (( thin_free_kib < required_kib )); then
        log "  storage=${storage}: not enough physical thin-pool free space"
        ok=0
      fi
    elif [[ "$thin_rc" -eq 2 ]]; then
      log "  storage=${storage}: lvmthin physical free check failed"
      ok=0
    fi
  done

  [[ "$ok" -eq 1 ]] || return 1
}

qm_guest_exec_sync_checked() {
  local vmid="$1"
  local command_timeout="$2"
  local output rc
  shift 2

  set +e
  output="$(timeout "$((command_timeout + 60))s" qm guest exec "$vmid" --synchronous 1 --timeout "$command_timeout" -- "$@" 2>&1)"
  rc="$?"
  set -e

  printf '%s\n' "$output"

  if (( rc != 0 )); then
    log "VM vmid=${vmid}: qm guest exec failed with rc=${rc}"
    return "$rc"
  fi

  if printf '%s\n' "$output" | grep -Eq '"exitcode"[[:space:]]*:[[:space:]]*0'; then
    return 0
  fi

  if printf '%s\n' "$output" | grep -Eq '"exitcode"[[:space:]]*:'; then
    log "VM vmid=${vmid}: guest command completed with non-zero exitcode"
    return 2
  fi

  log "VM vmid=${vmid}: guest command output did not contain an exitcode; treating as failure"
  return 1
}

windows_state_check() {
  local vmid="$1"
  local ps

  ps='
$ErrorActionPreference = "Stop"
$minGb = [double]'"$windows_ok_gb"'
Update-HostStorageCache | Out-Null

$c = Get-Partition -DriveLetter C
$disk = Get-Disk -Number $c.DiskNumber
$vol = Get-Volume -DriveLetter C
$proc = Get-Process -Name steam -ErrorAction SilentlyContinue | Select-Object -First 1 Id,ProcessName,Path

$diskGb = [math]::Round($disk.Size/1GB,4)
$cGb = [math]::Round($c.Size/1GB,4)
$diskOk = ($disk.Size -ge ([int64]($minGb * 1GB)))
$cOk = ($c.Size -ge ([int64]($minGb * 1GB)))
$steamOk = [bool]$proc
$success = $diskOk -and $cOk -and $steamOk

[pscustomobject]@{
  Success = $success
  Mode = "check-only"
  MinWindowsGB = $minGb
  DiskGB = $diskGb
  CGB = $cGb
  FreeGB = [math]::Round($vol.SizeRemaining/1GB,4)
  DiskOk = $diskOk
  COk = $cOk
  Steam = $steamOk
  SteamProcess = $proc
} | ConvertTo-Json -Compress -Depth 4

if (-not $success) { exit 2 }
'

  qm_guest_exec_sync_checked "$vmid" "$windows_exec_timeout" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps"
}

windows_resize_verify_and_steam() {
  local vmid="$1"
  local ps

  ps='
$ErrorActionPreference = "Stop"
$reserveBytes = [int64]([double]'"$reserve_tail_gb"' * 1GB)
$tailToleranceBytes = [int64](512MB)
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
$vol = Get-Volume -DriveLetter C

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
$steamAction = "already-running"
if (-not $proc) {
  if ($steamExe) {
    Start-Process -FilePath $steamExe -ArgumentList "-silent" -WorkingDirectory (Split-Path $steamExe)
    Start-Sleep -Seconds 10
    $proc = Get-Process -Name steam -ErrorAction SilentlyContinue | Select-Object -First 1 Id,ProcessName,Path
    if ($proc) { $steamAction = "started" } else { $steamAction = "start-command-sent-but-not-detected" }
  } else {
    $steamAction = "steam-exe-not-found"
  }
}

$tailOk = ([math]::Abs([double]($tailFree - $reserveBytes)) -le $tailToleranceBytes)
$cOk = ($afterC.Size -ge ($target - 100MB))
$steamOk = [bool]$proc
$success = $tailOk -and $cOk -and $steamOk
$result = [pscustomobject]@{
  Success = $success
  Action = $action
  DiskGB = [math]::Round($disk.Size/1GB,4)
  BeforeCGB = [math]::Round($beforeC.Size/1GB,4)
  CGB = [math]::Round($afterC.Size/1GB,4)
  TargetCGB = [math]::Round($target/1GB,4)
  TailGB = [math]::Round($tailFree/1GB,4)
  ReserveGB = [math]::Round($reserveBytes/1GB,4)
  FreeGB = [math]::Round($vol.SizeRemaining/1GB,4)
  TailOk = $tailOk
  COk = $cOk
  Steam = $steamOk
  SteamAction = $steamAction
  SteamExe = $steamExe
  RemovedTrailingRecovery = $removed
}
$result | ConvertTo-Json -Compress -Depth 5
if (-not $success) { exit 2 }
'

  qm_guest_exec_sync_checked "$vmid" "$windows_exec_timeout" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps"
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

launch_detached_and_exit() {
  local args=("$@")
  local run_dir script_path log_path pid

  command -v nohup >/dev/null 2>&1 || die "nohup command not found; cannot detach"

  run_dir="/tmp/proxmox-expand-vm-disks.detached.$(date +%Y%m%d-%H%M%S).$$"
  script_path="$run_dir/proxmox_expand_vm_disks.sh"
  log_path="$run_dir/run.log"
  mkdir -p "$run_dir"

  if [[ -r "${BASH_SOURCE[0]}" && "${BASH_SOURCE[0]}" != /dev/fd/* && "${BASH_SOURCE[0]}" != /proc/* ]]; then
    cat "${BASH_SOURCE[0]}" > "$script_path"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$script_source_url" -o "$script_path"
  else
    die "unable to copy current script for detached run and curl is not available"
  fi
  chmod +x "$script_path"

  nohup bash "$script_path" "${args[@]}" --no-detach > "$log_path" 2>&1 < /dev/null &
  pid="$!"

  printf 'Detached run started. SSH can be closed now.\n'
  printf 'PID: %s\n' "$pid"
  printf 'Log: %s\n' "$log_path"
  printf 'Watch live:\n  tail -f %q\n' "$log_path"
  printf 'Check process:\n  ps -p %s -o pid,etime,cmd\n' "$pid"
  exit 0
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
      --detach)
        detach=1
        shift
        ;;
      --no-detach|--foreground)
        detach=0
        shift
        ;;
      --no-watchdog-disable)
        auto_disable_watchdog=0
        shift
        ;;
      --no-vgpu-manage)
        manage_vgpu=0
        shift
        ;;
      --shutdown-timeout)
        [[ $# -ge 2 ]] || die "--shutdown-timeout requires seconds"
        shutdown_timeout="$2"
        shift 2
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
      --parallel)
        [[ $# -ge 2 ]] || die "--parallel requires a number"
        max_parallel="$2"
        shift 2
        ;;
      --windows-exec-timeout)
        [[ $# -ge 2 ]] || die "--windows-exec-timeout requires seconds"
        windows_exec_timeout="$2"
        shift 2
        ;;
      --pve-ok-gb)
        [[ $# -ge 2 ]] || die "--pve-ok-gb requires gigabytes"
        pve_ok_gb="$2"
        shift 2
        ;;
      --windows-ok-gb)
        [[ $# -ge 2 ]] || die "--windows-ok-gb requires gigabytes"
        windows_ok_gb="$2"
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

  [[ -z "$increment" || "$increment" =~ ^\+[0-9]+[KMGTPkmgpt]?$ ]] || die "--size must look like +15G"
  [[ "$stop_timeout" =~ ^[0-9]+$ ]] || die "--stop-timeout must be seconds"
  [[ "$start_timeout" =~ ^[0-9]+$ ]] || die "--start-timeout must be seconds"
  [[ "$shutdown_timeout" =~ ^[0-9]+$ ]] || die "--shutdown-timeout must be seconds"
  [[ "$guest_retry_attempts" =~ ^[0-9]+$ ]] || die "--guest-retry-attempts must be a count"
  [[ "$guest_retry_delay" =~ ^[0-9]+$ ]] || die "--guest-retry-delay must be seconds"
  [[ "$max_parallel" =~ ^[0-9]+$ ]] || die "--parallel must be a number"
  [[ "$windows_exec_timeout" =~ ^[0-9]+$ ]] || die "--windows-exec-timeout must be seconds"
  [[ "$pve_ok_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--pve-ok-gb must be numeric"
  [[ "$windows_ok_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--windows-ok-gb must be numeric"
  [[ "$guest_retry_attempts" -ge 1 ]] || die "--guest-retry-attempts must be at least 1"
  [[ "$max_parallel" -ge 1 ]] || die "--parallel must be at least 1"
  [[ "$windows_exec_timeout" -ge 60 ]] || die "--windows-exec-timeout must be at least 60"
  [[ "$reserve_tail_gb" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--reserve-tail-gb must be numeric"
}

process_vm() {
  local vmid="$1"
  local name="$2"
  local disk="$3"
  local pve_disk_gb="$4"
  local resize_increment="$5"
  local initial_status=""
  local started_now=0
  local did_pve_resize=0
  local check_rc=0

  initial_status="$(vm_status "$vmid" || true)"
  [[ -n "$initial_status" ]] || initial_status="unknown"

  if [[ "$apply" -eq 0 ]]; then
    if float_ge "$pve_disk_gb" "$pve_ok_gb"; then
      log "VM vmid=${vmid} name=${name}: dry-run pve=${pve_disk_gb}G >= ${pve_ok_gb}G, PVE resize not needed; Windows/Steam check would run"
    else
      log "VM vmid=${vmid} name=${name}: dry-run pve=${pve_disk_gb}G < ${pve_ok_gb}G, would stop-if-running, resize ${disk} by ${resize_increment}, start, then verify/repair Windows and Steam"
    fi
    return 0
  fi

  log "VM vmid=${vmid} name=${name}: status=${initial_status}, disk=${disk}, pve_disk=${pve_disk_gb}G, pve_ok_threshold=${pve_ok_gb}G, resize_increment=${resize_increment:-none}"

  if [[ "$initial_status" != "running" && "$initial_status" != "stopped" ]]; then
    die "vmid=${vmid} is in unsupported status '${initial_status}'"
  fi

  # Whether this VM needs the guest agent for Windows work. If so, we run the
  # VM WITHOUT its vGPU so the QEMU guest agent responds reliably, then restore
  # the vGPU at the very end.
  local needs_windows_work="$expand_windows_c"
  local needs_pve_resize=0
  float_lt "$pve_disk_gb" "$pve_ok_gb" && needs_pve_resize=1

  # If neither a resize nor Windows work is needed, there is nothing to do and
  # no reason to touch the VM state or the vGPU.
  if [[ "$needs_pve_resize" -eq 0 && "$needs_windows_work" -eq 0 ]]; then
    log "VM vmid=${vmid}: no Windows work requested and PVE disk already OK"
    set_step "success"
    log "VM vmid=${vmid}: done"
    return 0
  fi

  # Any work below requires the VM to pass through a stopped state, both to
  # resize (safer stopped) and to detach the vGPU. Stop gracefully if running.
  if [[ "$(vm_status "$vmid" || true)" == "running" ]]; then
    set_step "stop"
    log "VM vmid=${vmid}: stopping (gracefully) before resize/vGPU detach"
    graceful_stop_vm "$vmid"
  fi

  if [[ "$needs_pve_resize" -eq 1 ]]; then
    [[ -n "$resize_increment" ]] || die "vmid=${vmid}: PVE disk is below ${pve_ok_gb}G but resize increment was not calculated"
    set_step "pve-resize"
    log "VM vmid=${vmid}: resizing ${disk} by ${resize_increment}"
    qm resize "$vmid" "$disk" "$resize_increment"
    did_pve_resize=1
  else
    log "VM vmid=${vmid}: PVE disk already >= ${pve_ok_gb}G; skipping qm resize"
  fi

  # If no Windows work is needed, we do not need to start the VM at all beyond
  # the resize. Leave it in the state we found it in and finish.
  if [[ "$needs_windows_work" -eq 0 ]]; then
    if [[ "$initial_status" == "running" ]]; then
      set_step "start"
      log "VM vmid=${vmid}: restarting after resize (no Windows work)"
      qm start "$vmid"
      wait_for_status "$vmid" "running" "$start_timeout"
    fi
    set_step "success"
    log "VM vmid=${vmid}: done"
    return 0
  fi

  # ---- Windows work path: run WITHOUT vGPU so the guest agent responds ----

  set_step "vgpu-detach"
  detach_vgpu_if_present "$vmid"

  set_step "start"
  log "VM vmid=${vmid}: starting WITHOUT vGPU for guest-agent work"
  qm start "$vmid"
  wait_for_status "$vmid" "running" "$start_timeout"
  started_now=1

  set_step "guest-agent"
  log "VM vmid=${vmid}: waiting for Windows guest agent (no vGPU attached)"
  wait_for_guest_agent_after_start "$vmid" "$guest_retry_attempts" "$guest_retry_delay"

  set_step "windows-check"
  log "VM vmid=${vmid}: checking Windows disk >= ${windows_ok_gb}G and Steam running"
  check_rc=0
  windows_state_check "$vmid" || check_rc="$?"

  if [[ "$check_rc" -eq 0 ]]; then
    log "VM vmid=${vmid}: Windows disk and Steam already OK"
  else
    if [[ "$check_rc" -ne 2 ]]; then
      die "vmid=${vmid}: Windows check could not complete even without vGPU (rc=${check_rc}); aborting so vGPU is restored"
    fi

    set_step "windows-repair"
    log "VM vmid=${vmid}: repairing Windows C:, tail reserve, and Steam"
    local repair_rc=0
    windows_repair_with_retries "$vmid" || repair_rc="$?"

    # The repair script itself verifies the achievable target: it only reports
    # Success=true (exit 0) when C: is expanded to (max - reserve tail), the
    # tail reserve is correct, and Steam is running. So a 0 here IS the final
    # verification. We do NOT re-check against windows_ok_gb, because the
    # achievable C: size (disk minus system partitions minus reserve tail) is
    # slightly below that threshold and would always fail.
    if [[ "$repair_rc" -eq 0 ]]; then
      log "VM vmid=${vmid}: Windows C: expanded to max (minus ${reserve_tail_gb}G tail), reserve correct, Steam running"
    elif [[ "$repair_rc" -eq 2 ]]; then
      die "vmid=${vmid}: Windows repair ran but did not reach a good state (C:/tail/Steam); see JSON above"
    else
      die "vmid=${vmid}: Windows C:/Steam repair failed at transport level (rc=${repair_rc}) after retries"
    fi
  fi

  # ---- Restore vGPU: stop, re-attach hostpci, start with vGPU ----

  set_step "vgpu-restore-stop"
  log "VM vmid=${vmid}: Windows work done; stopping to re-attach vGPU"
  graceful_stop_vm "$vmid"

  set_step "vgpu-restore"
  restore_vgpu_if_needed "$vmid"

  set_step "start-with-vgpu"
  log "VM vmid=${vmid}: starting WITH vGPU restored"
  qm start "$vmid"
  wait_for_status "$vmid" "running" "$start_timeout"

  set_step "success"
  log "VM vmid=${vmid}: done"
}

run_vm_job() {
  local vmid="$1"
  local name="$2"
  local disk="$3"
  local pve_disk_gb="$4"
  local resize_increment="$5"
  local logfile="$6"
  local statusfile="$7"

  (
    current_step="init"
    trap 'rc=$?; trap - EXIT; if [[ "$rc" -ne 0 ]]; then restore_vgpu_on_failure "$vmid"; fi; printf "%s\t%s\t%s\t%s\t%s\n" "$vmid" "$rc" "$current_step" "$name" "$logfile" > "$statusfile"; exit "$rc"' EXIT
    process_vm "$vmid" "$name" "$disk" "$pve_disk_gb" "$resize_increment"
  ) 2>&1 | while IFS= read -r line; do
    printf '%s [vmid=%s name=%s] %s\n' "$(date '+%F %T')" "$vmid" "$name" "$line" | tee -a "$logfile"
  done
}

rerun_command_for_vmid() {
  local vmid="$1"
  local script_path="${BASH_SOURCE[0]:-$0}"
  local runner
  local cmd

  if [[ -f "$script_path" && "$script_path" != /dev/fd/* && "$script_path" != /proc/* ]]; then
    printf -v runner 'bash %q' "$script_path"
  else
    runner="bash <(curl -fsSL ${script_source_url})"
  fi

  printf -v cmd '%s --only-vmid %q' "$runner" "$vmid"

  if [[ -n "$increment" ]]; then
    cmd="${cmd} --size ${increment}"
  fi
  if [[ "$windows_exec_timeout" != "900" ]]; then
    cmd="${cmd} --windows-exec-timeout ${windows_exec_timeout}"
  fi
  if [[ "$guest_retry_attempts" != "4" ]]; then
    cmd="${cmd} --guest-retry-attempts ${guest_retry_attempts}"
  fi
  if [[ "$guest_retry_delay" != "120" ]]; then
    cmd="${cmd} --guest-retry-delay ${guest_retry_delay}"
  fi
  if [[ "$reserve_tail_gb" != "1" ]]; then
    cmd="${cmd} --reserve-tail-gb ${reserve_tail_gb}"
  fi
  if [[ "$pve_ok_gb" != "119" ]]; then
    cmd="${cmd} --pve-ok-gb ${pve_ok_gb}"
  fi
  if [[ "$windows_ok_gb" != "117.5" ]]; then
    cmd="${cmd} --windows-ok-gb ${windows_ok_gb}"
  fi
  if [[ "$expand_windows_c" -eq 0 ]]; then
    cmd="${cmd} --no-windows-c"
  fi
  if [[ "$skip_space_check" -eq 1 ]]; then
    cmd="${cmd} --skip-space-check"
  fi
  if [[ "$auto_disable_watchdog" -eq 0 ]]; then
    cmd="${cmd} --no-watchdog-disable"
  fi
  if [[ "$manage_vgpu" -eq 0 ]]; then
    cmd="${cmd} --no-vgpu-manage"
  fi

  printf '%s\n' "$cmd"
}

print_result_summary() {
  local failed=0
  local total=0
  local ok=0
  local statusfile vmid rc step name logfile

  log ""
  log "VM result summary:"
  for statusfile in "$log_dir"/*.status; do
    [[ -e "$statusfile" ]] || continue
    IFS=$'\t' read -r vmid rc step name logfile < "$statusfile"
    total=$((total + 1))
    if [[ "$rc" == "0" ]]; then
      ok=$((ok + 1))
      log "  OK   vmid=${vmid} name=${name} step=${step} log=${logfile}"
    else
      failed=1
      log "  FAIL vmid=${vmid} name=${name} step=${step} rc=${rc} log=${logfile}"
      log "       rerun: $(rerun_command_for_vmid "$vmid")"
    fi
  done
  log "Summary: total=${total} ok=${ok} fail=$((total - ok)) logs=${log_dir}"

  [[ "$failed" -eq 0 ]]
}

main() {
  parse_args "$@"
  if [[ "$apply" -eq 1 && "$detach" -eq 1 ]]; then
    launch_detached_and_exit "$@"
  fi

  local vmids=()
  local config name disk vmid
  local storage pve_disk_gb resize_mib resize_increment required_kib
  local selected_vmids=()
  local selected_names=()
  local selected_disks=()
  local selected_pve_gbs=()
  local selected_resize_increments=()
  local resize_storages=()
  local resize_required_kibs=()
  local resized=0
  local skipped=0
  local pve_resize_needed=0
  local failed
  local running_jobs=0

  command -v qm >/dev/null 2>&1 || die "qm command not found; run this on a Proxmox host"

  if [[ "$apply" -eq 0 ]]; then
    log "Mode: dry-run. Nothing will be changed."
  else
    log "Mode: apply. VMs are processed with parallel=${max_parallel}. PVE resize is skipped when disk >= ${pve_ok_gb}G; disks below that are auto-expanded exactly up to the target. Windows is OK when disk/C >= ${windows_ok_gb}G and Steam is running."
    if [[ "$expand_windows_c" -eq 1 ]]; then
      log "Windows C: expansion enabled. Each VM will leave ${reserve_tail_gb} GiB unallocated at the end of the disk, then Steam will be started if needed. Guest agent attempts=${guest_retry_attempts}, delay=${guest_retry_delay}s, windows_exec_timeout=${windows_exec_timeout}s."
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

    if ! pve_disk_gb="$(disk_size_gib_from_config "$config" "$disk")"; then
      log "SKIP vmid=${vmid} name=${name}: unable to detect current Proxmox size for ${disk}"
      skipped=$((skipped + 1))
      continue
    fi

    selected_vmids+=("$vmid")
    selected_names+=("$name")
    selected_disks+=("$disk")
    selected_pve_gbs+=("$pve_disk_gb")
    resize_increment=""
    if float_lt "$pve_disk_gb" "$pve_ok_gb"; then
      if [[ -n "$increment" ]]; then
        resize_increment="$increment"
        required_kib="$(increment_to_kib "$increment")" || die "unable to parse increment ${increment}"
      else
        resize_mib="$(resize_mib_to_target "$pve_disk_gb" "$pve_ok_gb")"
        resize_increment="+${resize_mib}M"
        required_kib=$((resize_mib * 1024))
      fi
      selected_resize_increments+=("$resize_increment")
      resize_storages+=("$storage")
      resize_required_kibs+=("$required_kib")
      pve_resize_needed=$((pve_resize_needed + 1))
    else
      selected_resize_increments+=("")
    fi
    resized=$((resized + 1))
  done

  [[ "${#selected_vmids[@]}" -gt 0 ]] || die "no selected VMs with resizable disks found"

  if [[ "$skip_space_check" -eq 0 && "$pve_resize_needed" -gt 0 ]]; then
    precheck_storage_space resize_storages resize_required_kibs || die "storage precheck failed; not starting VM changes"
  elif [[ "$skip_space_check" -eq 0 ]]; then
    log "Storage precheck: no PVE resize needed; all selected disks are already >= ${pve_ok_gb}G"
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
    pve_disk_gb="${selected_pve_gbs[$idx]}"
    resize_increment="${selected_resize_increments[$idx]}"

    if [[ "$apply" -eq 1 ]]; then
      mkdir -p "${log_dir}"
      run_vm_job "$vmid" "$name" "$disk" "$pve_disk_gb" "$resize_increment" "${log_dir}/${vmid}.log" "${log_dir}/${vmid}.status" &
      running_jobs=$((running_jobs + 1))
      if (( running_jobs >= max_parallel )); then
        wait -n || true
        running_jobs=$((running_jobs - 1))
      fi
    else
      process_vm "$vmid" "$name" "$disk" "$pve_disk_gb" "$resize_increment"
    fi
  done

  if [[ "$apply" -eq 1 ]]; then
    failed=0
    while (( running_jobs > 0 )); do
      if ! wait -n; then
        failed=1
      fi
      running_jobs=$((running_jobs - 1))
    done

    for idx in "${!selected_vmids[@]}"; do
      vmid="${selected_vmids[$idx]}"
      name="${selected_names[$idx]}"
      if [[ ! -s "${log_dir}/${vmid}.status" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$vmid" "missing" "no-status" "$name" "${log_dir}/${vmid}.log" > "${log_dir}/${vmid}.status"
      fi
    done

    if ! print_result_summary; then
      failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
      die "one or more VM resize jobs failed; see VM result summary above and logs in ${log_dir}"
    fi
  fi

  log "Done. planned_or_resized=${resized} skipped=${skipped}"
}

log_dir="/tmp/proxmox-expand-vm-disks.$(date +%Y%m%d-%H%M%S).$$"
main "$@"
