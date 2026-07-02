# USB Boot G-code — Import G-code from a USB drive on offline printers

**Date:** 2026-06-17
**Ticket:** "USB Boot gcode" — add gcode through USB. For offline devices that
people don't want on a network, allow option to load through a usb drive
plugged in.
**Repo:** Vulcan2 (Klipper config). Feature ships inside the `base` submodule.

## Problem

A networked printer receives sliced files via Moonraker's HTTP upload
(Mainsail/Fluidd). An air-gapped printer has no such path: the only way in is
physical media. Klipper G-code macros are sandboxed and cannot touch the host
filesystem, so importing files from a USB drive requires a host-side bridge.

## Goal

Let a touchscreen operator plug in a USB drive, tap one button on
KlipperScreen, and have the drive's G-code files copied into the printer's
existing G-code library where every UI already looks for them.

## Confirmed decisions

| Decision | Choice | Rationale |
|---|---|---|
| Trigger | Manual button (no auto-mount daemon) | Explicit, predictable, no background root scripts |
| File handling | Copy `.gcode/.gco/.g` (recursive, case-insensitive) into `~/printer_data/gcodes/USB/` | Tidy, non-destructive, persists after eject, no name collisions with local files |
| Source media | Mounted **read-only** | The stick may hold the customer's only copy of a file; never modify it |
| UI surface | KlipperScreen touchscreen only (`__main utilities` submenu) | Primary interface for an offline printer; the bare macro stays console-runnable too |
| Mount approach | **Hybrid**: use an already-mounted drive if present, else self-mount via a narrow sudoers rule | Robust across images. On the CB1 image (no auto-mount) it always self-mounts |
| During a print | **Blocked** — refuse if `print_stats.state == "printing"` | Avoid surprise disk I/O / operator confusion mid-print |
| Provisioning | Installer run **once on the golden image**; sudoers rule written by default | Whole-fleet setup collapses to one step captured in the cloned image |

## Live environment (verified on 192.168.1.205)

- OS: BIGTREETECH-CB1, Debian *trixie* (Armbian). User `biqu`, host `bigtreetech-cb1`.
- **No auto-mount machinery**: `usbmount`, `udisks2`, `udisksctl`, `pmount` all
  absent. `/media`, `/mnt` empty. Only `systemd-mount` binary present.
  → A plugged USB stick does **not** auto-mount; the sudoers self-mount path is
  mandatory on this image.
- `sudo` works with password; `/etc/sudoers.d` writable via sudo.
- Binaries: `/usr/bin/{mount,umount,lsblk,findmnt}` present.
- Services: `klipper.service`, `moonraker.service`, `KlipperScreen.service` running.
- `~/klipper/klippy/extras/` exists; `gcode_shell_command.py` **not** installed.
- `~/printer_data/gcodes/` exists, owned by `biqu`.

## Architecture

```
KlipperScreen menu tap
   └─ printer.gcode.script  ->  USB_IMPORT  (gcode_macro)
         └─ RUN_SHELL_COMMAND CMD=usb_import   (gcode_shell_command extra)
               └─ base/scripts/usb_import.sh   (host script)
                     ├─ find a mounted drive with gcode files, OR
                     ├─ sudo mount -o ro /dev/sdXN  /tmp/usb_import
                     ├─ copy *.gcode/.gco/.g  ->  ~/printer_data/gcodes/USB/
                     └─ umount + cleanup (always)
         └─ macro reads script summary -> touchscreen action:prompt + console echo
```

### The bridge: `gcode_shell_command`

Klipper macros cannot run host commands. The community `gcode_shell_command.py`
extra adds a `[gcode_shell_command <name>]` config section and a
`RUN_SHELL_COMMAND CMD=<name>` G-code command. We vendor this single file in the
repo and install it into `~/klipper/klippy/extras/`.

### Deployment safety — avoid a fleet-wide config brick

An unknown config section is a **fatal** Klipper config-load error. If the
`[gcode_shell_command usb_import]` section were placed in the auto-globbed
`base/macros/*.cfg`, every printer that pulls the `base` update *before* the
extra is installed would fail to start Klipper entirely.

Therefore the activation config that references the extra is kept **out** of the
auto-included path and installed per-image into `~/printer_data/config/local/`,
which `printer.cfg` already includes via `[include local/*.cfg]`. Printers
without the activation (and the extra) are completely unaffected.

