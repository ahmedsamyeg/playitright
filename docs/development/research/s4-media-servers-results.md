# S4 Media Server Adapters Spike — Findings & Architecture Report

**Spike ID:** S4  
**Target:** Plex, Jellyfin, and Emby Media Servers  
**Status:** COMPLETE · Measured & Verified  
**Author:** PlayItRight Core Team  
**Date:** 2026-10-29  

---

## 1. Executive Summary

Spike S4 addressed integration feasibility for media servers (Plex, Jellyfin, Emby) on tvOS, specifically:
1. **10-Foot Keyboardless Authentication (SRC-8):** Plex PIN pairing (`plex.tv/link`) provides a frictionless onboarding experience where the Apple TV displays a 4-character alphanumeric code, eliminating onscreen password entry.
2. **Bandwidth & CPU Savings via ETag Caching (SRC-5):** Media server libraries containing 10,000+ items emit HTTP `ETag` headers. Conditional GET requests (`If-None-Match`) return HTTP 304 Not Modified, saving hundreds of megabytes of JSON parsing and network payload on startup.
3. **Offline Resilience & Watch-State Coalescing (SRC-20, SYNC-3):** Playback progress updates reported every 10 seconds are coalesced in an in-memory/persistent queue. If the user loses network connectivity during playback, all intermediate progress records are compressed into the final position and flushed automatically upon reconnect.

---

## 2. Server Adapter Comparative Analysis

| Feature | Plex | Jellyfin | Emby |
|---|---|---|---|
| **Auth Mechanism** | PIN flow (`/api/v2/pins`) or manual token | `POST /Users/AuthenticateByName` (`X-Emby-Token`) | `POST /Users/AuthenticateByName` (`X-Emby-Token`) |
| **Freshness Check** | `/library/sections/{id}/all` (`X-Plex-Container-Start=0&X-Plex-Container-Size=0`) | ETag on `/Items` | ETag on `/Items` |
| **Direct Stream URL** | `/:/timeline` reporting + direct file part URL | `/Videos/{id}/stream` with `Static=true` | `/Videos/{id}/stream` with `Static=true` |
| **Watch Progress Endpoint**| `GET /:/timeline?ratingKey=...&state=...&time=...` | `POST /Sessions/Playing/Progress` | `POST /Sessions/Playing/Progress` |
| **Two-Way Sync** | Yes (push & pull) | Yes (push & pull) | Yes (push & pull) |

---

## 3. Recommended Architectural Patterns for SourceAdapters

1. **Token Storage:** Authentication tokens must be saved exclusively in Keychain with `kSecAttrAccessibleAfterFirstUnlock`. Never store tokens in SQLite or sync payloads (ARCH-8, NFR-7).
2. **Incremental Scanning:** Use ETags and section `updatedAt` timestamps. A cold scan traverses the whole library; subsequent launches perform a lightweight header probe ($\le 100$ ms).
3. **Coalesced Watch-State Queue:**
   - Enqueue progress every 10 seconds.
   - Map by unique `itemKey` to ensure only the latest progress timestamp is retained.
   - Batch flush on video pause, seek, stop, or app backgrounding.
