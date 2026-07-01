# Klicky/Euclid Home-Dock Pickup & Probe-Sensed Dropoff — Design

- **Date:** 2026-07-01
- **Status:** Approved (design)
- **Repo:** `Vulcan2` (parent) + `base` submodule (`Vulcan2-UpdateManagerConfig`)
- **Ticket:** "Klicky Pick up and Drop off Routine"

## 1. Problem / Ticket

The printer is an **IDEX, Y bed-slinger, Cartesian** machine. Its probe is a
magnetic dockable probe (labelled **Euclid** in the code, "klicky-style" in the
comments) and is the machine's **only Z reference** (`[stepper_z]`
`endstop_pin: probe:z_virtual_endstop`). Z cannot home without the probe
attached.

The ticket asks to:

1. Confirm whether a pickup/dropoff routine exists for the probe.
2. Make the routine match the real mechanical procedure:
   - **Pickup** = home X on the probe-carrying toolhead (the dock sits at that
     toolhead's X-home).
   - **Dropoff** = home X, then descend Z until a blocker on the vertical
     extrusion is sensed, then slide the toolhead `+X` to strip the probe off.
3. Confirm KlipperScreen exposes accessible pickup/dock buttons.

## 2. Current State (as found)

- `PROBE_PICKUP` and `PROBE_DROPOFF` **already exist** in
  `base/EuclidUtilities.cfg`, **but** they drive the active carriage to
  **absolute calibrated coordinates** (`probe_pickup_xpos/ypos/zpos` in the
  `LNLOS` holder, `base/macros/_host_deps.cfg`). Those values are all `0`, so
  the macros are guarded to abort with "dock not calibrated." This is **not**
  the home-X / blocker-sense mechanism the ticket describes.
- `PROBE_PICKUP` also calls `HOME_IF_NOT` (a full `G28`) **before** the probe is
  attached — a latent chicken-and-egg bug, since Z can't home without the probe.
- **KlipperScreen already has buttons:** `base/Klipperscreen_LNL.conf`,
  **Calibration → Probe Pickup / Probe Dropoff**, wired to the macro names.
- Only these two macros read `probe_pickup_xpos/ypos/zpos`, so those variables
  can be safely retired. `PROBE_PICKUP`/`PROBE_DROPOFF` are also called by
  `_Prepare_BedMesh` and `_AUTO_PROBE` (unchanged — they call by name).
- `PRINT_START` does **not** call these macros (it uses `ASSERT_PROBE_DOCKED`),
  so the blast radius is limited to the dock macros themselves.

### Relevant machine facts

| Fact | Value | Source |
|---|---|---|
| Probe carriage | carriage 0 (`T0`, "E1", `extruder`, leftmost) | `idex.cfg`, confirmed by user |
| X home (dock) | `position_endstop: -54` (homes `-X`) | `vulcan2.cfg [stepper_x]` |
| X range | `position_min: -55`, `position_max: 305` | `vulcan2.cfg [stepper_x]` |
| Second carriage | `[dual_carriage]`, homes `+X` to `354`, `safe_distance: 50` | `vulcan2.cfg` |
| Z reference | probe `z_virtual_endstop`; `[probe] z_offset: 8.5` defines Z=0 | `HC32F460.cfg`, `EuclidProbe.cfg` |
| Z range | `position_min: -9.0`, `position_max: 350` | `vulcan2.cfg [stepper_z]` |
| Probe wiring | **NC**: attached+idle ⇒ `last_query` False; detached/pressed ⇒ True | `HC32F460.cfg` |

## 3. Mechanical Model (why the design is shaped this way)

Two reference frames:

- The **probe dock** is mounted on the **moving X gantry** — it is Y/Z-locked to
  the toolhead. Homing X always aligns the toolhead to the dock regardless of
  where the gantry sits. → **Pickup is a pure "home X"; Y is never involved.**
- The **blocker** is mounted on the **static extrusion** the gantry rides on.
  The gantry's Z relative to the static blocker is **not fixed** run-to-run.
  → **The blocker's contact height must be sensed live** (not hardcoded).

Both the sense point (`X=-26`) and the release end point (`X=-4`) are **left of
the bed's print area** (bed ≈ X `0..305`), so the probe descends over the
gantry-mounted dock / static blocker, never over the bed — Y is irrelevant and
there is no bed-collision path.

## 4. Design

### 4.1 Configuration — `LNLOS` (`base/macros/_host_deps.cfg`)

Retire `probe_pickup_xpos`, `probe_pickup_ypos`, `probe_pickup_zpos`. Replace
with intent-named, endstop-relative variables (keep `probe_pickup_zraise`):

```ini
# Euclid/Klicky home-dock geometry (consumed by EuclidUtilities.cfg).
# The dock sits at the E1 (carriage 0) X endstop; PICKUP = home X.
# Sense/release are +X OFFSETS from that endstop so they track
# [stepper_x] position_endstop automatically. Y is irrelevant (bed-slinger;
# dock is off the left edge of the bed).
variable_probe_dock_sense_xoffset: 28   # +X from endstop to sense the blocker -> X=-26
variable_probe_dock_release:        50   # +X from endstop to strip the probe   -> X=-4
variable_probe_dock_zoffset:         0   # optional engagement-Z fine-tune (0 = use sensed height)
variable_probe_pickup_zraise:       15   # safe travel Z before/after dock moves (kept)
```

Dock/home X is read live from
`printer.configfile.settings.stepper_x.position_endstop` (`-54`) — never
hardcoded.

### 4.2 `PROBE_PICKUP` (probe NOT attached — X-only, never full-homes)

1. **Guard:** refuse if `printer["gcode_macro _IDEX_MODE"].idex_mode != 0`
   (copy/mirror) — independently homing one coupled carriage would crash.
2. `SET_DUAL_CARRIAGE CARRIAGE=0`
3. `G28 X` → carriage 0 drives to endstop `-54`; magnets grab the probe.
4. `PROBEON` → `QUERY_PROBE` + verify **attached**; aborts with a clear message
   on failure.

Deliberately **no full `G28`** (Z can't home yet). Leaves the toolhead at the
dock with the probe attached; the user then homes/prints normally.

### 4.3 `PROBE_DROPOFF` (probe IS attached — 8-step sense-and-strip)

Guards first: refuse if copy/mirror; `QUERY_PROBE` verify probe **attached**
(a detached NC probe reads TRIGGERED and would corrupt the `PROBE` move);
`HOME_IF_NOT` (full `G28` — safe here, probe attached; homes Z at bed centre).

| # | Intent | G-code |
|---|---|---|
| 1 | home X (dock ref) | `SET_DUAL_CARRIAGE CARRIAGE=0` → `G28 X` (→ **-54**) |
| 2 | lift | `G1 Z{zraise}` |
| 3 | move to sense X | `G1 X{endstop + sense_xoffset}` (→ **-26**) |
| 4 | sense blocker | `PROBE` → `printer.probe.last_z_result` = blocking height |
| 5 | lift clear of blocker | `G1 Z{zraise}` |
| 6 | back to home X | `G1 X{endstop}` (→ **-54**) |
| 7 | descend to engagement Z | `G1 Z{last_z_result + zoffset}` (clamped ≥ `position_min`) |
| 8 | strip probe | `G1 X{endstop + release}` (→ **-4**, passing the blocker at -26) |
| — | finish | `G1 Z{zraise}` → `PROBEOFF` (verify **docked**) |

**No re-home after step 8** — homing X would drive the toolhead back through the
dock and risk knocking the just-parked probe. Motion stays homed; final X (`-4`)
is a known position.

### 4.4 Two-stage QUERY pattern (Klipper gotcha, reused not reinvented)

A `gcode_macro` template renders fully **before** any command runs, so reading
`printer.probe.last_query` in the same macro as `QUERY_PROBE` sees the *previous*
query. The existing `PROBEON`/`PROBEOFF` → `_PROBE_VERIFY` split (in
`_host_deps.cfg`) already handles this and is reused verbatim. The
probe-attached pre-check in `PROBE_DROPOFF` uses the same split.

### 4.5 No-contact / safety guards

- **Copy/mirror refusal** on both macros.
- **Probe-attached pre-check** before any `PROBE` in dropoff.
- **Engagement-Z clamp** to `≥ position_min` (`-9`).
- **No-contact:** `PROBE` descending with no blocker present runs to
  `position_min` and Klipper raises "Probe … not triggered". Surface a friendly
  "dock surface not found — check the blocker / `probe_dock_sense_xoffset`"
  message.

## 5. KlipperScreen (ticket Q3)

**No change required.** The **Calibration → Probe Pickup / Probe Dropoff**
buttons in `base/Klipperscreen_LNL.conf` already call `PROBE_PICKUP` /
`PROBE_DROPOFF` and inherit the new behaviour automatically.

## 6. Files Touched

- `base/EuclidUtilities.cfg` — rewrite `PROBE_PICKUP` and `PROBE_DROPOFF`
  internals (keep names). Remove the obsolete "dock not calibrated" guard.
- `base/macros/_host_deps.cfg` — swap the `LNLOS` dock variables.
- **No** change to `Klipperscreen_LNL.conf`, `PrintStartEnd.cfg`,
  `EuclidProbe.cfg`, `idex.cfg`.

### Repo mechanics

The macros live in the **`base` submodule** (`Vulcan2-UpdateManagerConfig`),
currently in detached HEAD at `23f114e`. Implementation:

1. In `base/`: branch, edit, commit to the submodule repo.
2. In the parent: bump the submodule pointer (repo provides
   `scripts/bump-base.sh` for an atomic, verified bump) and commit.

This design doc lives in the **parent** repo (`docs/superpowers/specs/`).

## 7. Validation

Klipper macros are not unit-testable offline. Validation is:

1. **Config self-consistency review** — object references
   (`_IDEX_MODE.idex_mode`, `probe.last_z_result`, `stepper_x.position_endstop`),
   variable names, and range arithmetic (`-54 + 28 = -26`, `-54 + 50 = -4`,
   both within `[-55, 305]`).
2. **Diff review** at the git level.
3. **Hardware dry-run by the operator**, in order, with a hand on the E-stop:
   - Pickup first (cheap, X-only): confirm the probe attaches and `PROBEON`
     passes.
   - Dropoff: confirm the `PROBE` senses the blocker at a sane Z, that the lift
     between sense and strip clears the blocker, and that `PROBEOFF` confirms
     detachment. Tune `probe_dock_sense_xoffset` / `probe_dock_zoffset` /
     `probe_dock_release` as needed.

## 8. Risks / Notes

- **Wrong sense offset** → probe descends where there is no blocker; caught by
  the no-contact guard (Klipper error), not a crash.
- **Engagement Z too low** → clamped to `position_min`; `probe_dock_zoffset`
  lets the operator raise it.
- **Probe not actually attached at dropoff** → pre-check aborts before any
  descend.
- Defaults (`28`, `50`, `0`, `15`) are operator estimates; they are calibratable
  and expected to be tuned on first hardware run.
