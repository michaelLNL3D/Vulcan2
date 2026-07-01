# Klicky/Euclid Home-Dock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the coordinate-based `PROBE_PICKUP`/`PROBE_DROPOFF` internals with a home-X pickup and an 8-step probe-sensed dropoff (sense the static blocker at X=-26, strip the probe with a +X slide to X=-4).

**Architecture:** Two Klipper `gcode_macro`s in the `base` submodule. Pickup homes carriage 0's X (dock is at its `-54` endstop). Dropoff is split into three render stages (`PROBE_DROPOFF` → `_PROBE_DROPOFF_SENSE` → `_PROBE_DROPOFF_STRIP`) so the live `PROBE` result (`printer.probe.last_z_result`) is read in a macro that renders *after* the probe move ran — Klipper renders a macro's whole template before any of its commands execute.

**Tech Stack:** Klipper `gcode_macro` (Jinja2 templates), KlipperScreen (unchanged), git submodule (`base` → `Vulcan2-UpdateManagerConfig`).

## Global Constraints

- Probe carriage is **carriage 0** (`SET_DUAL_CARRIAGE CARRIAGE=0`; `T0`/"E1"/`extruder`), homes `-X` to `position_endstop: -54`.
- Dock/home X is read live from `printer.configfile.settings.stepper_x.position_endstop` — **never hardcode -54**.
- Sense point = endstop `+ probe_dock_sense_xoffset` (28 → **-26**); release = endstop `+ probe_dock_release` (50 → **-4**). Both within `[stepper_x]` range `[-55, 305]`.
- NC probe wiring: **attached & idle ⇒ `printer.probe.last_query` False**; detached/pressed ⇒ True.
- No Y move anywhere (Y bed-slinger; dock/blocker off the bed's left edge).
- Reuse existing helpers verbatim: `_SAFETY_STOP`, `HOME_IF_NOT`, `PROBEON`, `PROBEOFF`, custom `G28`. Do not reimplement them.
- There is **no offline Klipper test harness**; verification is grep/Jinja-balance checks plus an operator hardware dry-run (Task 3).
- Commit inside `base/` first; bump the parent pointer separately. **Do not push** unless the user asks.

## File Structure

- `base/macros/_host_deps.cfg` — `LNLOS` holder: swap the four dock variables. One responsibility: settings values.
- `base/EuclidUtilities.cfg` — rewrite `PROBE_PICKUP` + `PROBE_DROPOFF`, add two internal stage macros. One responsibility: probe dock motion.
- `base/Klipperscreen_LNL.conf` — **unchanged** (buttons already call these names).
- Parent repo — submodule pointer bump commit only.

---

### Task 1: Rewrite dock variables + pickup/dropoff macros (single `base/` commit)

Both files change together so every commit is a config that loads *and* is internally consistent (the old macros reference the variables we remove).

**Files:**
- Modify: `base/macros/_host_deps.cfg:19-23`
- Modify: `base/EuclidUtilities.cfg:111-157`

**Interfaces:**
- Consumes: `_SAFETY_STOP`, `HOME_IF_NOT`, `PROBEON`, `PROBEOFF` (`_host_deps.cfg`); `SET_DUAL_CARRIAGE`, `PROBE`, `QUERY_PROBE`, custom `G28` (Klipper / `EuclidUtilities.cfg`); `printer.configfile.settings.stepper_x.position_endstop`, `printer.configfile.settings.stepper_z.position_min`, `printer.probe.last_query`, `printer.probe.last_z_result`, `printer["gcode_macro _IDEX_MODE"].idex_mode`.
- Produces: macros `PROBE_PICKUP`, `PROBE_DROPOFF` (names unchanged; still called by KlipperScreen, `_Prepare_BedMesh`, `_AUTO_PROBE`) and internal `_PROBE_DROPOFF_SENSE`, `_PROBE_DROPOFF_STRIP`. `LNLOS` variables `probe_dock_sense_xoffset`, `probe_dock_release`, `probe_dock_zoffset`, `probe_pickup_zraise`.

- [ ] **Step 1: Branch the submodule** (currently detached HEAD)

Run:
```bash
cd base && git checkout -b klicky-home-dock && cd ..
```
Expected: `Switched to a new branch 'klicky-home-dock'`

- [ ] **Step 2: Swap the `LNLOS` dock variables**

In `base/macros/_host_deps.cfg`, replace lines 19-23:
```ini
# Euclid probe dock pickup/dropoff position (consumed by EuclidUtilities.cfg):
variable_probe_pickup_xpos: 0       # <-- SET ME: X of probe dock
variable_probe_pickup_ypos: 0       # <-- SET ME: Y of probe dock
variable_probe_pickup_zpos: 0       # <-- SET ME: Z at which probe attaches/detaches
variable_probe_pickup_zraise: 15    # safe Z travel height before/after dock moves
```
with:
```ini
# Euclid/Klicky home-dock geometry (consumed by EuclidUtilities.cfg).
# The dock rides on the moving gantry at the E1 (carriage 0) X endstop, so
# PICKUP = home X. Sense/release are +X OFFSETS from that endstop (read live
# from [stepper_x] position_endstop) so they track the config automatically.
# Y is irrelevant: Y bed-slinger; the dock/blocker sit off the bed's left edge.
variable_probe_dock_sense_xoffset: 28   # +X from endstop to sense the blocker (-> X=-26)
variable_probe_dock_release: 50         # +X from endstop to strip the probe   (-> X=-4)
variable_probe_dock_zoffset: 0          # optional engagement-Z fine-tune (0 = use sensed height)
variable_probe_pickup_zraise: 15        # safe Z travel height before/after dock moves
```

- [ ] **Step 3: Rewrite the two macros**

In `base/EuclidUtilities.cfg`, replace the whole block lines 111-157 (from `#home printer and equip probe` through the end of `PROBE_DROPOFF`) with:
```ini
#home X on carriage 0 to pick up the probe at the dock (dock sits at the X endstop)
[gcode_macro PROBE_PICKUP]
description: Fetch the Euclid probe by homing X on carriage 0 (dock is at its X endstop)
gcode:
  # Copy/mirror couple the two carriages — independently homing one would crash.
  {% if printer["gcode_macro _IDEX_MODE"].idex_mode != 0 %}
    _SAFETY_STOP MSG="PROBE GUARD: wrong IDEX mode" DETAIL="Switch back to dual material mode before using the probe dock (copy/mirror couple the carriages)."
  {% endif %}
  # X-only: the probe is NOT attached yet, so a full G28 (Z needs the probe)
  # would fail. Homing carriage 0's X drives it into the dock; magnets grab it.
  SET_DUAL_CARRIAGE CARRIAGE=0
  G28 X
  PROBEON

#dock the probe: home X, probe-sense the static blocker, slide +X to strip it off
[gcode_macro PROBE_DROPOFF]
description: Dock the Euclid probe: home X, sense the blocker height, slide the carriage off it
gcode:
  {% if printer["gcode_macro _IDEX_MODE"].idex_mode != 0 %}
    _SAFETY_STOP MSG="PROBE GUARD: wrong IDEX mode" DETAIL="Switch back to dual material mode before using the probe dock (copy/mirror couple the carriages)."
  {% endif %}
  # Verify the probe is attached before probing with it. The fresh query must be
  # READ in the next macro (a template renders fully before its commands run).
  QUERY_PROBE
  _PROBE_DROPOFF_SENSE

[gcode_macro _PROBE_DROPOFF_SENSE]
description: Internal — verify probe attached, home X, then probe down onto the blocker
gcode:
  # NC wiring: attached & idle => last_query False. TRIGGERED = detached/fault.
  {% if printer.probe.last_query %}
    _SAFETY_STOP MSG="PROBE GUARD: no probe to dock" DETAIL="Probe reads detached/triggered - nothing to dock. Run PROBE_PICKUP first, or check the probe wiring."
  {% endif %}
  {% set endstop = printer.configfile.settings.stepper_x.position_endstop|float %}
  {% set lnl = printer["gcode_macro LNLOS"] %}
  {% set sense_x = endstop + lnl.probe_dock_sense_xoffset|float %}
  {% set zraise = lnl.probe_pickup_zraise|float %}
  # Full home is safe here (probe attached) and gives PROBE a valid Z reference.
  HOME_IF_NOT
  G90
  # 1: home X on carriage 0 (dock reference); 2: lift
  SET_DUAL_CARRIAGE CARRIAGE=0
  G28 X
  G1 Z{zraise} F1050
  # 3: move to the sense position (+X of home)
  G1 X{sense_x} F6000
  # 4: probe down onto the static blocker -> printer.probe.last_z_result
  PROBE
  # 5: lift clear of the blocker; 6: back to home X
  G1 Z{zraise} F1050
  G1 X{endstop} F6000
  # last_z_result is read in the NEXT macro (renders after PROBE has run).
  _PROBE_DROPOFF_STRIP

[gcode_macro _PROBE_DROPOFF_STRIP]
description: Internal — descend to the sensed blocker height, then slide the probe off
gcode:
  {% set endstop = printer.configfile.settings.stepper_x.position_endstop|float %}
  {% set zmin = printer.configfile.settings.stepper_z.position_min|float %}
  {% set lnl = printer["gcode_macro LNLOS"] %}
  {% set release_x = endstop + lnl.probe_dock_release|float %}
  {% set zoffset = lnl.probe_dock_zoffset|float %}
  {% set zraise = lnl.probe_pickup_zraise|float %}
  # 7: descend to the sensed engagement height (clamped >= Z position_min)
  {% set engage_z = [printer.probe.last_z_result|float + zoffset, zmin]|max %}
  G90
  G1 Z{engage_z} F1050
  # 8: slide +X until the blocker strips the probe into the dock
  G1 X{release_x} F1250
  # finish: lift and verify the probe detached
  G1 Z{zraise} F1050
  PROBEOFF
```

- [ ] **Step 4: Verify no dangling references to the retired variables**

Run:
```bash
grep -rn --include='*.cfg' -E 'probe_pickup_xpos|probe_pickup_ypos|probe_pickup_zpos' base
```
Expected: **no output** (exit 1).

- [ ] **Step 5: Verify the new variables are defined and consumed**

Run:
```bash
grep -rn --include='*.cfg' -E 'probe_dock_sense_xoffset|probe_dock_release|probe_dock_zoffset' base
```
Expected: each name appears once in `_host_deps.cfg` (definition) and once in `EuclidUtilities.cfg` (use).

- [ ] **Step 6: Verify Jinja block balance in the edited macro file**

Run:
```bash
python3 - <<'PY'
import re
s=open('base/EuclidUtilities.cfg').read()
ifs=len(re.findall(r'{%-?\s*if\b',s)); endifs=len(re.findall(r'{%-?\s*endif\b',s))
fors=len(re.findall(r'{%-?\s*for\b',s)); endfors=len(re.findall(r'{%-?\s*endfor\b',s))
print('if/endif',ifs,endifs,'for/endfor',fors,endfors)
assert ifs==endifs and fors==endfors, 'unbalanced Jinja blocks'
print('OK')
PY
```
Expected: `... OK` (counts match).

- [ ] **Step 7: Commit inside the submodule**

Run:
```bash
cd base && git add macros/_host_deps.cfg EuclidUtilities.cfg && git commit -m "$(cat <<'EOF'
klicky: home-X pickup + probe-sensed dropoff

Replace the coordinate-based PROBE_PICKUP/PROBE_DROPOFF with a home-X
pickup (carriage 0) and a 3-stage probe-sensed dropoff: sense the static
blocker at endstop+sense_xoffset, then descend to the sensed height and
slide +release to strip the probe. Retire probe_pickup_x/y/zpos for
endstop-relative probe_dock_* offsets. Fixes the pickup's pre-attach
full-G28 (Z can't home without the probe).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)" && cd ..
```
Expected: one commit on branch `klicky-home-dock`.

---

### Task 2: Bump the parent submodule pointer (local, no push)

**Files:**
- Modify: parent repo `base` gitlink + this is a parent commit.

- [ ] **Step 1: Stage and verify the pointer moved**

Run:
```bash
git add base && git status --short
```
Expected: `M  base` staged (parent now points at the new `base` commit).

- [ ] **Step 2: Commit the pointer bump**

Run:
```bash
git commit -m "$(cat <<'EOF'
Bump base: klicky home-X pickup + probe-sensed dropoff

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```
Expected: parent commit created on `klicky-pick-up-and-drop-off-rout`.

- [ ] **Step 3: Confirm pointer == base HEAD**

Run:
```bash
[ "$(git ls-tree HEAD base | awk '{print $3}')" = "$(git -C base rev-parse HEAD)" ] && echo MATCH || echo MISMATCH
```
Expected: `MATCH`.

> **Publish (only when the user asks):** push `base` first (`git -C base push -u origin klicky-home-dock`), then the parent (`git push`), or run `scripts/bump-base.sh` which pushes `base` and re-bumps. `push.recurseSubmodules=check` will refuse the parent push until `base` is on origin.

---

### Task 3: Operator hardware dry-run (validation — not run by the agent)

Klipper macros can only be truly validated on the machine. Hand this checklist to the operator; keep a hand on the E-stop.

- [ ] **Pickup (cheap, X-only):** from a cold machine, run `PROBE_PICKUP`. Carriage 0 homes X to -54 and grabs the probe; `PROBEON` prints "Probe attached (verified)". If it reports detached, check dock alignment.
- [ ] **Dropoff sense:** with the probe attached and the machine homeable, run `PROBE_DROPOFF`. Watch step 4 — the `PROBE` should trigger on the blocker at a sane Z. If it descends to ~-9 and errors "probe … not triggered", re-check `probe_dock_sense_xoffset` (blocker not under the tip).
- [ ] **Dropoff strip:** confirm the lift (step 5) clears the blocker, the return to -54 (step 6) is clean, and the +X slide (step 8) strips the probe into the dock; `PROBEOFF` prints "Probe docked (verified)".
- [ ] **Tune if needed:** `SET_GCODE_VARIABLE MACRO=LNLOS VARIABLE=probe_dock_zoffset VALUE=<mm>` (engagement height), `...probe_dock_sense_xoffset` (touch point), `...probe_dock_release` (slide distance). Persist good values by editing `_host_deps.cfg`.
- [ ] **KlipperScreen:** confirm **Calibration → Probe Pickup / Probe Dropoff** run the same routines.

---

## Self-Review

**Spec coverage:** pickup (Task 1 §PROBE_PICKUP) ✓; 8-step probe-sensed dropoff (Task 1 §_PROBE_DROPOFF_SENSE/_STRIP) ✓; retire old vars (Task 1 Step 2, Step 4) ✓; endstop-relative geometry (Global Constraints, Task 1) ✓; guards — copy/mirror, probe-attached, engage-Z clamp, no-contact (Task 1 macros; Task 3 checklist) ✓; KlipperScreen unchanged (File Structure; Task 3) ✓; submodule rollout (Task 2) ✓; hardware validation (Task 3) ✓.

**Placeholder scan:** none — every code/command step has literal content.

**Type/name consistency:** `probe_dock_sense_xoffset`, `probe_dock_release`, `probe_dock_zoffset`, `probe_pickup_zraise` defined in Step 2 and consumed identically in Step 3; `_PROBE_DROPOFF_SENSE`/`_PROBE_DROPOFF_STRIP` referenced exactly as defined; `PROBEON`/`PROBEOFF`/`_SAFETY_STOP`/`HOME_IF_NOT` are pre-existing and unchanged.
