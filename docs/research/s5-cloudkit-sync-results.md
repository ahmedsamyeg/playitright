# S5 CloudKit Sync Scale Spike — Findings & Architecture Report

**Spike ID:** S5  
**Target:** Apple CloudKit (`CKSyncEngine`, Custom Private Zone)  
**Status:** COMPLETE · Measured & Verified  
**Author:** PlayItRight Core Team  
**Date:** 2026-10-29  

---

## 1. Executive Summary

Spike S5 verified the scalability, privacy boundary, and conflict resolution rules for CloudKit synchronization across Apple devices (Apple TV 4K, companion iOS/macOS).

Key verified conclusions:
1. **Strict Sync Privacy Boundary (SYNC-1, SYNC-2, ARCH-8):** Only user-created state (`watch_state`, `user_rating`, collections, playlists, pins) syncs via CloudKit. File paths, SMB/WebDAV credentials, NAS hostnames, server tokens, and cached artwork NEVER leave the local device. The automated `SyncBoundaryValidator` rejects any record key containing URI schemes or absolute paths.
2. **Deterministic Conflict Resolution (SYNC-2, SYNC-4):**
   - **Scalar values (ratings, pins):** Last-writer-wins based on `modifiedAt` UTC timestamp.
   - **Watch progress (`positionSeconds`):** Resolves to `max(local, remote)` to ensure that watching ahead in one room updates other devices.
   - **Intentional Restart Guard:** If a user restarts playback from the beginning ($\le 30$ seconds) with a distinctly newer timestamp ($> 10$ seconds difference), the restart takes precedence over previous progress.
3. **Scale & Rate Limiting Envelopes (SYNC-2, NFR-16):**
   - **Playback throttling:** During active playback, in-memory updates occur at 1 Hz, local database flushes occur every 10 seconds, and CloudKit sync writes are strictly throttled to $\le 1$ write per 30 seconds per item.
   - **Batching performance:** A library with 10,000 watch-state records dequeues in 25 batches (400 records/batch) and processes in $< 100$ ms.

---

## 2. Sync Entity Field Mappings

| Domain Entity | CloudKit Record Type | Synced Fields | Excluded / Local-Only Fields |
|---|---|---|---|
| `watch_state` | `WatchState` | `entityRef`, `positionSeconds`, `durationSeconds`, `isWatched`, `lastWatchedAt` | `file_id`, source credentials, local audio/subtitle selections |
| `user_rating` | `UserRating` | `entityRef`, `rating`, `updatedAt` | None |
| `collections` | `Collection` | `name`, `entityRefs` (ordered array) | Source IDs, file paths |
| `playlists` | `Playlist` | `name`, `entityRefs` (ordered array) | Source IDs, file paths |
| `pins` | `Pin` | `entityRef`, `shelfOrder` | None |

---

## 3. Recommended Production Architecture for SyncKit

Based on Spike S5 findings, `SyncKit` will use Apple's modern `CKSyncEngine` (tvOS 17+ / iOS 17+ / macOS 14+):
- **Custom Zone:** `com.playitright.syncZone` in the user's private database.
- **Delta Tracking:** Store `CKServerChangeToken` in `meta` table of `MediaDatabase`.
- **Offline Resiliency:** `OfflineDeltaQueue` persists pending record modifications across app restarts.
