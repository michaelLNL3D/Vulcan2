#!/usr/bin/env bash
set -euo pipefail

ROOT="${PAD7_PREP_ROOT:-/}"
EXECUTE=0
CONFIRM=0
ALLOW_NONROOT="${PAD7_PREP_ALLOW_NONROOT:-0}"

usage() {
  cat <<'EOF'
Usage:
  prep-pad7-distribution.sh --dry-run
  sudo prep-pad7-distribution.sh --execute --yes-i-understand

Prepares a BTT Pad7 / Armbian image for distribution before dd + pishrink.
Dry-run is the default. Wi-Fi profiles are removed last because that can break SSH.
Dry-run works unprivileged but previews only paths you can read — run
`sudo ... --dry-run` for the complete picture.
EOF
}

while (($#)); do
  case "$1" in
    --dry-run)
      EXECUTE=0
      ;;
    --execute)
      EXECUTE=1
      ;;
    --yes-i-understand)
      CONFIRM=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ "$EXECUTE" -eq 1 && "$CONFIRM" -ne 1 ]]; then
  printf 'Refusing to execute without --yes-i-understand.\n' >&2
  exit 2
fi

# Root is only required to EXECUTE against the real filesystem — dry-run just
# reads, so it may run unprivileged (the old check contradicted its own error
# message by rejecting non-root dry-runs too).
if [[ "$EXECUTE" -eq 1 && "$ROOT" == "/" && "$ALLOW_NONROOT" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
  printf 'Run as root for the real Pad7 filesystem, or use --dry-run first.\n' >&2
  exit 1
fi

trim_root() {
  local path="$1"
  path="${path#/}"
  if [[ "$ROOT" == "/" ]]; then
    printf '/%s' "$path"
  else
    printf '%s/%s' "${ROOT%/}" "$path"
  fi
}

exists_glob() {
  local pattern="$1"
  compgen -G "$pattern" >/dev/null
}

log_action() {
  printf '%s\n' "$1"
}

run_cmd() {
  log_action "$*"
  if [[ "$EXECUTE" -eq 1 ]]; then
    "$@"
  fi
}

remove_path() {
  local label="$1"
  shift
  local path
  for path in "$@"; do
    if [[ -e "$path" || -L "$path" ]]; then
      log_action "$label: rm -rf $path"
      if [[ "$EXECUTE" -eq 1 ]]; then
        rm -rf -- "$path"
      fi
    fi
  done
}

remove_glob() {
  local label="$1"
  shift
  local pattern match
  for pattern in "$@"; do
    if exists_glob "$pattern"; then
      for match in $pattern; do
        remove_path "$label" "$match"
      done
    fi
  done
}

clear_dir_contents() {
  local label="$1"
  shift
  local dir
  for dir in "$@"; do
    if [[ -d "$dir" ]]; then
      log_action "$label: clear contents of $dir"
      if [[ "$EXECUTE" -eq 1 ]]; then
        find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
      fi
    fi
  done
}

truncate_file() {
  local label="$1"
  shift
  local path
  for path in "$@"; do
    if [[ -f "$path" ]]; then
      log_action "$label: truncate $path"
      if [[ "$EXECUTE" -eq 1 ]]; then
        : > "$path"
      fi
    fi
  done
}

truncate_glob() {
  local label="$1"
  shift
  local pattern match
  for pattern in "$@"; do
    if exists_glob "$pattern"; then
      for match in $pattern; do
        truncate_file "$label" "$match"
      done
    fi
  done
}

clean_git_tracking() {
  local config_git
  config_git="$(trim_root /home/biqu/printer_data/config/.git)"
  remove_path "remove git tracking" "$config_git"
}

clean_ssh_identity() {
  remove_glob "remove SSH host keys" \
    "$(trim_root '/etc/ssh/ssh_host_*')"

  remove_glob "remove SSH client identity" \
    "$(trim_root '/home/*/.ssh/id_*')" \
    "$(trim_root '/home/*/.ssh/known_hosts*')" \
    "$(trim_root '/home/*/.ssh/authorized_keys*')" \
    "$(trim_root '/root/.ssh/id_*')" \
    "$(trim_root '/root/.ssh/known_hosts*')" \
    "$(trim_root '/root/.ssh/authorized_keys*')"
}

clean_histories() {
  truncate_file "clear shell history" \
    "$(trim_root /root/.bash_history)" \
    "$(trim_root /root/.zsh_history)" \
    "$(trim_root /root/.python_history)"

  truncate_glob "clear shell history" \
    "$(trim_root '/home/*/.bash_history')" \
    "$(trim_root '/home/*/.zsh_history')" \
    "$(trim_root '/home/*/.python_history')"
}

clean_printer_runtime_data() {
  # Per-instance identity only. NOTE: do NOT delete moonraker-sql.db — the
  # Mainsail macro groups (dashboard sections) live inside it, so deleting it
  # wipes them from every clone. Print history is cleared via the Moonraker API
  # in clear_moonraker_history() instead, which preserves the macro-group data.
  remove_path "remove Moonraker instance UUID" \
    "$(trim_root /home/biqu/printer_data/.moonraker.uuid)"

  remove_glob "remove config archive backups" \
    "$(trim_root '/home/biqu/printer_data/config/config-*.zip')"

  # Sweep ALL stray config backups, not just printer.cfg's. Moonraker writes
  # .moonraker.conf.bkp, Update Manager writes *.bak-<branch>-<timestamp>, and
  # Mainsail/editors leave *.bak/*.old/*.save/*~ — enumerating exact names
  # misses them, so glob the whole config dir (including dotfiles).
  remove_glob "remove stray config backups" \
    "$(trim_root '/home/biqu/printer_data/config/*.bak*')" \
    "$(trim_root '/home/biqu/printer_data/config/*.bkp')" \
    "$(trim_root '/home/biqu/printer_data/config/*.old')" \
    "$(trim_root '/home/biqu/printer_data/config/*.save')" \
    "$(trim_root '/home/biqu/printer_data/config/*.orig')" \
    "$(trim_root '/home/biqu/printer_data/config/*~')" \
    "$(trim_root '/home/biqu/printer_data/config/.*.bkp')" \
    "$(trim_root '/home/biqu/printer_data/config/.*.bak*')" \
    "$(trim_root '/home/biqu/printer_data/config/printer-*.cfg')"

  # The macro-groups provisioner and Mainsail/Moonraker drop JSON/config backups
  # here (e.g. mainsail_macros_*.json) — none of it should ship in the image.
  clear_dir_contents "clear printer_data backups" \
    "$(trim_root /home/biqu/printer_data/backup)"

  # Test prints / uploads must not ship: clear gcodes (including .thumbs) and
  # any timelapse output. Found testcode.gcode on the golden unit during prep.
  clear_dir_contents "clear uploaded gcode files" \
    "$(trim_root /home/biqu/printer_data/gcodes)"
  clear_dir_contents "clear timelapse output" \
    "$(trim_root /home/biqu/printer_data/timelapse)"

  truncate_file "clear printer logs" \
    "$(trim_root /home/biqu/printer_data/logs/KlipperScreen.log)" \
    "$(trim_root /home/biqu/printer_data/logs/crowsnest.log)" \
    "$(trim_root /home/biqu/printer_data/logs/klippy.log)" \
    "$(trim_root /home/biqu/printer_data/logs/moonraker.log)"

  remove_glob "remove rotated printer logs" \
    "$(trim_root '/home/biqu/printer_data/logs/*.log.*')"
}

# Clear Moonraker print history + job totals via the API (Moonraker is still
# running during prep). Replaces deleting moonraker-sql.db, so the Mainsail
# macro groups stored in the same DB survive into the distributed image.
clear_moonraker_history() {
  local api="http://localhost:7125"
  if [[ "$ROOT" != "/" ]]; then
    log_action "clear Moonraker history via API (DELETE $api/server/history/*)"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_action "clear Moonraker history: skip (curl not found)"
    return 0
  fi
  log_action "clear Moonraker history: DELETE jobs + POST reset_totals via $api"
  if [[ "$EXECUTE" -eq 1 ]]; then
    # Failures are logged (not silently swallowed): shipping an image with
    # history intact is a real defect that must be visible in the prep output.
    curl -fsS -X DELETE "$api/server/history/job?all=true" >/dev/null 2>&1 \
      || log_action "WARNING: clearing history jobs FAILED (is Moonraker running?)"
    # NOTE: reset_totals is a POST endpoint — DELETE returns 405 Method Not
    # Allowed, and with errors swallowed the totals silently shipped in the
    # image (verified against Moonraker v0.10 on the golden unit).
    curl -fsS -X POST "$api/server/history/reset_totals" >/dev/null 2>&1 \
      || log_action "WARNING: resetting history totals FAILED (is Moonraker running?)"
  fi
}

# Reset per-unit saved runtime variables (IDEX tool offsets, probe trigger
# height, maintenance counters). Klipper recreates the [Variables] section on
# the next SAVE_VARIABLE, so an empty file is the correct shipped state.
reset_saved_variables() {
  truncate_file "reset saved variables (per-unit calibration/stats)" \
    "$(trim_root /home/biqu/printer_data/config/variables.cfg)"
}

# Strip the golden unit's saved bed mesh(es) from printer.cfg's SAVE_CONFIG
# block — bed meshes are unique to each customer's bed and must not ship. PID,
# input_shaper, and probe z_offset are intentionally LEFT as starting points.
strip_per_unit_calibration() {
  local cfg
  cfg="$(trim_root /home/biqu/printer_data/config/printer.cfg)"
  if [[ ! -f "$cfg" ]]; then
    log_action "strip saved bed_mesh: skip (not found: $cfg)"
    return 0
  fi
  if ! grep -q '^#\*# \[bed_mesh' "$cfg"; then
    log_action "strip saved bed_mesh: none present in $cfg"
    return 0
  fi
  log_action "strip saved bed_mesh profiles from $cfg (per-unit calibration)"
  if [[ "$EXECUTE" -eq 1 ]]; then
    awk '
      /^#\*# \[bed_mesh/ { skip=1; next }
      /^#\*# \[/ && skip { skip=0 }
      skip { next }
      { print }
    ' "$cfg" > "$cfg.prep.tmp" && mv "$cfg.prep.tmp" "$cfg"
  fi
}

clean_system_logs_and_caches() {
  truncate_file "clear system logs" \
    "$(trim_root /var/log/alternatives.log)" \
    "$(trim_root /var/log/auth.log)" \
    "$(trim_root /var/log/boot.log)" \
    "$(trim_root /var/log/cron.log)" \
    "$(trim_root /var/log/dpkg.log)" \
    "$(trim_root /var/log/fontconfig.log)" \
    "$(trim_root /var/log/kern.log)" \
    "$(trim_root /var/log/user.log)" \
    "$(trim_root /var/log/Xorg.0.log)" \
    "$(trim_root /var/log/armbian-hardware-monitor.log)" \
    "$(trim_root /var/log/apt/history.log)" \
    "$(trim_root /var/log/apt/term.log)" \
    "$(trim_root /var/log/nginx/access.log)" \
    "$(trim_root /var/log/nginx/error.log)" \
    "$(trim_root /var/log/nginx/mainsail-access.log)" \
    "$(trim_root /var/log/nginx/mainsail-error.log)"

  remove_glob "remove rotated/compressed logs" \
    "$(trim_root '/var/log/*.gz')" \
    "$(trim_root '/var/log/*.1')" \
    "$(trim_root '/var/log/*.[0-9]')" \
    "$(trim_root '/var/log/nginx/*.gz')" \
    "$(trim_root '/var/log/nginx/*.1')" \
    "$(trim_root '/var/log/journal/*')"

  remove_path "remove caches" \
    "$(trim_root /home/biqu/.cache)"

  clear_dir_contents "clear temporary/cache files" \
    "$(trim_root /tmp)" \
    "$(trim_root /var/tmp)" \
    "$(trim_root /var/cache/apt/archives)"

  if [[ "$EXECUTE" -eq 1 ]]; then
    chmod 1777 "$(trim_root /tmp)" "$(trim_root /var/tmp)" 2>/dev/null || true
  fi

  if [[ "$ROOT" == "/" ]]; then
    run_cmd apt-get clean
    run_cmd journalctl --rotate
    run_cmd journalctl --vacuum-time=1s
  else
    log_action "apt-get clean"
    log_action "journalctl --rotate"
    log_action "journalctl --vacuum-time=1s"
  fi
}

reset_machine_identity() {
  local machine_id dbus_id image_release
  machine_id="$(trim_root /etc/machine-id)"
  dbus_id="$(trim_root /var/lib/dbus/machine-id)"
  image_release="$(trim_root /etc/armbian-image-release)"

  if [[ -f "$machine_id" ]]; then
    log_action "reset machine-id: truncate $machine_id"
    if [[ "$EXECUTE" -eq 1 ]]; then
      : > "$machine_id"
    fi
  fi

  if [[ -e "$dbus_id" || -L "$dbus_id" ]]; then
    log_action "reset dbus machine-id: replace $dbus_id with symlink"
    if [[ "$EXECUTE" -eq 1 ]]; then
      rm -f -- "$dbus_id"
      mkdir -p -- "$(dirname "$dbus_id")"
      ln -s /etc/machine-id "$dbus_id"
    fi
  fi

  if [[ -f "$image_release" ]]; then
    log_action "remove cloned Armbian IMAGE_UUID from $image_release"
    if [[ "$EXECUTE" -eq 1 ]]; then
      sed -i '/^IMAGE_UUID=/d' "$image_release"
    fi
  fi
}

reset_autoexpand() {
  remove_path "reset autoexpand guard files" \
    "$(trim_root /root/.no_rootfs_resize)" \
    "$(trim_root /root/.rootfs_resize)"

  if [[ "$ROOT" == "/" ]]; then
    run_cmd systemctl daemon-reload
    log_action "systemctl reset-failed armbian-firstrun.service armbian-resize-filesystem.service || true"
    if [[ "$EXECUTE" -eq 1 ]]; then
      systemctl reset-failed armbian-firstrun.service armbian-resize-filesystem.service || true
    fi
    run_cmd systemctl enable armbian-firstrun.service
    run_cmd systemctl enable armbian-resize-filesystem.service
  else
    log_action "systemctl daemon-reload"
    log_action "systemctl reset-failed armbian-firstrun.service armbian-resize-filesystem.service"
    log_action "systemctl enable armbian-firstrun.service"
    log_action "systemctl enable armbian-resize-filesystem.service"
  fi
}

sync_filesystems() {
  if [[ "$ROOT" == "/" ]]; then
    run_cmd sync
  else
    log_action "sync"
  fi
}

# Re-apply the KlipperScreen network-panel crash fix (idempotent).
# Upstream KlipperScreen's get_ip_for_interface() builds an IPv4Config proxy on
# the active connection's ip4_config even when that path is the null D-Bus
# object "/" (connection still activating / no DHCP lease yet). Reading a
# property off "/" raises "Object does not exist at path /", which crashes the
# whole network panel on a freshly flashed unit that has no saved Wi-Fi. We
# track upstream KlipperScreen directly via Moonraker update_manager, so a
# KlipperScreen update can revert a hand-applied patch; re-applying here at
# image-prep time guarantees every distributed image carries the guard until the
# fix lands upstream. Pure text edit, safe to run repeatedly.
apply_klipperscreen_network_fix() {
  local target
  target="$(trim_root /home/biqu/KlipperScreen/ks_includes/sdbus_nm.py)"
  if [[ ! -f "$target" ]]; then
    log_action "patch KlipperScreen network panel: skip (not found: $target)"
    return 0
  fi
  if grep -q 'active_conn.ip4_config == "/"' "$target"; then
    log_action "patch KlipperScreen network panel: already patched ($target)"
    return 0
  fi
  log_action "patch KlipperScreen network panel: add null-path guard to $target"
  if [[ "$EXECUTE" -eq 1 ]]; then
    python3 - "$target" <<'KSPATCH'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if 'active_conn.ip4_config == "/"' in src:
    sys.exit(0)
OLD = (
    '                if dev_obj.interface == iface:\n'
    '                    ip_info = IPv4Config(active_conn.ip4_config)\n'
)
NEW = (
    '                if dev_obj.interface == iface:\n'
    '                    # A connection still activating (no lease yet) reports the\n'
    '                    # null D-Bus object path "/" for ip4_config; building an\n'
    '                    # IPv4Config proxy on "/" and reading a property raises\n'
    '                    # "Object does not exist at path /" and crashes the network\n'
    '                    # panel. Guard it like get_primary_interface() already does.\n'
    '                    if active_conn.ip4_config == "/":\n'
    '                        return "?"\n'
    '                    ip_info = IPv4Config(active_conn.ip4_config)\n'
)
if OLD not in src:
    sys.stderr.write(
        "WARNING: KlipperScreen sdbus_nm.py changed upstream; network guard NOT applied\n"
    )
    sys.exit(0)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(OLD, NEW, 1))
KSPATCH
  fi
}

# Silence BTT's stock Wi-Fi provisioning boot spam (idempotent).
# /boot/scripts/connect_wifi.sh (run from rc.local via btt_init.sh) only checks
# that a WIFI_SSID line EXISTS in /boot/system.cfg — not that it's non-empty.
# With the shipped WIFI_SSID='' the unquoted nmcli args shift, and the boot
# console shows "No network with SSID 'password' found", "unknown connection
# 'wifi-sec.key-mgmt'", "No connection specified" right before KlipperScreen
# starts (Env_init silences stdout but NOT stderr). Two-line fix: route stderr
# to wifi.log, and exit 0 when WIFI_SSID is empty — KlipperScreen-joined Wi-Fi
# is a NetworkManager profile with autoconnect, so nothing is lost.
apply_wifi_provision_guard() {
  local target
  target="$(trim_root /boot/scripts/connect_wifi.sh)"
  if [[ ! -f "$target" ]]; then
    log_action "patch connect_wifi.sh boot spam: skip (not found: $target)"
    return 0
  fi
  if grep -q 'WIFI_SSID empty; skipping wifi provisioning' "$target"; then
    log_action "patch connect_wifi.sh boot spam: already patched ($target)"
    return 0
  fi
  log_action "patch connect_wifi.sh boot spam: add stderr redirect + empty-SSID guard to $target"
  if [[ "$EXECUTE" -eq 1 ]]; then
    python3 - "$target" <<'WIFIPATCH'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    src = fh.read()
changed = False
STDERR_ANCHOR = "log_file=/boot/scripts/wifi.log"
STDERR_PATCH = (
    STDERR_ANCHOR
    + '\n# LNL3D: route errors to the log, not the boot console (stdout was\n'
    + '# already silenced in Env_init; stderr was not - hence the boot spam).\n'
    + 'exec 2>> "$log_file"\n'
)
if 'exec 2>> "$log_file"' not in src:
    if STDERR_ANCHOR not in src:
        sys.stderr.write("WARNING: connect_wifi.sh changed upstream; stderr redirect NOT applied\n")
        sys.exit(0)
    src = src.replace(STDERR_ANCHOR, STDERR_PATCH, 1)
    changed = True
GUARD_ANCHOR = "source $cfg_file"
GUARD_PATCH = (
    GUARD_ANCHOR
    + '\n# LNL3D: no Wi-Fi configured in system.cfg -> nothing to provision.\n'
    + '# (Empty WIFI_SSID previously shifted nmcli args and spammed the boot\n'
    + '# console. KlipperScreen-joined Wi-Fi reconnects via NetworkManager.)\n'
    + 'if [ -z "${WIFI_SSID}" ]; then\n'
    + '    echo "$(date) ===> WIFI_SSID empty; skipping wifi provisioning" >> "$log_file"\n'
    + '    exit 0\n'
    + 'fi\n'
)
if "WIFI_SSID empty; skipping wifi provisioning" not in src:
    if GUARD_ANCHOR not in src:
        sys.stderr.write("WARNING: connect_wifi.sh changed upstream; empty-SSID guard NOT applied\n")
        sys.exit(0)
    src = src.replace(GUARD_ANCHOR, GUARD_PATCH, 1)
    changed = True
if changed:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)
WIFIPATCH
  fi
}

