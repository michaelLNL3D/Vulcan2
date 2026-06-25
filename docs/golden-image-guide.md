# Vulcan2 Golden Image — Build & Distribution Guide

How to turn a working BTT Pad / CB1 unit (user `biqu`) into a clean, distributable
image. Most of the cleanup is now automated by **`prep-pad7-distribution.sh`**
(canonical copy: `scripts/prep-pad7-distribution.sh` in the **Vulcan2** repo —
internal-only, NOT in `base`, so it never ships to customers).

**The golden rule:** the prep script must be the **last thing** you run before
**power off → image**. Any boot after prep re-runs first-boot logic that
regenerates the identity/Wi-Fi you just wiped.

---

## A. Build the desired state (manual — do FIRST)

- [ ] `base` repo: all changes committed **and pushed**; `git -C ~/printer_data/config/base status` clean and level with `origin/main`. (Customer units pull `base` via update_manager, so the fix must be on origin.)
- [ ] Moonraker **Update Manager** shows every component *valid / up to date* (no "dirty"/"detached").
- [ ] Run the macro-group provisioner (note: **`.py`**, default host `localhost:7125`):
      `python3 ~/printer_data/config/base/scripts/setup_mainsail_macro_groups.py`
      Refresh Mainsail → confirm the 4 sections (Filament / Probe & Calibration / IDEX / Utilities).
- [ ] Set the product **hostname** (no spaces): `sudo hostnamectl set-hostname LNL3D-Vulcan2`, plus `sudo hostnamectl set-hostname 'LNL3D Vulcan 2' --pretty`, update the `127.0.1.1` line in `/etc/hosts`, and set `hostname='LNL3D-Vulcan2'` in `/boot/system.cfg`. Optional Mainsail display name via the `mainsail.general` DB key `printername`.
- [ ] Any other Mainsail UI defaults (theme, temp presets) — set now; they live in the Moonraker DB and clone.

**Calibration policy:** the prep script auto-strips per-unit data (see B). It removes
the saved `[bed_mesh]` from `printer.cfg` and resets `variables.cfg`; it **keeps**
`z_offset`, PID, and input-shaper as starting points. Decide if you also want
`z_offset` zeroed (probe is the sole Z ref — usually re-calibrated per unit).

---

## B. Run the sanitizer (`prep-pad7-distribution.sh`)

**What it automates** (verified via `--dry-run`):
- Removes Moonraker instance UUID; **clears print history via the API** — it does **NOT** delete `moonraker-sql.db`, so the macro groups survive.
- Sweeps **all** stray config backups (`*.bak*`, `*.bkp`, `.moonraker.conf.bkp`, UpdateManager `*.bak-<branch>-<ts>`) and clears `~/printer_data/backup/`.
- Resets `variables.cfg`; strips saved `[bed_mesh]` from `printer.cfg`.
- Wipes SSH host keys + client identity, shell history, machine-id + dbus-id, Armbian IMAGE_UUID.
- Truncates printer + system logs, clears caches/`/tmp`, `apt-get clean`, journal vacuum.
- Re-arms `armbian-firstrun` + `armbian-resize-filesystem` (so clones regenerate identity + auto-expand).
- Removes NetworkManager Wi-Fi profiles **last** (this drops Wi-Fi).

**Run it** (dry-run is the default; `--execute` requires root):
```bash
sudo ~/prep-pad7-distribution.sh --dry-run                       # review first
sudo ~/prep-pad7-distribution.sh --execute --yes-i-understand    # the real run
sudo poweroff                                                    # NEVER reboot
```

**Connection caveat:** the script removes Wi-Fi as its final step, so if you're on
SSH-over-Wi-Fi it will cut your session. Either run it **locally on the Pad**, or
run it **detached** so it finishes + powers off after the link drops:
```bash
sudo bash -c 'nohup bash -c "bash ~/prep-pad7-distribution.sh --execute --yes-i-understand; sync; systemctl poweroff" >/dev/shm/prep.log 2>&1 & sleep 2; tail -f /dev/shm/prep.log'
```

---

## C. NOT covered by the script — verify by hand

- [ ] **`/boot/system.cfg` Wi-Fi (BTT CB1 only):** the script removes NM profiles but **not** the boot-partition creds. Confirm `WIFI_SSID=''` / `WIFI_PASSWD=''`, or the CB1 re-creates the network on next boot:
      `grep -E '^WIFI_' /boot/system.cfg` → blank. (`sed -i "s/^WIFI_SSID=.*/WIFI_SSID=''/; s/^WIFI_PASSWD=.*/WIFI_PASSWD=''/" /boot/system.cfg` if not.)