Ordering the installer enforces on the golden image:
1. Copy the extra into `~/klipper/klippy/extras/`.
2. Write the sudoers rule.
3. Symlink the activation config into `local/`.
4. Restart `klipper` and `KlipperScreen`.

(The extra must exist before the config that references it is loaded.)

## Components

| Path (in repo `base/`) | Purpose | Loaded by Klipper? |
|---|---|---|
| `scripts/usb_import.sh` | Host script: locate/mount USB (RO), copy gcode → `gcodes/USB/`, unmount, print one-line summary | No — plain script |
| `scripts/gcode_shell_command.py` | Vendored Klipper extra (the bridge) | Installed into `~/klipper/klippy/extras/` |
| `optional/usb_import.cfg` | `[gcode_shell_command usb_import]` + `[gcode_macro USB_IMPORT]` wrapper | Only via `local/` symlink (opt-in) |
| `scripts/install_usb_import.sh` | One-time golden-image installer (copy extra, write sudoers, symlink activation, restart services). Idempotent | n/a |
| `Klipperscreen_LNL.conf` (edit) | Add `[menu __main utilities usbimport]` → `printer.gcode.script` `USB_IMPORT` | Yes (existing file) |
| `scripts/gcode_shell_command.LICENSE` | License/attribution for the vendored extra | n/a |

### `usb_import.sh` behavior (host script)

Inputs: none (or optional `DEST` / `SRC` env overrides for testing).
Output: a single final line to stdout the macro can surface, e.g.
`USB_IMPORT_RESULT: imported=N skipped=M source=<path>` or
`USB_IMPORT_RESULT: no_drive` or `USB_IMPORT_RESULT: error=<reason>`.

Steps:
1. `set -euo pipefail`; define `DEST=~/printer_data/gcodes/USB`, `MNT=/tmp/usb_import`.
2. `trap` cleanup: `umount` `MNT` if we mounted it, remove temp dir — runs on any exit.
3. **Find an already-mounted drive:** scan `/media/*`, `/media/*/*`,
   `/run/media/*/*`, `/mnt/*` for a path that is a mountpoint (`findmnt`) and
   contains ≥1 file matching `-iname '*.gcode' -o -iname '*.gco' -o -iname '*.g'`.
   If found, set `SRC` to it; skip mounting.
4. **Else self-mount:** pick the first removable partition from
   `lsblk -rno NAME,RM,TYPE` where `RM=1` and `TYPE=part`; build `/dev/<name>`;
   `mkdir -p "$MNT"`; `sudo mount -o ro "/dev/<name>" "$MNT"`; set `SRC=$MNT`.
   If no removable partition exists → print `no_drive`, exit 0.
5. **Copy:** `mkdir -p "$DEST"`; for each matching file under `SRC`, `cp` into
   `DEST` (flatten basename; later same-name copy overwrites the prior USB/
   copy only). Count imported vs. skipped/failed.
6. Print the `USB_IMPORT_RESULT:` summary line; exit 0 on success, non-zero on
   hard error. Cleanup runs via trap.

### `USB_IMPORT` macro (`optional/usb_import.cfg`)

- `description`: "Import G-code files from a plugged-in USB drive".
- Guard: if `printer.print_stats.state == "printing"` → show a "blocked during
  print" `action:prompt` popup + console echo, do nothing.
- Else: `RUN_SHELL_COMMAND CMD=usb_import` (the extra streams the script's
  stdout to the console). A companion `[gcode_shell_command usb_import]` sets
  `command:`, `timeout:` (e.g. 120s), and `verbose: True`.
- Dual feedback matching the existing `_SAFETY_STOP` pattern: `RESPOND TYPE=echo`
  for console + `action:prompt_begin/_text/_footer_button/_show` for the
  touchscreen so a touchscreen-only operator sees the result.
- Result detail: because the extra runs asynchronously and the macro template
  renders before the command runs, the human-readable popup is emitted by a
  small `_USB_IMPORT_DONE` notify command the script's output triggers, OR the
  macro shows a generic "Import started — see console" popup and the script's
  streamed lines carry the count. (Implementation plan picks the cleaner of the
  two; both are acceptable. The async-vs-render constraint is the same one
  documented for `_PROBE_VERIFY`/`_SAFETY_RAISE` in `_host_deps.cfg`.)

### KlipperScreen menu entry