remove_wifi_last() {
  remove_glob "remove NetworkManager Wi-Fi profiles" \
    "$(trim_root '/etc/NetworkManager/system-connections/*.nmconnection')"

  if [[ "$ROOT" == "/" && -x /usr/bin/nmcli ]]; then
    local uuid type
    while IFS=: read -r uuid type; do
      [[ "$type" == "802-11-wireless" ]] || continue
      log_action "remove NetworkManager Wi-Fi profiles: nmcli connection delete $uuid"
      if [[ "$EXECUTE" -eq 1 ]]; then
        nmcli connection delete "$uuid" >/dev/null 2>&1 || true
      fi
    done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null || true)
  else
    log_action "remove NetworkManager Wi-Fi profiles: nmcli connection delete <wireless profiles>"
  fi
}

main() {
  if [[ "$EXECUTE" -eq 1 ]]; then
    log_action "MODE: execute"
  else
    log_action "MODE: dry-run"
  fi

  clean_git_tracking
  clean_ssh_identity
  clean_histories
  clean_printer_runtime_data
  clear_moonraker_history
  reset_saved_variables
  strip_per_unit_calibration
  clean_system_logs_and_caches
  reset_machine_identity
  reset_autoexpand
  apply_klipperscreen_network_fix
  apply_wifi_provision_guard
  sync_filesystems
  remove_wifi_last
  # Second sync: remove_wifi_last deletes files AFTER the first sync — without
  # this, the very last removals may not be flushed before power-off.
  sync_filesystems
  log_action "complete"
  log_action "NOTE: power off now (poweroff) — /tmp cleanup removed Klipper's"
  log_action "socket/pty, so services must not be reused before the next boot."
}

main "$@"