- [ ] **Confirm nothing else holds the SSID:** `sudo grep -rilE '<your-ssid>' /boot /etc` → after prep, none.
- [ ] **Git credentials** (if you ever pushed from the unit): `rm -f ~/.git-credentials; rm -rf ~/.config/gh` and check `~/.gitconfig` for tokens.
- [ ] `~/printer_data/gcodes/` and `timelapse/` empty (delete test prints/renders).
- [ ] Crontabs (`crontab -l` as biqu + root); timezone/locale set to the shipping default.

---

## D. Capture + shrink the image (`dd` + `pishrink`)

Power the unit **off**, pull the microSD, insert into a **Linux** build machine
(pishrink is Linux-only). ⚠️ Identify the device carefully — a wrong `of=`/`if=`
wipes the wrong disk.

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL          # find the card (usb), e.g. /dev/sdX
sudo dd if=/dev/sdX of=vulcan2-$(date +%Y%m%d).img bs=4M status=progress conv=fsync
sudo pishrink.sh -z vulcan2-*.img           # -> .img.gz, auto-expands on first boot
```

**Flashing a customer card** from the image:
```bash
lsblk                                        # confirm target, e.g. /dev/sdY (NOT your system disk)
zcat vulcan2-*.img.gz | sudo dd of=/dev/sdY bs=4M status=progress conv=fsync && sync
# verify it wrote correctly (want "EOF on -", no "differ"):
zcat vulcan2-*.img.gz | sudo cmp - /dev/sdY
```

**On macOS** (capture/flash works; pishrink does not):
```bash
diskutil list external physical              # find diskN
diskutil unmountDisk /dev/diskN
gunzip -c vulcan2-*.img.gz | sudo dd of=/dev/rdiskN bs=4m   # rdiskN = raw, faster
```

### Flashing gotchas (learned the hard way)
- **`/dev/sdX` is a placeholder** — substitute the real letter from `lsblk`. `dd of=/dev/sdX` to a non-existent device silently writes a *file* (fills RAM/`/dev`, "No space left").
- **Always run long transfers under `tmux`/`screen`** (or `nohup`); an SSH drop kills a bare `dd`/`zcat` mid-write.
- **Flaky USB readers / Pi 3B power:** if `dmesg` shows `hostbyte=0x07` + capacity dropping to 0, the reader/host power is failing (not the card). Use a powered hub, a different reader, or flash from a Mac.
- **Resumable copy** when moving the image between machines: `rsync -P user@host:/path/img.gz ./` (re-run to resume), or `tail -c +$((offset+1))` appended to the partial.

---

## E. Validate a flashed clone (on a second unit)

- [ ] Root filesystem **expanded** to the card (`df -h /` ≈ card size; `armbian-resize-filesystem` ran + disabled)
- [ ] **Fresh identity:** `/etc/machine-id` populated + matches dbus-id; SSH host keys dated first boot
- [ ] **No residual Wi-Fi:** `nmcli connection show` has no shop SSID; `/boot/system.cfg` Wi-Fi blank
- [ ] **Mainsail** shows the 4 macro sections; **history empty**; **Update Manager green**
- [ ] `base` clean, on `main`, level with `origin`; filament sensors read correctly (`QUERY_FILAMENT_SENSOR SENSOR=e1_runout` → "detected" with filament present)

---

## Reference: what clones where

| State | Lives in | Ships to customer? |
|---|---|---|
| Macros & hardware config | `base` repo (git, via update_manager) | ✅ image + future pulls |
| Macro sections / UI layout / printer name | Moonraker DB (`mainsail` namespace) | ✅ baked in (prep preserves the DB) |
| Internal prep/build tooling | `Vulcan2` parent repo `scripts/` | ❌ never deployed to units |
| Print/console history | Moonraker DB | ❌ prep clears via API |
| Calibration: bed mesh, `variables.cfg` | `printer.cfg` SAVE_CONFIG / `variables.cfg` | ❌ prep strips/resets |
| Wi-Fi (NM + `/boot/system.cfg`), SSH, machine-id, git creds | OS files | ❌ prep (NM/SSH/machine-id) + manual (`system.cfg`, git creds) |
