# 09 · Non-Functional Requirements

## 1. Performance

| ID | Requirement |
|---|---|
| NFR-1 | **App launch:** cold start → interactive Home ≤ 3 s on Apple TV 4K gen 3. Library first paint ≤ 1.5 s for 10 k items (index-backed). Search ≤ 300 ms per keystroke. All UI at 60 fps, no jank over 100-frame windows. |
| NFR-2 | **Thermal:** fanless box. Planner obeys `ProcessInfo.thermalState`: at `.serious` drop encode resolution one rung & notify (PB-24); at `.critical` pause *new* transcode sessions (in-flight ones finish the scene). No feature may poll > 1 Hz. |
| NFR-3 | **Memory:** player render graph ≤ 300 MB resident (4K 10-bit pipelines); app total ≤ 1.5 GB; grid ≤ 100 MB (virtualized); exceeding a budget triggers cache eviction, never a crash. |
| NFR-4 | **Disk:** index ≤ 1 GB for a 1 M-item library (streams not stored; metadata + FTS only); artwork cache user-capped (default 2 GB, 0.5–10 GB); download buffer ≤ 64 MB. |

## 2. Power

| ID | Requirement |
|---|---|
| NFR-5 | Idle app (Home, no video) ≤ 0.5 W sustained; direct-play 1080p HEVC ≤ 3 W; 4K HEVC 10-bit ≤ 5 W; SW-transcode sessions are *expected* to spike (6–10 W) and are always badge-labeled + user-consented by the quality bias. (Measured on gen 3/4; instrumented, advisory.) |
| NFR-6 | Background: app fully suspends when idle; only `BGAppRefreshTask` (library freshness, opportunistic, ≤ 30 s/month budget) and active audio sessions wake it. No timers while suspended. |

## 3. Security

| ID | Requirement |
|---|---|
| NFR-7 | **Credentials:** all source secrets in Keychain (`kSecAttrAccessibleAfterFirstUnlock`); never in the SQLite index, logs, crash reports, or sync payloads (ARCH-8). Memory zeroing for tokens post-use where feasible. |
| NFR-8 | **Transport:** TLS 1.2+ for all vendor APIs and our services; self-signed local-server TLS → explicit user warning + per-server opt-in (never silent downgrade). Plaintext HTTP allowed for local LAN servers with a visible "unencrypted" badge on the source. |
| NFR-9 | **File paths:** no path traversal from URL/`.strm` contents (URL validation: scheme allowlist, no `file://` escapes outside the source's declared root, redirect hops ≤ 3). |
| NFR-10 | **Memory safety:** Swift-first; all C/ObjC interop (FFmpeg, protocol clients) audited in Phase 0; ASan/UBSan CI build weekly. |

## 4. Privacy

| ID | Requirement |
|---|---|
| NFR-11 | **No telemetry by default.** Zero third-party SDKs in the release build. The only network traffic is: user-configured sources, Apple services (CloudKit/StoreKit), metadata providers (TMDB etc.), and *opt-in* diagnostics. |
| NFR-12 | Opt-in diagnostics = user-triggered export of a bounded report (device, tvOS, capability probes, last-N pipeline plans, redacted logs — **never** file paths of private shares, never content metadata, never credentials). Stored locally until the user initiates export. |
| NFR-13 | App Privacy labels: Data Not Collected (default) / with opt-in: Diagnostics (not linked to identity). Crash reporting strictly opt-in, Apple-native. |
| NFR-14 | "Delete my data" (SYNC-5) also clears Keychain entries for *our* stores (source credentials are deleted with their source, individually confirmable). |

## 5. Reliability

| ID | Requirement |
|---|---|
| NFR-15 | Crash-free ≥ 99.5% of sessions; any playback error degrades (rung drop, doc 04 §4.3-7) before it becomes a crash; a session may never die on a recoverable network blip. |
| NFR-16 | Watch-state durability: positions flushed to disk every 10 s and on suspend; a power cut loses < 10 s of progress. |
| NFR-17 | Source resilience: per-adapter circuit breaker (3 consecutive failures → source marked "unreachable", UI badge, background retry with backoff; playback from index continues). |
| NFR-18 | App-update safety: index schema migrations are forward/backward tested (N-1 app version can still open the DB read-only). |

## 6. Compatibility

| ID | Requirement |
|---|---|
| NFR-19 | **Ships working on: Apple TV 4K only** (PRD D-2) — gen 2 (2021, A12Z) **[verify tvOS 18 support]**, gen 3 (2022, A15), gen 4 (2026, A19); tvOS 18+. Feature *breadth* gates on the capability matrix (doc 04 §5), never on model checks in UI code. Unsupported boxes (1080p HD models, 2017 gen 1) launch into a clear "**PlayItRight requires Apple TV 4K**" screen with a support link — no broken half-states. The *tested* floor may be raised per release; raising it requires a spec change + user notice. |
| NFR-20 | Remotes: Apple TV remote (all generations), Siri Remote, any Bluetooth keyboard/game controller; no feature requires a keyboard. |
| NFR-21 | Network: works on 100 Mb LAN and on a 10 Mb WAN uplink (adaptive quality: source bitrate > 1.5× uplink ⇒ suggest lower-rung start). IPv6-only networks supported for servers. |

## 7. Localization & accessibility

| ID | Requirement |
|---|---|
| NFR-22 | Launch locales: **English**. Day-one strings 100% externalized (String Catalogs); full translation of English + 5 top markets by v1.1 (owner picks, budget allows). Codec/format names use locale-correct forms (HEVC, etc.). |
| NFR-23 | Accessibility per doc 06 §4 (VoiceOver, scales, contrast, Reduce Motion) is a **P0 release gate**, not a polish item. |
| NFR-24 | Regional formats: 25/30 fps, PAL/NTSC, all subtitle language codes; no hardcoded 1.6 s or "US" assumptions in timing math. |

## 8. Testability & observability

| ID | Requirement |
|---|---|
| NFR-25 | **Conformance suite:** every supported (codec × container × color × audio) combo has a ≤ 5 MB test asset; the suite runs CI on the device lab (all supported Apple TVs) asserting: plays, correct rung chosen, badge text, tone-map correctness (PSNR/ΔE vs reference), audio downmix correctness. This is the acceptance test for the playback engine. |
| NFR-26 | Developer menu (non-App-Store builds): force rung, force sink profile, force thermal state, dump capability probes, packet-trace a source session. |
| NFR-27 | Deterministic replay: a `PipelinePlan` + inputs must reproduce the same pipeline (PB-7); CI replays 24 h of recorded plans against each release. |