Add under the existing `[menu __main utilities]` block in `Klipperscreen_LNL.conf`:

```
[menu __main utilities usbimport]
name: Import from USB
method: printer.gcode.script
params: {"script":"USB_IMPORT"}
```

Note: this entry ships in `base` and is therefore present on all printers. On a
printer without the activation config, tapping it produces a harmless
"Unknown command USB_IMPORT" runtime error (not a config brick). Accepted
trade-off; the alternative (installer-injected menu) is rejected as
disproportionate complexity.

### `install_usb_import.sh` (golden-image installer)

Idempotent; run once over SSH or the touchscreen terminal on the golden image.
Resolves paths relative to its own location so it works from `base/scripts/`.

1. `cp base/scripts/gcode_shell_command.py ~/klipper/klippy/extras/` (skip if identical).
2. Write `/etc/sudoers.d/usb-import` (mode 0440, via `sudo tee` + `visudo -c`):
   ```
   biqu ALL=(root) NOPASSWD: /usr/bin/mount -o ro /dev/sd* /tmp/usb_import, /usr/bin/umount /tmp/usb_import
   ```
3. `mkdir -p ~/printer_data/config/local` and symlink
   `~/printer_data/config/base/optional/usb_import.cfg` →
   `~/printer_data/config/local/usb_import.cfg`.
4. `chmod +x base/scripts/usb_import.sh`.
5. `sudo systemctl restart klipper KlipperScreen` (KlipperScreen restart is
   needed for the new menu entry; note moonraker.conf's warning about racing the
   websocket — restart KlipperScreen explicitly, last).
6. Print a clear success/next-steps summary.

## Security

- Mount is **read-only** and the sudoers rule is locked to:
  `mount -o ro`, a `/dev/sd*` device, and the single fixed mountpoint
  `/tmp/usb_import` — it cannot be repurposed to mount arbitrary devices or
  paths, and cannot write to the stick.
- `umount` is likewise locked to `/tmp/usb_import`.
- Filenames from the stick are handled as data (no `eval`, quoted expansions,
  `find -print0`/`while read -d ''`); copy only by extension all-list.
- The vendored extra runs host shell — this is inherent to the feature; it is
  gated behind a deliberate per-image install and is otherwise dormant.

## Error handling

| Condition | Behavior |
|---|---|
| No drive / no gcode files | `no_drive` summary, friendly popup, no raised error |
| Removable device but mount fails (no sudoers / bad FS) | `error=mount` summary, popup hinting setup may be incomplete, non-zero exit |
| Print in progress | Macro refuses up front; script never runs |
| Drive yanked mid-copy | `trap` unmounts/cleans up; partial count reported |
| Re-import same file | Overwrites only the `USB/` copy; local library untouched |

## Testing

Driven on the live CB1 (`192.168.1.205`) over SSH plus touchscreen checks:

- **Host script (`usb_import.sh`)**, with a real stick:
  - no drive inserted → `no_drive`, exit 0;
  - stick with gcode files → files appear in `gcodes/USB/`, correct count;
  - stick with mixed content → only gcode extensions copied;
  - re-import → overwrites USB/ copy, no duplicates;
  - eject mid-run → cleanup leaves no stale mount (`findmnt /tmp/usb_import` empty).
- **Macro/menu:** tap "Import from USB" in KlipperScreen → popup shows result;
  files visible in the file list under `USB/`.
- **Block-during-print:** start a (dummy) print state → tap import → refused popup.
- **Config-load safety:** a printer/config **without** the `local/` activation
  loads Klipper cleanly (no `gcode_shell_command` section error).
- **Installer idempotency:** run `install_usb_import.sh` twice → second run is a
  no-op, `visudo -c` passes, symlink intact.

## Out of scope (YAGNI)

- Auto-mount-on-insert (udev) — explicitly deferred; manual button chosen.
- Mainsail macro-group registration — touchscreen-only chosen.
- Mirroring/deleting on the USB or in `USB/` — non-destructive copy only.
- Printing directly off the USB device (re-pointing virtual_sdcard).
- Exporting/copying files *to* the USB.

## Open implementation choices (deferred to the plan, both acceptable)

- Exact mechanism for the touchscreen result popup (script-triggered notify
  command vs. generic "started" popup + streamed console count), given the
  macro-render-before-command async constraint.
- Whether to also accept `.gz`-wrapped gcode (`.gcode.gz`) — default: no.
