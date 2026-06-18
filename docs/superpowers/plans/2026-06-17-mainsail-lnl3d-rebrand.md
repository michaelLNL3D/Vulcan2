# Mainsail LNL3D Rebrand Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Mainsail a distinctive LNL3D gold-on-dark identity (logo, favicon, accent, visible BIQU/BTT→LNL3D naming) entirely through the config-dir `.theme/` folder plus Moonraker runtime settings.

**Architecture:** Mainsail loads branding from the printer config directory's hidden `.theme/` folder, never from its own install. We add/update files there (favicons, `navi.json`, `custom.css`) and apply two native runtime settings (primary color, printer name). All `update_manager`-tracked repos (`~/mainsail`, `~/mainsail-config`, `~/KlipperScreen`) stay pristine.

**Tech Stack:** Mainsail (Vue/Vuetify), Moonraker, Python 3 + Pillow (asset generation), JSON, CSS.

## Global Constraints

- **No dirty managed repos.** Only `.theme/` files (this config repo) and Moonraker runtime settings may change. Never edit `~/mainsail`, `~/mainsail-config`, `~/KlipperScreen`, hostname, or OS user.
- **Brand colors (verbatim):** primary gold `#FBB040`; secondary blue `#1B75BB`; neutral grey `#939598`; dark app background `#1b1b1d`; panel surface `#26262a`.
- **Accent color is a NATIVE Mainsail setting**, not CSS. The gold primary is applied via Mainsail's UI color picker (stored in Moonraker DB) — `custom.css` only handles branding polish the picker can't reach, using documented-safe selectors verified live on the Pi.
- **Favicon filenames are exact:** `favicon-16x16.png`, `favicon-32x32.png` (Mainsail loads only these names).
- **Logo source:** existing `.theme/sidebar-logo.png` (transparent LNL triangle mark, 1508×1361).
- Each file change is committed to the config repo (branch `way-too-many-macros-showing`).
- Asset generation runs on the dev machine (macOS, Pillow 12.1.1 present). Runtime settings + final verification run on the Pi.

---

### Task 1: Generate LNL3D favicons from the triangle mark

**Files:**
- Read: `.theme/sidebar-logo.png` (source mark)
- Create: `.theme/favicon-32x32.png`
- Create: `.theme/favicon-16x16.png`
- Create: `scripts/gen_favicons.py` (one-shot generator, kept for reproducibility)

**Interfaces:**
- Consumes: nothing from prior tasks.
- Produces: `.theme/favicon-16x16.png`, `.theme/favicon-32x32.png` — square transparent PNGs Mainsail auto-loads as the browser tab icon.

- [ ] **Step 1: Write the generator script**

Create `scripts/gen_favicons.py`:

```python
#!/usr/bin/env python3
"""Generate Mainsail favicons from the LNL3D triangle mark.

Pads the (non-square) mark onto a transparent square canvas, then
downscales to the two sizes Mainsail loads by exact filename.
"""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / ".theme" / "sidebar-logo.png"
OUT = ROOT / ".theme"

def main() -> None:
    mark = Image.open(SRC).convert("RGBA")
    side = max(mark.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(mark, ((side - mark.width) // 2, (side - mark.height) // 2), mark)
    for size in (32, 16):
        icon = canvas.resize((size, size), Image.LANCZOS)
        icon.save(OUT / f"favicon-{size}x{size}.png")
        print(f"wrote favicon-{size}x{size}.png")

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run the generator**

Run: `python3 scripts/gen_favicons.py`
Expected output:
```
wrote favicon-32x32.png
wrote favicon-16x16.png
```

- [ ] **Step 3: Verify the files exist with correct dimensions and transparency**

Run: `sips -g pixelWidth -g pixelHeight -g hasAlpha .theme/favicon-32x32.png .theme/favicon-16x16.png`
Expected: `favicon-32x32.png` → pixelWidth 32, pixelHeight 32, hasAlpha yes; `favicon-16x16.png` → pixelWidth 16, pixelHeight 16, hasAlpha yes.

- [ ] **Step 4: Commit**

```bash
git add scripts/gen_favicons.py .theme/favicon-16x16.png .theme/favicon-32x32.png
git commit -m "feat(theme): add LNL3D favicons from triangle mark"
```

---

### Task 2: Point the sidebar nav link at the real LNL3D wiki

**Files:**
- Modify: `.theme/navi.json`

**Interfaces:**
- Consumes: nothing.
- Produces: corrected `navi.json` (valid JSON array Mainsail renders as a sidebar link).

- [ ] **Step 1: Replace the placeholder href**

Set `.theme/navi.json` to exactly:

```json
[
  {
    "title": "LNL3D Wiki",
    "href": "https://wiki.lnl3d.com"
  }
]
```

- [ ] **Step 2: Verify it is valid JSON**

Run: `python3 -c "import json; json.load(open('.theme/navi.json')); print('valid json')"`
Expected: `valid json`

- [ ] **Step 3: Commit**

```bash
git add .theme/navi.json
git commit -m "fix(theme): point sidebar nav link to wiki.lnl3d.com"
```

---

### Task 3: Add custom.css with documented-safe LNL3D branding polish

**Files:**
- Create: `.theme/custom.css`

**Interfaces:**
- Consumes: brand color tokens from Global Constraints.
- Produces: `.theme/custom.css` — loaded by Mainsail on top of the native theme.

**Note:** This file uses only the selector Mainsail officially documents (`#nav-header .v-toolbar__title`) so it cannot break across versions. Deeper structural CSS (panel tints, sliders) is intentionally NOT guessed here — it is added in Task 5 only after inspecting the running app's real selectors via browser devtools. The bulk of the recolor comes from the native primary-color setting (Task 4), not this file.

