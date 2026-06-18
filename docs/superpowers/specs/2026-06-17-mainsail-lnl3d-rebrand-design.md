# Mainsail LNL3D Rebrand — Design Spec

**Date:** 2026-06-17
**Status:** Draft for review
**Scope:** Mainsail web UI only. KlipperScreen deferred to a later effort.

## Goal

Give the Mainsail web interface a distinctive LNL3D identity — gold-primary
dark theme, LNL3D logo + favicon, and visible "BIQU/BTT → LNL3D" naming — so it
no longer looks like a stock BigTreeTech/BIQU install.

## Hard Constraint: Do Not Dirty Managed Repos

The only files that may change live in the **printer config directory's
`.theme/` folder** (this Vulcan2 config repo) plus **Moonraker runtime settings**
(stored in Moonraker's database, not in any repo).

Explicitly OFF LIMITS:
- `~/mainsail` (the Mainsail app — managed by `update_manager`)
- `~/mainsail-config`
- `~/KlipperScreen`
- System hostname / networking / OS user (`biqu`)

Rationale: Mainsail loads its theme from the **config directory**, not from the
app install. Putting branding in `.theme/` leaves every `update_manager`-tracked
repo a pristine git checkout, so software updates keep working untouched.

## Direction (decided)

| Decision | Value |
|---|---|
| Primary accent | LNL Gold `#FBB040` |
| Secondary accent | LNL Blue `#1B75BB` |
| Neutral | LNL Grey `#939598` |
| Base theme | Dark |
| Rename scope | All visible UI text (hostname left alone) |
| Logo source | Adapt the existing LNL3D artwork (triangle mark + wordmark) |

## Deliverables

### A. Files in `.theme/` (this config repo)

| File | Status | Purpose |
|---|---|---|
| `sidebar-logo.png` | exists (triangle mark, transparent) — keep or refine | Sidebar brand logo |
| `favicon-16x16.png` | new | Browser tab icon (squared triangle mark) |
| `favicon-32x32.png` | new | Browser tab icon (squared triangle mark) |
| `custom.css` | new | The visual overhaul (see Color Tokens) |
| `navi.json` | exists — update | Fix wiki link `google.com` → `https://wiki.lnl3d.com` |
| `main-background.svg` | new, optional | Subtle branded dashboard backdrop |

All `.theme/` files are optional and loaded only if present, per Mainsail's
custom-theme contract.

### B. `custom.css` — what it overrides

- `--primary` accent → gold `#FBB040` (re-tints buttons, progress bars, active
  tabs, sliders, toggles).
- Secondary/link/highlight accents → blue `#1B75BB`.
- Dark surface refinements: app background `#1b1b1d`, cards/panels `#26262a`,
  borders/dividers tuned to the LNL grey family.
- Ensure gold accent meets readable contrast on dark surfaces (gold text only on
  dark, never gold-on-gold).
- Keep overrides scoped to color/branding tokens; avoid layout/structural CSS
  that could break across Mainsail versions.

### C. Color Tokens

```
--primary (gold)      #FBB040
secondary (blue)      #1B75BB
neutral grey          #939598
app background        #1b1b1d
panel/card surface    #26262a
```

### D. Runtime Settings (Moonraker DB — no repo touched)

Documented as one-time operator steps; these are the visible BTT/BIQU → LNL3D
rename surface in Mainsail:

1. Settings → set theme to **Dark**.
2. Settings → General → Printer display name → **"LNL3D Vulcan2"**
   (this drives the browser tab title and the sidebar heading).
3. Confirm primary color shows as gold (custom.css enforces it; the UI color
   picker may be left at default since CSS wins).

## Asset Production Plan

- **Favicon:** derive from the existing transparent triangle mark
  (`sidebar-logo.png`) — square the canvas, export 16×16 and 32×32 PNG.
- **Sidebar logo:** keep the triangle mark (reads well on dark). Optionally
  produce a horizontal wordmark variant with "Solutions" lightened for dark
  backgrounds if a wider lockup is preferred.
- Tooling: image library (PIL/ImageMagick) for crop/resize/recolor. No external
  services.

## Out of Scope (explicit)

- KlipperScreen theming (deferred — needs a deploy script / install-dir theme,
  which the "no dirty repos" constraint rules out for now).
- Hostname / `.local` URL / SSH config changes.
- PWA app name (`Mainsail`) — not reliably settable via `.theme/`.
- Any edits to `~/mainsail`, `~/mainsail-config`, or `~/KlipperScreen`.

## Success Criteria

1. Mainsail loads with a gold-accented dark theme and LNL3D logo + favicon.
2. Browser tab + sidebar read "LNL3D Vulcan2" — no visible BIQU/BTT branding.
3. `git status` in `~/mainsail`, `~/mainsail-config`, `~/KlipperScreen` is clean;
   `update_manager` reports all three as up-to-date / updatable.
4. Only `.theme/` files changed in the config repo.

## Verification (on the Pi)

- Hard-refresh Mainsail; confirm logo, favicon, gold accents, dark surfaces.
- Confirm tab title / sidebar name.
- Run `update_manager` status check; confirm managed repos clean.
