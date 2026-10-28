# 08 · Business Model

Freemium with a subscription, mirroring Infuse's published pricing for
positioning ([appendix A](appendix-a-infuse-reference.md): $1.99/mo · $16.99/yr
· $99.99 lifetime, 7-day trial) while differentiating on **what's free**
(PR-D1/D2, doc 01).

## 1. Tiers

| Capability | Free | Pro |
|---|---|---|
| Video codecs | H.264, HEVC (direct, remux, HW-transcode) | **everything**: AV1, VP8/9, VVC, MPEG-1/2, VC-1, WMV, DivX, DV, all containers |
| **HDR (HDR10/10+/HLG) + Dolby Vision + tone-mapping** | ✅ **free, all displays** | — |
| Audio | AAC, AC-3, E-AC-3/Atmos (incl. Atmos downmix), PCM | **DTS, DTS-HD MA, Dolby TrueHD**, lossless FLAC/ALAC/24-bit |
| Subtitles | all formats, full styling | — |
| Sources | **1** source (any kind) | unlimited sources |
| Cloud drives | ❌ | all (§3 of doc 03) |
| Media servers | Plex / Jellyfin / Emby ✅ (1) | ✅ (unlimited instances) |
| Library, metadata, organization | ✅ all (local) | ✅ + synced |
| iCloud sync | ❌ (one-time device migration) | ✅ |
| AirPlay / Google Cast | ❌ | ✅ |
| Trailers | ❌ | ✅ (TMDB) |
| Local files | ✅ | ✅ |
| Updates | current major only | **all updates for life of the purchase** |

> **Decision D-1 (from doc 01, restated):** we deliberately put **all HDR and
> Atmos playback in Free** — the two features Infuse locks behind Pro are the
> most visible quality features, and "my DoVi movie just played, on my cheap
> TV, for free" is the acquisition story. Pro monetizes *codec breadth, audio
> breadth, source breadth, cloud, sync, casting*. Owner sign-off needed before
> store metadata is written.

## 2. Monetization mechanics

- **BIZ-1** StoreKit 2: one **auto-renewable subscription** ("PlayItRight Pro",
  monthly + yearly) + one **non-consumable** ("Pro Lifetime"). Subscription is
  primary UI; lifetime offered on the same sheet. *(P0)*
- **BIZ-2** Pricing (launch, USD; localize with StoreKit price tiers):
  monthly **$1.99**, yearly **$16.99**, lifetime **$99.99**. 7-day free trial
  on the monthly at launch; trial availability per App Store rules. *(P0 —
  final prices owner-decided, these are the positioning anchors)*
- **BIZ-3** Entitlement = any of: active subscription (any term) **or**
  lifetime purchase, or active trial. Grace period: expired-subscription users
  keep Pro for the StoreKit grace window; feature gates then degrade to Free
  *without losing any data* (watch states, libraries, prefs all persist; only
  Pro-gated behaviors switch off, with a single inline notice per feature). *(P0)*
- **BIZ-4** Restore purchases works offline-cached (entitlement cache in
  Keychain with last-seen + expiry, re-validated on next connectivity). *(P0)*
- **BIZ-5** Family Sharing **off** for Pro (single household via Apple ID
  switching, doc 07) — simplifies entitlements; revisit post-launch. *(P0 decision)*
- **BIZ-6** No ads, ever, in any tier. No account beyond Apple ID (and
  optional per-source credentials). This is a product feature (PRD-D2), not a
  cost. *(P0)*
- **BIZ-7** Trial→conversion moment: gate is hit *at the moment of value*
  (first Pro source added / first DTS file / first sync) → sheet with one
  line of benefit + trial CTA; max 1 proactive sheet per day, then badge only. *(P0)*

## 3. Unit economics targets (for planning, not promises)

| Metric | 12-month target |
|---|---|
| Free MAU | 250 k |
| Free→Pro (12 mo) | ≥ 4% |
| Pro MRR at maturity | ≥ $150 k |
| Refund rate | < 1% |
| Lifetime purchase share of new Pro | 10–20% |