- [ ] **Step 1: Create the stylesheet**

Create `.theme/custom.css`:

```css
/* LNL3D Mainsail branding polish.
   Accent/dark base come from native Mainsail settings (see plan Task 4).
   Only the documented #nav-header selector is used here so it is
   version-stable. Add inspected selectors in Task 5 if desired. */

:root {
  --lnl-gold: #FBB040;
  --lnl-blue: #1B75BB;
  --lnl-grey: #939598;
}

/* Brand the navigation header title in LNL3D gold. */
#nav-header .v-toolbar__title {
  color: var(--lnl-gold);
  font-weight: 600;
  letter-spacing: 0.02em;
}
```

- [ ] **Step 2: Verify the CSS parses (no stray braces)**

Run: `python3 -c "s=open('.theme/custom.css').read(); assert s.count('{')==s.count('}'), 'brace mismatch'; print('braces balanced:', s.count('{'))"`
Expected: `braces balanced: 2`

- [ ] **Step 3: Commit**

```bash
git add .theme/custom.css
git commit -m "feat(theme): add LNL3D custom.css branding polish"
```

---

### Task 4: Apply native runtime settings on the Pi (no repo touched)

**Files:** none (settings persist in Moonraker's database).

**Interfaces:**
- Consumes: the `.theme/` files from Tasks 1–3 (must be pulled onto the Pi first).
- Produces: a running Mainsail showing gold accent, dark base, and "LNL3D Vulcan2" naming.

- [ ] **Step 1: Get the `.theme/` changes onto the Pi**

On the Pi, in the printer config directory: `git pull` (or your normal sync) so `.theme/favicon-*.png`, `navi.json`, and `custom.css` are present next to `printer.cfg`.

- [ ] **Step 2: Set the primary (accent) color to LNL gold**

In Mainsail: Settings → (Theme/General) → primary color picker → set to `#FBB040`. This is stored in Moonraker's DB and applies to all clients.

- [ ] **Step 3: Set the base theme to Dark**

In Mainsail: toggle/select Dark theme. (Skip if already dark.)

- [ ] **Step 4: Set the printer display name**

In Mainsail: Settings → General → Printername → `LNL3D Vulcan2`. This drives the browser tab title and sidebar heading — the visible BIQU/BTT→LNL3D rename.

- [ ] **Step 5: Hard-refresh and confirm**

Hard refresh (Ctrl+Shift+R / Cmd+Shift+R). Confirm: gold accents on buttons/progress/active tabs, dark surfaces, LNL3D favicon in the tab, "LNL3D Vulcan2" in tab + sidebar, gold nav-header title, "LNL3D Wiki" link in the sidebar.

---

### Task 5 (optional): Deepen the custom.css using live selectors

**Files:**
- Modify: `.theme/custom.css`

**Interfaces:**
- Consumes: the running Mainsail (Task 4) for accurate selectors.
- Produces: extended branding (e.g. panel header tints, login page, scrollbars) using only selectors confirmed in devtools.

Do this ONLY if the native settings + Task 3 leave a specific element you still want re-tinted.

- [ ] **Step 1: Inspect the target element**

In the browser, F12 → element picker (Ctrl+Shift+C) → click the element you want to restyle → copy its real selector from the Elements panel.

- [ ] **Step 2: Add a scoped rule using brand variables**

Append to `.theme/custom.css`, e.g. (replace selector with the inspected one):

```css
/* Example: tint panel headers — REPLACE selector with the one you inspected. */
.panel > .v-card__title {
  color: var(--lnl-gold);
}
```

- [ ] **Step 3: Verify braces balanced**

Run: `python3 -c "s=open('.theme/custom.css').read(); assert s.count('{')==s.count('}'); print('ok')"`
Expected: `ok`

- [ ] **Step 4: Hard-refresh Mainsail and confirm the element restyled**

Cmd/Ctrl+Shift+R, visually confirm. Revert the rule if Mainsail looks broken (malformed/over-broad CSS).

- [ ] **Step 5: Commit**

```bash
git add .theme/custom.css
git commit -m "feat(theme): extend LNL3D custom.css with inspected selectors"
```

---

## Verification (acceptance criteria from spec)

- [ ] Mainsail loads gold-accented dark theme with LNL3D logo + favicon.
- [ ] Browser tab + sidebar read "LNL3D Vulcan2"; no visible BIQU/BTT branding.
- [ ] `git -C ~/mainsail status` / `~/mainsail-config` / `~/KlipperScreen` all clean; `update_manager` reports them updatable.
- [ ] Only `.theme/` files (+ `scripts/gen_favicons.py`) changed in the config repo.
