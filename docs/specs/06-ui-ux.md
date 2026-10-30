# 06 · UI/UX

Apple TV is a 10-foot, remote-first, dark-room medium. The UI is designed for:
glanceable hierarchy, one-press actions, backdrop-driven visuals, and zero
keyboard dependency. (Infuse's "stunning organization" bar is the reference —
[appendix A](appendix-a-infuse-reference.md).)

## 1. Design language

| Token | Rule |
|---|---|
| Motion | 60 fps, 200–350 ms eased transitions; no 120 Hz dependency; honor Reduce Motion (crossfade instead of parallax) |
| Layout | 16:9 full-bleed backdrop; content cards float on 12-pt safe grid; max 6 items visible per row, 3 rows typical |
| Focus | single-focus remote model; clear focus ring + scale (1.06×) + backdrop dim of non-focused; keyboard/game-controller supported |
| Type | SF; 10-foot scale (base 28 pt); max 2 lines truncation with "…" — detail view is where text lives |
| Color | dark-first (near-black backdrops); accent = user theme; HDR-aware: UI renders SDR even over HDR video (never washes out to 1000 nits) |
| Density | Grid (posters) / List / Detail per collection; density user-tunable |

## 2. Screens

### 2.1 Onboarding (first launch)

1. Three sink questions (doc 04 §3): *Display: SDR / HDR / Dolby Vision? ·
   Audio: Stereo / 5.1 / Atmos / HomePod? · Typical library: servers / files /
   a bit of both* → written to sink profile + capability hints.
2. Add first source (full add-source flow, doc 03 §2.21): host/credential →
   connect test with plain-language failures → library naming → first-enum
   progress with live counts → **instant first frame**: onboarding finishes
   by letting the user *press play on the first found 4K movie* (the moment
   the pipeline badge first appears is the product's thesis).
3. Optional: sign in for sync (Pro prompt deferred to first sync-worthy action,
   not a modal ambush).

### 2.2 Home

`Continue Watching` (resume rings) · `Next Up` (series logic) · per-library
rows · `Recently Added`. Reorderable; empty state = one big "Add a source"
card. No marketing screens, ever.

### 2.3 Library

- Grid: posters with watched-progress ring, resolution/codec corner badges
  (`4K DoV Atmos`), "in progress" glow.
- List: title · year · stars · progress · badges; sortable/filterable (§4).
- **Filters bar** (top): source · watched · genre · resolution · rating; active
  filters shown as chips; saved as Smart Libraries.
- **Detail (movie/episode)**: hero backdrop, synopsis, cast row, ratings,
  tech badges (codec/color/audio — *clickable → pipeline explainer*), audio &
  subtitle track previews, "Similar" (P1), Play / Play Next Episode / Add to
  collection / Mark watched.
- **Series view**: season/episode episode-grid with stills (P1), progress per
  season, "play next unwatched".

### 2.4 Player

| Element | Spec |
|---|---|
| Video | letterbox/pillarbox preserved; 21:9 + "anamorphic" hint (P2: 2.39 squeeze); frame-rate shown in debug sheet |
| Controls overlay | auto-hide 3 s; seek bar with chapter ticks + buffered region; play/pause, ±10 s, next/prev chapter; audio + subtitle menus; **quality badge** (top-right, persistent dim) |
| **Quality badge** | `Direct` (green) · `Remuxed` (blue) · `Transcoded · HW` (amber) · `Transcoded · SW` (orange) · `Server` (gray) + `HDR/SDR` and `Atmos/5.1/stereo` sub-labels; focus → full pipeline sheet (planner's reasons, in→out codecs, thermal state, "lock this path" action) — the PRD-D1 differentiator |
| Audio menu | all tracks with codec/layout/language badges; downmix preset selector (when transcoding audio) |
| Subtitle menu | tracks + `Off`; forced-only toggle; style presets (size/position/color/opacity) |
| Now-playing strip | in-library: thin bottom bar with title + progress; keep browsing while audio continues (video pauses) |
| Failure card | on un-recoverable error: what failed (codec/color/audio), the rung it died on, actions: `Try software` / `Try server transcode` / `Retry` / `Report` (opt-in diagnostics export) |
| End card | next episode (TV), "more like this" (P1), auto-advance user-toggle |

- **UI-1** All player actions available from remote **and** Bluetooth keyboard/game controller (play, seek, menu, volume, back). *(P0)*
- **UI-2** Controls never block: any action must work without looking at a menu (long-press = 10 s, double = 30 s, etc., user-rebindable P1). *(P0 core bindings; P1 rebinding)*

### 2.5 Settings

Sections: **Sources** (list, connect/test/edit/delete, freshness) ·
**Playback** (sink profile [display, audio setup], quality bias, color mode
`system/precise/off`, tone-map tuning [P1], frame pacing, subtitle defaults,
per-source & per-codec path locks) · **Library** (artwork cache size, scan
schedules, default libraries) · **Sync** (sign-in, what syncs, last sync) ·
**Privacy** (diagnostics opt-in, data export, delete my data) ·
**Subscription** · **About** (capability sheet: *this box can do: …* —
the registry made visible, a feature not a debug screen).

- **UI-3** The capability sheet and every "why did it transcode" explanation use plain language with an expandable technical detail. *(P0)*

### 2.6 Search & browse

Global search (local + TMDB + scoped per source), people pages (P1), genre
browse (P1), "Browse the web's catalog" as a *play-anything* entry (URL/
.strm drop-in). *(P0 local+TMDB; P1 rest)*

## 3. Theming & personalization

- Dark (default) / Light / Auto (by time). Per-library accent color (auto from
  backdrop palette, user-overridable). Font scale 3 steps. *(P0 dark+auto; P1
  full theming)*

## 4. Accessibility

- **UI-4** Full VoiceOver labels on every card (title, year, progress, badges)
  and every player control; rotation-free layouts; 3 text scales; high-contrast
  mode; Reduce Motion honored; color-blind-safe badge colors (shape+text, never
  color alone). *(P0)*
- **UI-5** Closed-caption *display* quality for SDR/SD content: our subtitle
  renderer is the accessibility path — size/position/contrast/opacity all
  user-tunable and persisted per account. *(P0)*
- **UI-6** Switch Control / full keyboard navigation pass on every screen. *(P1)*

## 5. Performance UX budget

| Action | Budget |
|---|---|
| App cold launch → interactive Home | ≤ 3 s |
| Library grid first paint (10 k items) | ≤ 1.5 s |
| Search keystroke → results | ≤ 300 ms |
| Any focus move | 60 fps, no jank |
| Remote-press → visible response | ≤ 100 ms |

- **UI-7** All budgets above are enforced by UI performance tests in CI (simulator + device matrix). *(P0)*
