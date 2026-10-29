# PlayItRight — Master Implementation Plan & Agent Tracking System

**Target Platform:** Apple TV 4K (gen 2, 3, 4; tvOS 18.0+)  
**Architecture:** Platform-neutral Swift Package Manager (SPM) core modules + tvOS SwiftUI App Shell  
**Licensing Constraints:** LGPL 2.1+ for FFmpeg (dynamic `.dylib` only; no static GPL linkage; pure-Swift/permissive for protocol clients)  
**Document Status:** ACTIVE · Last Updated: 2026-10-29  

---

## 1. Tracking Methodology & Agent Execution Protocol

This document is the single source of truth for the implementation of PlayItRight. It is designed to be consumed and executed by autonomous software engineering AI agents as well as human developers.

### 1.1 How Agents Must Operate
1. **Locate Next Task:** Consult the [Master Progress Dashboard](#2-master-progress-dashboard) and identify the earliest phase/workstream with uncompleted tasks whose dependencies are satisfied (`[x]`).
2. **Claim Task:** Before writing code, update the task status in this document from `[ ] NOT STARTED` to `[-] IN PROGRESS`.
3. **Adhere to Code Standards:**
   - Swift 6 language mode with complete concurrency safety (`Sendable`, actors, async/await).
   - Strict adherence to project architecture: `CoreKit`, `CapKit`, `LibraryCore`, `MetadataKit`, `SourceAdapters`, `PlaybackKit`, `SyncKit`, `StoreKit`, and `PlayItRight` (App Shell).
   - No feature code may inspect `UIDevice` or hardware strings directly (ARCH-1); all hardware queries must route through `CapabilityRegistry`.
   - All source secrets and tokens must be stored in Keychain (`kSecAttrAccessibleAfterFirstUnlock`) and never leaked to logs, database, or sync payloads (ARCH-8, NFR-7).
   - Apple hardware acceleration (VideoToolbox / Core Image / Metal / AudioToolbox) is the mandatory first rung; software (FFmpeg / openh264) is strictly the fallback for unsupported operations (ARCH-P6, PB-G2).
4. **Implement Task & Mandatory Unit Tests:**
   - Implement the required source code in the specified module.
   - Every task MUST include unit tests covering nominal, edge, and failure scenarios.
   - Place tests in the corresponding test target (e.g., `Tests/PlaybackKitTests/`).
5. **Verify & Validate:**
   - Run the specified verification command (e.g., `make test` or `swift test --filter <TestSuite>`).
   - Ensure all new and existing tests pass with 0 failures and 0 warnings.
6. **Update Progress:**
   - Mark the task as `[x] COMPLETED` in this document.
   - Update the [Master Progress Dashboard](#2-master-progress-dashboard) counters and percentage.
   - Ensure changes are cleanly documented in the pull request or task recap.

---

## 2. Master Progress Dashboard

### 2.1 Phase Summary

| Phase | Description | Total Tasks | Completed | In Progress | Remaining | % Complete |
|---|---|---|---|---|---|---|
| **Phase 0** | De-risking Spikes (Real Hardware & Labs) | 5 | 5 | 0 | 0 | 100.0% |
| **Phase 1** | MVP Alpha (Core Foundation to First 4K Play) | 36 | 7 | 0 | 29 | 19.4% |
| **Phase 2** | Public Beta (Pro Formats, Cloud, Sync, StoreKit) | 16 | 0 | 0 | 16 | 0% |
| **Phase 3** | v1.0 Launch & Accessibility / Localization | 6 | 0 | 0 | 6 | 0% |
| **Phase 4** | v1.x Continuous Roadmap | 5 | 0 | 0 | 5 | 0% |
| **TOTAL** | **Full Project Lifecycle** | **68** | **12** | **0** | **56** | **17.6%** |

### 2.2 Subsystem Progress

| Subsystem / Target | Responsible Domain | Total Tasks | Completed | Remaining | Status |
|---|---|---|---|---|---|
| `CoreKit` | DI, Keychain, Ring Buffer Diagnostics, Entitlements | 4 | 0 | 4 | Not Started |
| `CapKit` | CapabilityRegistry, Capabilities.json, Hardware Probes | 3 | 0 | 3 | Not Started |
| `LibraryCore` | SQLite Database, GRDB, FTS5, Reader, Writer, GC | 9 | 7 | 2 | **Active (78%)** |
| `MetadataKit` | Matcher Ladder, NFO Parser, TMDB/OMDB, Artwork LRU | 5 | 0 | 5 | Not Started |
| `SourceAdapters` | SourceAdapter Protocol, Plex, Jellyfin, Emby, SMB, NFS, WebDAV, HTTP | 8 | 0 | 8 | Not Started |
| `PlaybackKit` | MediaGraph, PipelinePlanner, R1–R5, Color, Audio, Subtitles | 11 | 0 | 11 | Not Started |
| `SyncKit` | CloudKit SyncEngine, Record Zones, Merge Rules, Deltas | 5 | 0 | 5 | Not Started |
| `StoreKit` | Subscriptions, Lifetime Purchase, Entitlements Gating | 2 | 0 | 2 | Not Started |
| `PlayItRight (App)`| SwiftUI 10-Foot UI, Focus, Player, Badge, Settings | 11 | 0 | 11 | Not Started |
| `QA & Test Lab` | Conformance Suite, Automated Benchmarks, Replay | 5 | 0 | 5 | Not Started |
| `Phase 0 Spikes` | S1-S5 Spikes on Hardware & Protocols | 5 | 5 | 0 | **COMPLETED (5/5)** |
| `Localization / A11y`| VoiceOver, Contrast, String Catalogs, Translations | 5 | 0 | 5 | Not Started |

---

## 3. Phase 0 — De-risking Spikes (Lab & Verification Harnesses)

Spikes resolve all Apple platform uncertainties (**[verify]** items) prior to full production integration. Code in this phase lives in standalone test harnesses or benchmark CLI tools.

### [x] TASK-0.1: S1 Playback Core Spike
- **Status:** COMPLETED
- **Requirements Ref:** `ARCH-P6`, `PB-G2`, `PB-4`, `PB-16`, `doc 04 §3/§5`
- **Objective:** Verify `AVPlayer` vs `AVSampleBufferDisplayLayer` (ASBDL) for remuxed MKVs; evaluate system tone-mapping of HEVC-HDR to SDR; observe composited `CMVideoFormatDescription`; test Dolby Vision Profile 8 on SDR displays.
- **Deliverables:**
  - Prototype playback test harness running in `Sources/PlaybackSpike/`.
  - Documented findings in `docs/research/s1-playback-results.md` filling all **[verify]** cells in doc 04 §3/§5.
- **Unit & Integration Tests:**
  - `Tests/PlaybackSpikeTests/FormatDescriptionInspectorTests.swift`
  - `Tests/PlaybackSpikeTests/SampleBufferDisplayQueueTests.swift`
  - `Tests/PlaybackSpikeTests/HDRToneMapSimulatorTests.swift`
  - `Tests/PlaybackSpikeTests/DisplayCapabilityDetectorTests.swift`
- **Verification:** `make test` (17 tests passing across 4 suites)
- **Dependencies:** None.

### [x] TASK-0.2: S2 File Protocols Spike
- **Status:** COMPLETED
- **Requirements Ref:** `SRC-2`, `SRC-3`, `SRC-9`, `ARCH-6`, `doc 03 §3`
- **Objective:** Evaluate pure-Swift SMB2/3, NFSv3/v4, and SFTP client implementations for sustained throughput on LAN (target > 100 MB/s for 4K remuxes) without GPL license contamination.
- **Deliverables:**
  - Benchmark simulation engine running in `Sources/PlaybackSpike/FileProtocols/`.
  - Licensing audit report verifying pure-Swift / permissive license compliance in `docs/research/s2-file-protocols-results.md`.
- **Unit & Integration Tests:**
  - `Tests/PlaybackSpikeTests/FileProtocolsTests/ResilientByteStreamReaderTests.swift`
  - `Tests/PlaybackSpikeTests/FileProtocolsTests/ProtocolBenchmarkSimulatorTests.swift`
  - `Tests/PlaybackSpikeTests/FileProtocolsTests/FileProtocolLicenseAuditTests.swift`
- **Verification:** `make test` (7 tests passing across 3 suites)
- **Dependencies:** None.

### [x] TASK-0.3: S3 FFmpeg LGPL XCFramework & Conformance Spike
- **Status:** COMPLETED
- **Requirements Ref:** `ARCH-5`, `ARCH-6`, `PB-2`, `doc 02 §5`
- **Objective:** Build reproducible LGPL 2.1+ FFmpeg dynamic framework for tvOS (`arm64`) with required decoders (AV1, VP8/VP9, VVC, VC-1, DTS, TrueHD, dolbyvision, zscale/tonemap) and openh264 for software H.264 encode; verify zero static GPL symbols.
- **Deliverables:**
  - Build script `scripts/build-ffmpeg-tvos.sh` generating `FFmpeg.xcframework` receipt and configuration.
  - CI license check script `scripts/audit-licenses.sh` verifying absence of GPL code.
  - Simulated demuxer and decoder bridge in `Sources/PlaybackSpike/FFmpeg/`.
  - Research findings report in `docs/research/s3-ffmpeg-results.md`.
- **Unit & Integration Tests:**
  - `Tests/PlaybackSpikeTests/FFmpegTests/FFmpegConformanceTests.swift`
- **Verification:** `./scripts/audit-licenses.sh && make test` (5 tests passing across 1 suite)
- **Dependencies:** None.

### [x] TASK-0.4: S4 Media Server Adapters Spike
- **Status:** COMPLETED
- **Requirements Ref:** `SRC-1`, `SRC-5`, `SRC-8`, `doc 03 §2`
- **Objective:** Verify Plex PIN/2FA pairing flow on 10-foot UI without keyboard; test Jellyfin/Emby REST endpoints, ETag caching, and watch-state write APIs.
- **Deliverables:**
  - Mock and live integration tests for Plex, Jellyfin, and Emby authentication in `Sources/PlaybackSpike/MediaServers/`.
  - Research findings report in `docs/research/s4-media-servers-results.md`.
- **Unit & Integration Tests:**
  - `Tests/PlaybackSpikeTests/MediaServersTests/MediaServerSpikeTests.swift`
- **Verification:** `make test` (3 tests passing across 1 suite)
- **Dependencies:** None.

### [x] TASK-0.5: S5 CloudKit Sync Scale Spike
- **Status:** COMPLETED
- **Requirements Ref:** `SYNC-1`, `SYNC-2`, `doc 07 §1`, `doc 10 §Phase 0`
- **Objective:** Verify CloudKit `CKSyncEngine` with custom zone, batching 10,000 `watchState` records, rate limit envelopes, and conflict resolution rules.
- **Deliverables:**
  - CloudKit sync harness in `Sources/PlaybackSpike/Sync/` proving batching and scale.
  - Conflict resolution algorithms with recency guard in `CloudKitConflictResolver.swift`.
  - Research findings report in `docs/research/s5-cloudkit-sync-results.md`.
- **Unit & Integration Tests:**
  - `Tests/PlaybackSpikeTests/SyncTests/CloudKitSyncScaleTests.swift`
- **Verification:** `make test` (5 tests passing across 1 suite)
- **Dependencies:** None.

---

## 4. Phase 1 — MVP Alpha (Core Foundation to First 4K Playback)

### Workstream 1.1: CoreKit Foundation

#### [ ] TASK-1.1.1: CoreKit Module Setup & Dependency Injection
- **Requirements Ref:** `ARCH-P2`, `ARCH-P8`, `doc 02 §2`
- **Objective:** Initialize `CoreKit` SPM target with lightweight, type-safe dependency injection container and service registry.
- **Target Files:**
  - `Sources/CoreKit/DI/ServiceContainer.swift`
  - `Sources/CoreKit/DI/Inject.swift`
  - `Tests/CoreKitTests/ServiceContainerTests.swift`
- **Implementation Details:**
  - Provide thread-safe `ServiceContainer` using Swift 6 concurrency (`Sendable`, actor-protected or lock-free).
  - Implement `@Injected` property wrapper resolving registered protocols.
- **Unit Tests:**
  - Test registration and resolution of singletons and transient factory instances.
  - Test resolution failure throws typed error `ServiceNotFoundError`.
  - Test concurrent service resolution under parallel Task execution.
- **Verification:** `swift test --filter ServiceContainerTests`
- **Dependencies:** None.

#### [ ] TASK-1.1.2: Keychain Storage Abstraction
- **Requirements Ref:** `ARCH-8`, `NFR-7`, `doc 09 §3`
- **Objective:** Implement secure Keychain wrapper for credential storage with `kSecAttrAccessibleAfterFirstUnlock`. Secrets must never touch disk, logs, or sync payloads.
- **Target Files:**
  - `Sources/CoreKit/Security/KeychainStore.swift`
  - `Sources/CoreKit/Security/KeychainProtocol.swift`
  - `Tests/CoreKitTests/KeychainStoreTests.swift`
- **Implementation Details:**
  - Store strings, data, and Codable objects keyed by opaque identifiers.
  - Support memory-zeroing for sensitive tokens post-use where feasible.
- **Unit Tests:**
  - Test saving, reading, updating, and deleting credentials.
  - Test query by unknown key returns `nil` (or throws typed error).
  - Test mock Keychain implementation for CI and unit test execution without host Keychain prompts.
- **Verification:** `swift test --filter KeychainStoreTests`
- **Dependencies:** `TASK-1.1.1`

#### [ ] TASK-1.1.3: Structured Logging & Ring Buffer Diagnostics
- **Requirements Ref:** `ARCH-9`, `NFR-11`, `NFR-12`, `doc 09 §4`
- **Objective:** Implement structured in-memory ring-buffer logger (5,000 entries max) with log levels, automatic redaction of URLs, tokens, and file paths, and export capability.
- **Target Files:**
  - `Sources/CoreKit/Diagnostics/RingBufferLogger.swift`
  - `Sources/CoreKit/Diagnostics/LogRedactor.swift`
  - `Sources/CoreKit/Diagnostics/DiagnosticReport.swift`
  - `Tests/CoreKitTests/RingBufferLoggerTests.swift`
- **Implementation Details:**
  - Lock-free or actor-isolated circular buffer retaining `LogEntry`.
  - `LogRedactor` strips query parameters, auth headers, and IP/share paths from log strings.
- **Unit Tests:**
  - Test circular buffer overwrites oldest entries when exceeding capacity.
  - Test redactor sanitizes strings like `smb://user:pass@192.168.1.100/share` to `smb://[REDACTED]@...`.
  - Test diagnostic report serialization to JSON without leaking credentials.
- **Verification:** `swift test --filter RingBufferLoggerTests`
- **Dependencies:** `TASK-1.1.1`

#### [ ] TASK-1.1.4: Thermal State & System Resource Monitor
- **Requirements Ref:** `ARCH-6`, `NFR-2`, `PB-24`, `doc 09 §1`
- **Objective:** Implement `ThermalMonitor` observing `ProcessInfo.thermalStateDidChangeNotification` and exposing an `AsyncStream<ThermalState>` for reactive pipeline downgrades.
- **Target Files:**
  - `Sources/CoreKit/System/ThermalMonitor.swift`
  - `Tests/CoreKitTests/ThermalMonitorTests.swift`
- **Implementation Details:**
  - Map `ProcessInfo.ThermalState` to app-level domain enum (`nominal`, `fair`, `serious`, `critical`).
  - Debounce notifications so sampling occurs at $\le 1$ Hz.
- **Unit Tests:**
  - Test thermal state transitions trigger stream emissions.
  - Test thermal polling rate is bounded to $\le 1$ Hz (NFR-2).
- **Verification:** `swift test --filter ThermalMonitorTests`
- **Dependencies:** `TASK-1.1.1`

---

### Workstream 1.2: CapKit (Hardware Capabilities & Probes)

#### [ ] TASK-1.2.1: Capability Data Model & Bundled Capabilities.json
- **Requirements Ref:** `ARCH-1`, `PB-8`, `PB-9`, `doc 04 §5`
- **Objective:** Create the static hardware capability matrix model and `Capabilities.json` covering Apple TV 4K gen 2 (A12Z), gen 3 (A15), and gen 4 (A19).
- **Target Files:**
  - `Sources/CapKit/Models/DeviceCapabilityProfile.swift`
  - `Sources/CapKit/Models/CodecCapability.swift`
  - `Sources/CapKit/Resources/Capabilities.json`
  - `Tests/CapKitTests/CapabilityProfileTests.swift`
- **Implementation Details:**
  - Define video codec capabilities: decode (`hw`, `sw`, `none`), max resolution, max bit depth, HDR support (HDR10, HDR10+, DoVi profiles 5, 8, 8.1, HLG).
  - Define audio capabilities: hardware decode vs software decode vs passthrough.
- **Unit Tests:**
  - Test JSON decoding for gen 2, gen 3, and gen 4 capability profiles.
  - Test profile lookups: gen 4 reports AV1 HW decode = true; gen 2/3 report AV1 HW decode = false.
  - Test Dolby Vision profile support: gen 4 supports 5 and 8.1; gen 3 supports 5; gen 2 supports 5 and 8.
- **Verification:** `swift test --filter CapabilityProfileTests`
- **Dependencies:** `TASK-1.1.1`

#### [ ] TASK-1.2.2: Runtime VideoToolbox Probes
- **Requirements Ref:** `ARCH-1`, `PB-8`, `PB-10`, `doc 04 §5.1`
- **Objective:** Implement hardware probe runner that attempts to create `VTDecompressionSession` and `VTCompressionSession` instances with minimal format descriptions to verify actual silicon capabilities.
- **Target Files:**
  - `Sources/CapKit/Probes/VideoToolboxProbe.swift`
  - `Sources/CapKit/Probes/AudioOutputProbe.swift`
  - `Tests/CapKitTests/VideoToolboxProbeTests.swift`
- **Implementation Details:**
  - Probe H.264 8-bit, HEVC 8/10-bit, AV1 (on gen 4), VP9, and ProRes.
  - Cache probe results to local storage so probe runs in $< 200$ ms on subsequent launches.
- **Unit Tests:**
  - Test probe execution against mock formats.
  - Test probe result caching and eviction if OS version changes.
- **Verification:** `swift test --filter VideoToolboxProbeTests`
- **Dependencies:** `TASK-1.2.1`

#### [ ] TASK-1.2.3: CapabilityRegistry Engine
- **Requirements Ref:** `ARCH-1`, `PB-8`, `PB-9`, `PB-10`, `NFR-19`
- **Objective:** Implement `CapabilityRegistry` as the single authoritative service answering queries like `canHardwareDecode(codec, profile, bitDepth, resolution)` and rejecting unsupported devices (1080p Apple TV HD, 2017 gen 1).
- **Target Files:**
  - `Sources/CapKit/CapabilityRegistry.swift`
  - `Tests/CapKitTests/CapabilityRegistryTests.swift`
- **Implementation Details:**
  - Layer 1 (bundled JSON) + Layer 2 (runtime probes override Layer 1).
  - Detect unsupported hardware at launch and emit `UnsupportedHardwareError`.
- **Unit Tests:**
  - Test `canHardwareDecode` returns correct values for each Apple TV generation.
  - Test runtime probe override takes precedence over static JSON (PB-10).
  - Test developer override ("force software path") works for all codecs.
- **Verification:** `swift test --filter CapabilityRegistryTests`
- **Dependencies:** `TASK-1.2.2`

---

### Workstream 1.3: LibraryCore (Database & Storage)

*Note: Core schema, migrations, reader, writer, entity refs, and environment configs are already implemented and tested.*

#### [x] TASK-1.3.1: SQLite Schema & GRDB Migration V1
- **Requirements Ref:** `DB-1`, `DB-2`, `DB-3`, `DB-4`, `DB-5`, `DB-6`, `DB-7`, `ARCH-3`, `doc 11`
- **Status:** COMPLETED
- **Files:** `Sources/LibraryCore/Database/DatabaseMigrator+Schema.swift`
- **Tests:** `Tests/LibraryCoreTests/MigrationTests.swift`

#### [x] TASK-1.3.2: MediaDatabase Connection & Concurrency Architecture
- **Requirements Ref:** `DB-1`, `ARCH-3`, `doc 11 §2`
- **Status:** COMPLETED
- **Files:** `Sources/LibraryCore/Database/MediaDatabase.swift`, `Sources/LibraryCore/Database/MediaDatabaseConfiguration.swift`
- **Tests:** `Tests/LibraryCoreTests/MediaDatabaseTests.swift`

#### [x] TASK-1.3.3: Environment Configuration & DotEnv Loader
- **Requirements Ref:** `doc 02 §3`, `design 01 §1`
- **Status:** COMPLETED
- **Files:** `Sources/LibraryCore/Environment/AppEnvironment.swift`, `Sources/LibraryCore/Environment/DotEnv.swift`, `Sources/LibraryCore/Environment/EnvironmentConfiguration.swift`
- **Tests:** `Tests/LibraryCoreTests/EnvironmentConfigurationTests.swift`

#### [x] TASK-1.3.4: EntityRef Models & Schema Records
- **Requirements Ref:** `DB-X1`, `DB-X2`, `DB-X3`, `doc 11 §2`
- **Status:** COMPLETED
- **Files:** `Sources/LibraryCore/Models/EntityRef.swift`, `Sources/LibraryCore/Models/Enums.swift`, `Sources/LibraryCore/Models/Records.swift`
- **Tests:** `Tests/LibraryCoreTests/EntityRefTests.swift`

#### [x] TASK-1.3.5: MediaDatabaseWriter & Index Change Events
- **Requirements Ref:** `DB-3`, `DB-4`, `DB-7`, `NFR-16`, `doc 11 §3.2`
- **Status:** COMPLETED
- **Files:** `Sources/LibraryCore/Writer/MediaDatabaseWriter.swift`, `Sources/LibraryCore/Database/IndexChangeEvent.swift`
- **Tests:** `Tests/LibraryCoreTests/MediaDatabaseWriterTests.swift`

#### [x] TASK-1.3.6: MediaDatabaseReader & Keyset Pagination
- **Requirements Ref:** `DB-6`, `MD-11`, `NFR-1`, `doc 11 §2.15`
- **Status:** COMPLETED
- **Files:** `Sources/LibraryCore/Reader/MediaDatabaseReader.swift`, `Sources/LibraryCore/Reader/QueryModels.swift`, `Sources/LibraryCore/Filters/SmartLibraryFilter.swift`
- **Tests:** `Tests/LibraryCoreTests/MediaDatabaseReaderTests.swift`

#### [x] TASK-1.3.7: Orphan Garbage Collection & Backup Generations
- **Requirements Ref:** `DB-10`, `MD-13`, `NFR-4`, `design 01 §6`
- **Status:** COMPLETED
- **Files:** `Sources/LibraryCore/Database/MediaDatabase.swift`, `Sources/LibraryCore/Writer/MediaDatabaseWriter.swift`
- **Tests:** `Tests/LibraryCoreTests/MediaDatabaseTests.swift`, `Tests/LibraryCoreTests/MediaDatabaseWriterTests.swift`

#### [ ] TASK-1.3.8: Similar Titles Table & "More Like This" Queries (DB-11)
- **Requirements Ref:** `DB-11`, `MD-2`, `doc 11 §2.11`, `doc 05 §2`
- **Objective:** Add schema support and reader/writer queries for `similar` titles table storing entity ref pairs to power "More Like This" recommendations.
- **Target Files:**
  - `Sources/LibraryCore/Database/DatabaseMigrator+Schema.swift` (Migration v2)
  - `Sources/LibraryCore/Reader/MediaDatabaseReader.swift`
  - `Sources/LibraryCore/Writer/MediaDatabaseWriter.swift`
  - `Tests/LibraryCoreTests/SimilarTitlesTests.swift`
- **Implementation Details:**
  - `CREATE TABLE similar (entity_kind TEXT, entity_ref TEXT, similar_kind TEXT, similar_ref TEXT, rank INTEGER, PRIMARY KEY (entity_kind, entity_ref, similar_ref))`
  - Add reader method `fetchSimilar(to: EntityRef, limit: Int)` returning matched movie/show summaries.
- **Unit Tests:**
  - Test saving similar relations for a movie and retrieving them sorted by rank.
  - Test cascade or cleanup when target entity is removed.
- **Verification:** `make test`
- **Dependencies:** `TASK-1.3.1`

#### [ ] TASK-1.3.9: Free-Tier User State Local Export/Import (SYNC-1)
- **Requirements Ref:** `SYNC-1`, `doc 07 §1.1`, `design 01 §1`
- **Objective:** Implement export of the user-state layer only (`watch_state`, `user_rating`, collections, playlists, pins, prefs) into a standalone JSON file for manual device migration.
- **Target Files:**
  - `Sources/LibraryCore/Sync/UserStateExporter.swift`
  - `Sources/LibraryCore/Sync/UserStateImporter.swift`
  - `Tests/LibraryCoreTests/UserStateExportTests.swift`
- **Implementation Details:**
  - Export strictly omits credentials, file paths, artwork, and provider rows.
  - Import merges with conflict rule: max(`last_watched_at`).
- **Unit Tests:**
  - Test exporting user state produces valid JSON without private paths or credentials.
  - Test importing into fresh DB restores watch progress and playlists.
- **Verification:** `make test`
- **Dependencies:** `TASK-1.3.6`

---

### Workstream 1.4: MetadataKit (Scraping, Matching & Artwork)

#### [ ] TASK-1.4.1: Filename Matcher Ladder & Regex Engine
- **Requirements Ref:** `MD-1`, `MD-2`, `doc 05 §1`
- **Objective:** Implement filename parser extracting title, year, season, episode, multi-episode, edition, resolution, and codecs from complex release file strings.
- **Target Files:**
  - `Sources/MetadataKit/Matching/FilenameParser.swift`
  - `Sources/MetadataKit/Matching/ParsedMediaInfo.swift`
  - `Tests/MetadataKitTests/FilenameParserTests.swift`
- **Implementation Details:**
  - Match movie formats: `Inception (2010) [2160p 4K HDR Atmos x265].mkv`.
  - Match episode formats: `Breaking Bad S01E02-E03.mkv`, `Show 1x02.mp4`, `Anime - 12 [1080p].mkv`.
  - Strip release group tags, scene junk, audio/video specs cleanly.
- **Unit Tests:**
  - Test parsing 50 diverse real-world scene release filenames across movies and TV.
  - Test multi-episode range detection (`S01E01-E02`).
  - Test confidence score calculation (high confidence if clean year/season; low if ambiguous).
- **Verification:** `swift test --filter FilenameParserTests`
- **Dependencies:** `TASK-1.1.1`

#### [ ] TASK-1.4.2: Local NFO & Sidecar Metadata Parser
- **Requirements Ref:** `MD-1`, `doc 05 §1`
- **Objective:** Parse Kodi/Emby style `.nfo` XML files and sidecar text files for movies and TV shows, extracting provider IDs, title, synopsis, and cast.
- **Target Files:**
  - `Sources/MetadataKit/Parsers/NFOParser.swift`
  - `Sources/MetadataKit/Models/NFOMedia.swift`
  - `Tests/MetadataKitTests/NFOParserTests.swift`
- **Implementation Details:**
  - Extract TMDB ID, IMDB ID (`tt...`), TVDB ID, plot, rating, director, actors.
  - Priority: local NFO overrides remote scraped metadata for text fields.
- **Unit Tests:**
  - Test parsing valid movie NFO XML with TMDB and IMDB IDs.
  - Test parsing TV show and episode NFOs.
  - Test malformed XML recovers gracefully without throwing fatal errors.
- **Verification:** `swift test --filter NFOParserTests`
- **Dependencies:** `TASK-1.4.1`

#### [ ] TASK-1.4.3: TMDB v3 Client & Rate Limiter
- **Requirements Ref:** `MD-1`, `MD-2`, `doc 05 §1`
- **Objective:** Implement client for The Movie Database (TMDB) v3 API with client-side token bucket rate limiting (40 req / 10 s), 429 backoff, and full DTO decoding.
- **Target Files:**
  - `Sources/MetadataKit/TMDB/TMDBClient.swift`
  - `Sources/MetadataKit/TMDB/TMDBRateLimiter.swift`
  - `Sources/MetadataKit/TMDB/TMDBModels.swift`
  - `Tests/MetadataKitTests/TMDBClientTests.swift`
- **Implementation Details:**
  - Endpoints: `/search/movie`, `/search/tv`, `/movie/{id}`, `/tv/{id}`, `/tv/{id}/season/{s}`, `/movie/{id}/credits`, `/movie/{id}/videos`.
  - Support localized metadata fetching with language fallbacks.
- **Unit Tests:**
  - Test searching movies and decoding response with mock HTTP protocol.
  - Test rate limiter delays requests when token bucket is exhausted.
  - Test HTTP 429 response triggers retry-after delay.
- **Verification:** `swift test --filter TMDBClientTests`
- **Dependencies:** `TASK-1.1.1`, `TASK-1.1.2`

#### [ ] TASK-1.4.4: OMDb & TVDB Secondary Providers
- **Requirements Ref:** `MD-1`, `DB-2`, `doc 05 §1`, `doc 11 §2.3`
- **Objective:** Implement secondary metadata clients for OMDb (fallback movie enrichment) and TVDB (TV series lookup and primary key provider for shows missing in TMDB).
- **Target Files:**
  - `Sources/MetadataKit/OMDb/OMDbClient.swift`
  - `Sources/MetadataKit/TVDB/TVDBClient.swift`
  - `Tests/MetadataKitTests/SecondaryProvidersTests.swift`
- **Implementation Details:**
  - OMDb: match by IMDB ID or title/year.
  - TVDB: authenticate via v4 API token, fetch series and episode mappings.
- **Unit Tests:**
  - Test OMDb title fallback matching with mock responses.
  - Test TVDB series ID resolution and episode list generation.
- **Verification:** `swift test --filter SecondaryProvidersTests`
- **Dependencies:** `TASK-1.4.3`

#### [ ] TASK-1.4.5: Artwork Pipeline & LRU Disk Cache
- **Requirements Ref:** `MD-4`, `NFR-3`, `NFR-4`, `doc 05 §2`, `design 01 §1`
- **Objective:** Implement artwork downloader with size-capped LRU disk cache (default 2 GB, user-adjustable 0.5–10 GB) and memory cache for 4K posters and backdrops.
- **Target Files:**
  - `Sources/MetadataKit/Artwork/ArtworkCache.swift`
  - `Sources/MetadataKit/Artwork/ArtworkPipeline.swift`
  - `Tests/MetadataKitTests/ArtworkCacheTests.swift`
- **Implementation Details:**
  - Cache directory: `Application Support/Artwork/`.
  - Store assets by content hash: `sha256(url)`.
  - LRU eviction based on file access timestamp (`mtime`/`atime`).
- **Unit Tests:**
  - Test downloading and caching an image file.
  - Test LRU eviction when cache exceeds configured byte quota.
  - Test concurrent requests for the same image coalesce into a single download task.
- **Verification:** `swift test --filter ArtworkCacheTests`
- **Dependencies:** `TASK-1.1.1`

---

### Workstream 1.5: SourceAdapters (Protocol & Phase 1 Sources)

#### [ ] TASK-1.5.1: SourceAdapter Protocol & ByteRange Stream
- **Requirements Ref:** `SRC-1`, `SRC-2`, `SRC-3`, `SRC-4`, `SRC-9`, `doc 03 §1`
- **Objective:** Define the core `SourceAdapter` protocol, `SourceSession`, `ItemStream`, `ByteRange`, and `FreshnessInfo` contracts.
- **Target Files:**
  - `Sources/SourceAdapters/Protocols/SourceAdapter.swift`
  - `Sources/SourceAdapters/Models/SourceConfig.swift`
  - `Sources/SourceAdapters/Models/ByteRange.swift`
  - `Sources/SourceAdapters/Models/SourceItem.swift`
  - `Tests/SourceAdaptersTests/SourceAdapterContractTests.swift`
- **Implementation Details:**
  - `read(session:item:range:) -> AsyncThrowingStream<Data, Error>` supporting partial content and mid-stream seeks.
  - All implementations must be `Sendable`.
- **Unit Tests:**
  - Test mock `SourceAdapter` fulfilling contract.
  - Test byte range calculation and boundary checks.
- **Verification:** `swift test --filter SourceAdapterContractTests`
- **Dependencies:** `TASK-1.1.1`

#### [ ] TASK-1.5.2: HTTP/HTTPS & .strm Source Adapter
- **Requirements Ref:** `SRC-9`, `SRC-10`, `SRC-16`, `NFR-8`, `NFR-9`, `doc 03 §3`
- **Objective:** Implement HTTP/HTTPS source adapter supporting direct streaming, standard HTTP `Range: bytes=X-Y`, `.strm` indirection parsing, and self-signed TLS policy.
- **Target Files:**
  - `Sources/SourceAdapters/HTTP/HTTPSourceAdapter.swift`
  - `Sources/SourceAdapters/HTTP/StrmParser.swift`
  - `Tests/SourceAdaptersTests/HTTPSourceAdapterTests.swift`
- **Implementation Details:**
  - Use `URLSession` with background streaming configuration.
  - Parse `.strm` files and resolve target URI with security bounds (no `file://` escape, max 3 redirects per NFR-9).
- **Unit Tests:**
  - Test ranged GET request parses HTTP 206 response correctly.
  - Test `.strm` file with HTTP URL resolves correctly.
  - Test path traversal and malicious redirect rejection (NFR-9).
- **Verification:** `swift test --filter HTTPSourceAdapterTests`
- **Dependencies:** `TASK-1.5.1`

#### [ ] TASK-1.5.3: WebDAV Source Adapter
- **Requirements Ref:** `SRC-2`, `SRC-9`, `SRC-10`, `doc 03 §3`
- **Objective:** Implement WebDAV client adapter supporting `PROPFIND` directory walks, file metadata extraction, and ranged `GET` downloads.
- **Target Files:**
  - `Sources/SourceAdapters/WebDAV/WebDAVSourceAdapter.swift`
  - `Sources/SourceAdapters/WebDAV/WebDAVXMLParser.swift`
  - `Tests/SourceAdaptersTests/WebDAVSourceAdapterTests.swift`
- **Implementation Details:**
  - `PROPFIND` Depth 1 XML response parser extracting display names, sizes, `getlastmodified`, and `getcontenttype`.
  - HTTP basic and digest authentication via Keychain.
- **Unit Tests:**
  - Test parsing multi-status WebDAV XML response.
  - Test directory enumeration yields expected `SourceItem` list.
  - Test ranged download from mock WebDAV server.
- **Verification:** `swift test --filter WebDAVSourceAdapterTests`
- **Dependencies:** `TASK-1.5.1`, `TASK-1.1.2`

#### [ ] TASK-1.5.4: Plex Server Adapter
- **Requirements Ref:** `SRC-1`, `SRC-3`, `SRC-4`, `SRC-6`, `SRC-20`, `doc 03 §2.1`
- **Objective:** Implement Plex Media Server adapter: token authentication, TV PIN linking flow, section enumeration, direct stream URL generation, and watch-state reporting.
- **Target Files:**
  - `Sources/SourceAdapters/Plex/PlexSourceAdapter.swift`
  - `Sources/SourceAdapters/Plex/PlexAPI.swift`
  - `Sources/SourceAdapters/Plex/PlexModels.swift`
  - `Tests/SourceAdaptersTests/PlexSourceAdapterTests.swift`
- **Implementation Details:**
  - Enumerate video sections: `/library/sections`, `/library/all`.
  - Ingest Plex server metadata (TMDB ID links, season/episode hierarchies).
  - Push watch state to `/watchHistory` with offline retry queue.
- **Unit Tests:**
  - Test Plex PIN code generation and verification response parsing.
  - Test section parsing and item conversion.
  - Test DirectStream preference hints.
- **Verification:** `swift test --filter PlexSourceAdapterTests`
- **Dependencies:** `TASK-1.5.1`, `TASK-1.1.2`

#### [ ] TASK-1.5.5: Jellyfin & Emby Server Adapters
- **Requirements Ref:** `SRC-1`, `SRC-3`, `SRC-6`, `SRC-20`, `doc 03 §2.2`, `doc 03 §2.3`
- **Objective:** Implement Jellyfin and Emby adapters using REST API v1 (`X-Emby-Token`), ETag-based freshness checks, and item playback reporting.
- **Target Files:**
  - `Sources/SourceAdapters/Jellyfin/JellyfinSourceAdapter.swift`
  - `Sources/SourceAdapters/Emby/EmbySourceAdapter.swift`
  - `Sources/SourceAdapters/Jellyfin/JellyfinModels.swift`
  - `Tests/SourceAdaptersTests/JellyfinSourceAdapterTests.swift`
- **Implementation Details:**
  - Distinguish Jellyfin vs Emby via `/System/Info/Public`.
  - Enumerate items paged via `/Items` with recursive filters.
  - Report playback progress via `/Sessions/Playing/Progress`.
- **Unit Tests:**
  - Test Jellyfin item tree parsing into shows, seasons, and episodes.
  - Test ETag caching returning not-modified.
  - Test watch state push serialization.
- **Verification:** `swift test --filter JellyfinSourceAdapterTests`
- **Dependencies:** `TASK-1.5.1`, `TASK-1.1.2`

#### [ ] TASK-1.5.6: SMB2/3 File Share Adapter (Phase 1 Priority)
- **Requirements Ref:** `SRC-2`, `SRC-9`, `SRC-10`, `SRC-11`, `ARCH-6`, `doc 03 §3`
- **Objective:** Implement in-process SMB2/3 client adapter supporting NTLMv2 authentication, tree connect, directory enumeration, and ranged reads with reconnect resilience.
- **Target Files:**
  - `Sources/SourceAdapters/SMB/SMBSourceAdapter.swift`
  - `Sources/SourceAdapters/SMB/SMBClient.swift`
  - `Tests/SourceAdaptersTests/SMBSourceAdapterTests.swift`
- **Implementation Details:**
  - Pure-Swift or audited permissive C library (no GPL static linkage per ARCH-6).
  - Exponential backoff and ranged reconnect from current byte position on network blip (SRC-10).
  - Glob filter engine for include/exclude (SRC-11).
- **Unit Tests:**
  - Test SMB connection, authentication handshake, and tree connect against mock SMB service.
  - Test directory walk with exclusion filters (e.g. `*.nfo`, `samples/`).
  - Test ranged byte read and mid-stream resume.
- **Verification:** `swift test --filter SMBSourceAdapterTests`
- **Dependencies:** `TASK-1.5.1`, `TASK-1.1.2`

#### [ ] TASK-1.5.7: NFSv3 File Share Adapter (Phase 1 Priority)
- **Requirements Ref:** `SRC-2`, `SRC-9`, `SRC-10`, `ARCH-6`, `doc 03 §3`
- **Objective:** Implement in-process NFSv3 client adapter supporting RPC/XDR mount, directory walk, and ranged reads.
- **Target Files:**
  - `Sources/SourceAdapters/NFS/NFSSourceAdapter.swift`
  - `Sources/SourceAdapters/NFS/NFSClient.swift`
  - `Tests/SourceAdaptersTests/NFSSourceAdapterTests.swift`
- **Implementation Details:**
  - Implement RPC portmap, mount, and NFS protocol read operations.
  - Ensure zero GPL license contamination.
- **Unit Tests:**
  - Test NFS mount and export directory reading.
  - Test sequential and ranged byte reads.
- **Verification:** `swift test --filter NFSSourceAdapterTests`
- **Dependencies:** `TASK-1.5.1`

#### [ ] TASK-1.5.8: Source Freshness Engine & Library Coordinator
- **Requirements Ref:** `SRC-5`, `SRC-19`, `SRC-20`, `SRC-21`, `MD-12`, `doc 03 §6`
- **Objective:** Implement `SourceSyncCoordinator` managing scheduled syncs, ETag checks, file change detection, rename tracking (SRC-19), and dispatching files to `MediaDatabaseWriter`.
- **Target Files:**
  - `Sources/SourceAdapters/Sync/SourceSyncCoordinator.swift`
  - `Sources/SourceAdapters/Sync/RenameDetector.swift`
  - `Tests/SourceAdaptersTests/SourceSyncCoordinatorTests.swift`
- **Implementation Details:**
  - Periodic poll, webhook trigger, or manual "Check for updates".
  - Detect file renames via file size + duration + container probe to preserve watch state (SRC-19).
- **Unit Tests:**
  - Test rename detection matches moved file and preserves `file_id`.
  - Test incremental sync only processes changed mtime/ETag files.
- **Verification:** `swift test --filter SourceSyncCoordinatorTests`
- **Dependencies:** `TASK-1.5.2`, `TASK-1.3.5`

---

### Workstream 1.6: PlaybackKit (Engine, Planner & Pipelines)

#### [ ] TASK-1.6.1: MediaGraph Demux & Stream Probe
- **Requirements Ref:** `PB-3`, `DB-5`, `doc 04 §2`, `doc 04 §4.1`
- **Objective:** Implement `MediaGraph` probe inspecting containers and streams using `AVFoundation` for Apple native containers and `FFmpeg` (`avformat`) for MKV/AVI/WebM.
- **Target Files:**
  - `Sources/PlaybackKit/MediaGraph/MediaGraph.swift`
  - `Sources/PlaybackKit/MediaGraph/StreamProbe.swift`
  - `Sources/PlaybackKit/Models/MediaTrackInfo.swift`
  - `Tests/PlaybackKitTests/MediaGraphTests.swift`
- **Implementation Details:**
  - Extract video codecs (H.264, HEVC, AV1, VP9), profile, level, dimensions, FPS, bit depth, color primaries, transfer characteristics, matrix, HDR format (`hdr10`, `hdr10plus`, `dovi:5`, `dovi:8`, `dovi:8.1`, `hlg`, `sdr`).
  - Extract audio codecs, channel layouts, sample rates.
  - Extract embedded subtitles and chapter marks.
- **Unit Tests:**
  - Test probing MP4/MOV assets via AVFoundation.
  - Test probing MKV with Dolby Vision Profile 8.1 and Atmos via FFmpeg demuxer.
  - Test populating `TrackRecord` records for insertion into `LibraryCore`.
- **Verification:** `swift test --filter MediaGraphTests`
- **Dependencies:** `TASK-0.3`, `TASK-1.3.5`

#### [ ] TASK-1.6.2: Sink Profile & Display Negotiation
- **Requirements Ref:** `PB-4`, `PB-6`, `doc 04 §3`
- **Objective:** Implement `SinkProfileManager` capturing display capabilities (SDR / HDR10 / Dolby Vision, resolution, refresh rate) and audio output routing (Stereo / 5.1 / Atmos / HomePod).
- **Target Files:**
  - `Sources/PlaybackKit/Sink/SinkProfileManager.swift`
  - `Sources/PlaybackKit/Sink/SinkProfile.swift`
  - `Tests/PlaybackKitTests/SinkProfileTests.swift`
- **Implementation Details:**
  - Observe `UIScreen.mode`, active format changes, and `AVAudioSession` route changes.
  - Support user-declared overrides from Settings ("My TV supports Dolby Vision", "My receiver is 5.1 AC3").
- **Unit Tests:**
  - Test profile creation from system defaults.
  - Test user override takes precedence over auto-detected capabilities.
  - Test audio route change notification triggers recalculation.
- **Verification:** `swift test --filter SinkProfileTests`
- **Dependencies:** `TASK-1.2.3`

#### [ ] TASK-1.6.3: PipelinePlanner Decision Ladder (Rungs R1–R5)
- **Requirements Ref:** `ARCH-P5`, `ARCH-P6`, `PB-G2`, `PB-G3`, `PB-5`, `PB-6`, `doc 04 §4`
- **Objective:** Implement `PipelinePlanner` selecting the optimal, lowest-cost playback path: R1 (Direct Play) $\to$ R2 (Remux) $\to$ R3 (Hardware Transcode) $\to$ R4 (Software Transcode) $\to$ R5 (Server Transcode).
- **Target Files:**
  - `Sources/PlaybackKit/Planner/PipelinePlanner.swift`
  - `Sources/PlaybackKit/Planner/PipelinePlan.swift`
  - `Sources/PlaybackKit/Planner/QualityBadge.swift`
  - `Tests/PlaybackKitTests/PipelinePlannerTests.swift`
- **Implementation Details:**
  - Evaluate inputs: `MediaGraph` + `SinkProfile` + `CapabilityRegistry` + `UserPrefs`.
  - Color is planned as a video decision; audio is planned independently.
  - Produce serializable `PipelinePlan` containing rung, reason strings, in/out codecs, and badge metadata (`Direct` (green), `Remuxed` (blue), `Transcoded · HW` (amber), `Transcoded · SW` (orange), `Server` (gray)).
- **Unit Tests:**
  - Test MP4 H.264 on SDR TV selects R1 (Direct Play).
  - Test MKV HEVC on HDR TV selects R2 (Remux to fMP4).
  - Test 4K DoVi Profile 8 MKV on SDR TV selects R2/R3 with system tone-mapping.
  - Test gen 3 playing AV1 selects R4 (Software Transcode via FFmpeg).
  - Test gen 4 playing AV1 selects R1/R2 (Hardware Decode on A19).
  - Test user quality lock caps the maximum ladder rung.
- **Verification:** `swift test --filter PipelinePlannerTests`
- **Dependencies:** `TASK-1.6.1`, `TASK-1.6.2`, `TASK-1.2.3`

#### [ ] TASK-1.6.4: R1 Direct Play Pipeline (AVPlayerViewController)
- **Requirements Ref:** `PB-G2`, `doc 04 §4.2`, `doc 06 §2.4`
- **Objective:** Implement R1 direct play pipeline wrapping `AVPlayer` and `AVPlayerItem` with custom resource loader for ranged network streams.
- **Target Files:**
  - `Sources/PlaybackKit/Pipelines/DirectPlayPipeline.swift`
  - `Sources/PlaybackKit/Pipelines/CustomResourceLoaderDelegate.swift`
  - `Tests/PlaybackKitTests/DirectPlayPipelineTests.swift`
- **Implementation Details:**
  - Feed `SourceAdapter.read()` byte ranges into `AVAssetResourceLoaderDelegate`.
  - Track playback timing, buffer health, and stall events.
- **Unit Tests:**
  - Test resource loader answers data requests with byte ranges from source stream.
  - Test seek request cancels previous stream and starts from requested offset.
- **Verification:** `swift test --filter DirectPlayPipelineTests`
- **Dependencies:** `TASK-1.6.3`, `TASK-1.5.1`

#### [ ] TASK-1.6.5: R2 Remux Pipeline (fMP4 Packager)
- **Requirements Ref:** `PB-3`, `doc 04 §4.2`, `doc 02 §3`
- **Objective:** Implement R2 remux pipeline: demux non-Apple container (MKV/WebM) via FFmpeg `libavformat` and repackage video/audio packets into fragmented MP4 (fMP4) stream fed into `AVPlayer`.
- **Target Files:**
  - `Sources/PlaybackKit/Pipelines/RemuxPipeline.swift`
  - `Sources/PlaybackKit/Packaging/FMP4Packager.swift`
  - `Tests/PlaybackKitTests/RemuxPipelineTests.swift`
- **Implementation Details:**
  - Zero re-encoding of video/audio bitstreams.
  - Strip Dolby Vision RPU if outputting to HDR10-only display (PB-G4).
- **Unit Tests:**
  - Test packaging H.264 and HEVC NAL units into valid ISO-BMFF `moof`/`mdat` atoms.
  - Test timeline continuity and DTS/PTS synchronization.
- **Verification:** `swift test --filter RemuxPipelineTests`
- **Dependencies:** `TASK-1.6.4`, `TASK-0.3`

#### [ ] TASK-1.6.6: R3 Hardware Transcode Pipeline (VideoToolbox & Metal)
- **Requirements Ref:** `ARCH-P6`, `PB-G2`, `PB-16`, `PB-17`, `doc 04 §4.2`, `doc 04 §7`
- **Objective:** Implement R3 hardware transcode pipeline: VideoToolbox decode $\to$ Metal color transform / tone-map $\to$ VideoToolbox encode / ASBDL render.
- **Target Files:**
  - `Sources/PlaybackKit/Pipelines/HardwareTranscodePipeline.swift`
  - `Sources/PlaybackKit/Color/MetalToneMapper.swift`
  - `Sources/PlaybackKit/Color/Shaders.metal`
  - `Tests/PlaybackKitTests/HardwareTranscodePipelineTests.swift`
- **Implementation Details:**
  - Metal compute shader implementing PQ/HLG to BT.1886/sRGB tone-mapping with configurable target nits (doc 04 §7).
  - Render frames directly to `AVSampleBufferDisplayLayer` (ASBDL).
- **Unit Tests:**
  - Test Metal tone mapper shader compiles and executes on test pixel buffer.
  - Test VideoToolbox compression session produces valid 10-bit HEVC frames.
- **Verification:** `swift test --filter HardwareTranscodePipelineTests`
- **Dependencies:** `TASK-1.6.3`

#### [ ] TASK-1.6.7: R4 Software Transcode Pipeline (FFmpeg & openh264)
- **Requirements Ref:** `ARCH-P6`, `PB-G2`, `PB-24`, `doc 04 §4.2`
- **Objective:** Implement R4 software transcode pipeline for codecs lacking hardware support (AV1 on gen 2/3, VP9, MPEG-2, VC-1) using FFmpeg software decode $\to$ Metal $\to$ VideoToolbox/openh264 encode.
- **Target Files:**
  - `Sources/PlaybackKit/Pipelines/SoftwareTranscodePipeline.swift`
  - `Sources/PlaybackKit/FFmpeg/FFmpegDecoder.swift`
  - `Tests/PlaybackKitTests/SoftwareTranscodePipelineTests.swift`
- **Implementation Details:**
  - Worker thread pool bounded to $\le 60\%$ CPU in `balanced` quality bias (PB-24).
  - Automatically drop resolution from 4K to 1080p if `ThermalMonitor` enters `.serious` state.
- **Unit Tests:**
  - Test software decoding of VP9 sample frames into raw `CVPixelBuffer`.
  - Test thermal downgrade reduces target resolution.
- **Verification:** `swift test --filter SoftwareTranscodePipelineTests`
- **Dependencies:** `TASK-1.6.6`, `TASK-0.3`, `TASK-1.1.4`

#### [ ] TASK-1.6.8: Audio Pipeline & Downmix Matrix
- **Requirements Ref:** `PB-5`, `PB-11`, `PB-12`, `PB-14`, `doc 04 §6`
- **Objective:** Implement audio pipeline handling passthrough (AC3/E-AC3 Atmos), hardware decode (AAC, PCM, FLAC), and software decode (DTS, TrueHD) with ITU BS.775 downmix to stereo or 5.1.
- **Target Files:**
  - `Sources/PlaybackKit/Audio/AudioPipeline.swift`
  - `Sources/PlaybackKit/Audio/AudioDownmixMatrix.swift`
  - `Sources/PlaybackKit/Audio/PassthroughMonitor.swift`
  - `Tests/PlaybackKitTests/AudioPipelineTests.swift`
- **Implementation Details:**
  - Detect audio passthrough failure (silence detection within 2 s) and automatically fall back to decode + downmix (PB-11).
  - Downmix presets: stereo (BS.775 with dialog center enhancement), 5.1 bed.
- **Unit Tests:**
  - Test 7.1 TrueHD to 2.0 stereo BS.775 matrix math preserves dialog balance.
  - Test silence detector triggers fallback after 2 seconds without audio session activity.
- **Verification:** `swift test --filter AudioPipelineTests`
- **Dependencies:** `TASK-1.6.3`

#### [ ] TASK-1.6.9: Subtitle Parser & Rendering Engine
- **Requirements Ref:** `PB-1`, `PB-2`, `doc 04 §2.3`
- **Objective:** Implement subtitle demuxing and rendering for text-based formats (SRT, WebVTT, ASS/SSA) and image-based formats (PGS/SUP, VobSub) synchronized to $\pm 1$ frame.
- **Target Files:**
  - `Sources/PlaybackKit/Subtitles/SubtitleEngine.swift`
  - `Sources/PlaybackKit/Subtitles/Parsers/SRTParser.swift`
  - `Sources/PlaybackKit/Subtitles/Parsers/ASSParser.swift`
  - `Sources/PlaybackKit/Subtitles/Renderers/MetalSubtitleRenderer.swift`
  - `Tests/PlaybackKitTests/SubtitleEngineTests.swift`
- **Implementation Details:**
  - Render text and image subtitles via Metal overlay layer above video layer.
  - Support styling controls: font size ($\pm$), position, opacity, color, and forced-only filter (PB-2).
- **Unit Tests:**
  - Test SRT and WebVTT timestamp parsing and cue extraction.
  - Test PGS bitmap decompression and positioning.
  - Test forced subtitle filtering toggle.
- **Verification:** `swift test --filter SubtitleEngineTests`
- **Dependencies:** `TASK-1.6.3`

#### [ ] TASK-1.6.10: PlaybackSession Coordinator & Watch-State Flusher
- **Requirements Ref:** `PB-18`, `PB-19`, `PB-20`, `PB-21`, `PB-22`, `MD-6`, `NFR-16`, `doc 04 §8`
- **Objective:** Implement `PlaybackSession` coordinator managing play, pause, seek, audio/video drift correction ($\le 40$ ms), and periodic watch-state flushes (1 s in-memory, 10 s to database).
- **Target Files:**
  - `Sources/PlaybackKit/Session/PlaybackSession.swift`
  - `Sources/PlaybackKit/Session/WatchStateReporter.swift`
  - `Tests/PlaybackKitTests/PlaybackSessionTests.swift`
- **Implementation Details:**
  - Mark watched automatically at $\ge 90\%$ duration (MD-6).
  - Flush progress to `MediaDatabaseWriter` on 10 s timer and app suspension.
- **Unit Tests:**
  - Test watch state marks item watched at 90% and keeps unwatched at 4%.
  - Test 10-second flush schedule writes to database.
  - Test A/V clock drift measurement and gentle audio stretch correction.
- **Verification:** `swift test --filter PlaybackSessionTests`
- **Dependencies:** `TASK-1.6.4`, `TASK-1.3.5`

#### [ ] TASK-1.6.11: Quality Badge & Pipeline Detail View Model
- **Requirements Ref:** `PRD-D1`, `PB-5`, `UI-3`, `doc 01 §2`, `doc 06 §2.4`
- **Objective:** Implement view model generating the honest quality badge and expandable pipeline detail sheet (in/out codec, color transform, audio path, reasons, thermal state).
- **Target Files:**
  - `Sources/PlaybackKit/ViewModels/QualityBadgeViewModel.swift`
  - `Tests/PlaybackKitTests/QualityBadgeViewModelTests.swift`
- **Implementation Details:**
  - Generate plain-language summary with technical drill-down.
  - Provide "Lock this path" user action.
- **Unit Tests:**
  - Test badge color and label for all rungs (Direct: green, Remux: blue, HW Transcode: amber, SW Transcode: orange, Server: gray).
  - Test explanation string formatting for complex DoVi $\to$ SDR tone-map.
- **Verification:** `swift test --filter QualityBadgeViewModelTests`
- **Dependencies:** `TASK-1.6.3`

---

### Workstream 1.7: tvOS App Shell & UI (10-Foot Design)

#### [ ] TASK-1.7.1: tvOS Design System & Focus Foundation
- **Requirements Ref:** `doc 06 §1`, `UI-1`, `UI-4`, `UI-7`
- **Objective:** Create SwiftUI 10-foot design system tokens (colors, typography, 12-pt grid, focus scaling 1.06x, dark-first HDR-safe palettes) and custom focus wrapper.
- **Target Files:**
  - `Sources/PlayItRight/Theme/DesignTokens.swift`
  - `Sources/PlayItRight/Theme/FocusableCard.swift`
  - `Tests/PlayItRightTests/DesignTokensTests.swift`
- **Implementation Details:**
  - Support Reduce Motion accessibility toggle (crossfade instead of parallax).
  - High-contrast mode and VoiceOver accessibility traits on focusable elements.
- **Unit Tests:**
  - Test color contrast ratios meet WCAG AA standards in dark mode.
  - Test focus card accessibility labels and hints.
- **Verification:** `swift test --filter DesignTokensTests`
- **Dependencies:** `TASK-1.1.1`

#### [ ] TASK-1.7.2: First-Launch Onboarding View
- **Requirements Ref:** `UI-1`, `doc 06 §2.1`
- **Objective:** Implement 3-question sink setup (Display: SDR/HDR/DoVi, Audio: Stereo/5.1/Atmos/HomePod, Source type) and initial source connection flow culminating in instant first playback.
- **Target Files:**
  - `Sources/PlayItRight/Views/Onboarding/OnboardingView.swift`
  - `Sources/PlayItRight/Views/Onboarding/SinkSetupView.swift`
  - `Sources/PlayItRight/Views/Onboarding/InitialSourceView.swift`
  - `Tests/PlayItRightTests/OnboardingViewModelTests.swift`
- **Implementation Details:**
  - Save answers to `SinkProfileManager` and Keychain.
  - Guide user to connect first source with immediate progress counts.
- **Unit Tests:**
  - Test onboarding view model saves completed sink profile to database and preferences.
- **Verification:** `swift test --filter OnboardingViewModelTests`
- **Dependencies:** `TASK-1.6.2`, `TASK-1.7.1`

#### [ ] TASK-1.7.3: Home View & Continue Watching Row
- **Requirements Ref:** `MD-9`, `doc 06 §2.2`
- **Objective:** Implement tvOS Home view with reorderable shelves: "Continue Watching" (with circular progress indicators), "Recently Added", and per-library shelves.
- **Target Files:**
  - `Sources/PlayItRight/Views/Home/HomeView.swift`
  - `Sources/PlayItRight/Views/Home/ContinueWatchingRow.swift`
  - `Sources/PlayItRight/ViewModels/HomeViewModel.swift`
  - `Tests/PlayItRightTests/HomeViewModelTests.swift`
- **Implementation Details:**
  - Keyset-paginated queries backed by `MediaDatabaseReader`.
  - Empty state with "Add a source" card.
- **Unit Tests:**
  - Test home view model loads continue watching items in descending `last_watched_at` order.
  - Test progress ring percentage calculation.
- **Verification:** `swift test --filter HomeViewModelTests`
- **Dependencies:** `TASK-1.3.6`, `TASK-1.7.1`

#### [ ] TASK-1.7.4: Library Grid & List Views
- **Requirements Ref:** `MD-11`, `NFR-1`, `doc 06 §2.3`
- **Objective:** Implement virtualized poster grid and list views with corner tech badges (`4K`, `DoVi`, `Atmos`), watched indicators, and sort/density options.
- **Target Files:**
  - `Sources/PlayItRight/Views/Library/LibraryGridView.swift`
  - `Sources/PlayItRight/Views/Library/LibraryListView.swift`
  - `Sources/PlayItRight/Views/Library/MediaCardView.swift`
  - `Sources/PlayItRight/ViewModels/LibraryViewModel.swift`
  - `Tests/PlayItRightTests/LibraryViewModelTests.swift`
- **Implementation Details:**
  - Efficient virtualization holding 60 FPS scrolling over 10,000 items (NFR-1).
  - Keyset pagination with `limit: 50`.
- **Unit Tests:**
  - Test pagination loading triggers next page when reaching shelf boundary.
  - Test sorting by title, year, date added, and rating.
- **Verification:** `swift test --filter LibraryViewModelTests`
- **Dependencies:** `TASK-1.3.6`, `TASK-1.4.5`

#### [ ] TASK-1.7.5: Filter Bar & Smart Library Save View
- **Requirements Ref:** `MD-4`, `doc 05 §4`, `doc 06 §2.3`
- **Objective:** Implement library filter bar (source, watched status, genre, resolution, codec, HDR) and ability to save active filters as a Smart Library.
- **Target Files:**
  - `Sources/PlayItRight/Views/Library/LibraryFilterBar.swift`
  - `Sources/PlayItRight/Views/Library/SaveSmartLibrarySheet.swift`
  - `Tests/PlayItRightTests/FilterBarViewModelTests.swift`
- **Implementation Details:**
  - Compile selected chips into `SmartLibraryFilter` definition.
  - Save to `smart_libraries` table in `LibraryCore`.
- **Unit Tests:**
  - Test filter bar toggles generate matching SQL predicate.
  - Test saving and recalling Smart Library configuration.
- **Verification:** `swift test --filter FilterBarViewModelTests`
- **Dependencies:** `TASK-1.3.6`

#### [ ] TASK-1.7.6: Movie & TV Show Detail Views
- **Requirements Ref:** `doc 06 §2.3`, `doc 05 §2`, `DB-4`
- **Objective:** Implement rich detail screens: full-bleed hero backdrop, title, overview, cast & crew shelf with headshots, technical metadata badges (clickable to pipeline explainer), audio/subtitle tracks preview, and action buttons ("Play", "Mark Watched", "Add to Collection").
- **Target Files:**
  - `Sources/PlayItRight/Views/Detail/MovieDetailView.swift`
  - `Sources/PlayItRight/Views/Detail/ShowDetailView.swift`
  - `Sources/PlayItRight/Views/Detail/SeasonEpisodePicker.swift`
  - `Sources/PlayItRight/ViewModels/DetailViewModel.swift`
  - `Tests/PlayItRightTests/DetailViewModelTests.swift`
- **Implementation Details:**
  - Cast row displays top 6 billed actors with links to full cast tab.
  - For TV shows: season selector, episode list with progress bars, and "Play Next Unwatched" primary CTA.
- **Unit Tests:**
  - Test detail view model loads movie and associated media files.
  - Test TV show resolves next unwatched episode correctly.
- **Verification:** `swift test --filter DetailViewModelTests`
- **Dependencies:** `TASK-1.3.6`, `TASK-1.4.5`

#### [ ] TASK-1.7.7: Video Player Overlay & Remote Interaction
- **Requirements Ref:** `UI-1`, `UI-2`, `doc 06 §2.4`
- **Objective:** Implement tvOS player controls overlay: auto-hide timer (3 s), scrub bar with chapter markers, play/pause, $\pm 10$ s skip, next/prev chapter, audio and subtitle menus, and Siri Remote clickpad bindings.
- **Target Files:**
  - `Sources/PlayItRight/Views/Player/PlayerOverlayView.swift`
  - `Sources/PlayItRight/Views/Player/CustomScrubberBar.swift`
  - `Sources/PlayItRight/Views/Player/AudioSubtitleMenu.swift`
  - `Tests/PlayItRightTests/PlayerOverlayViewModelTests.swift`
- **Implementation Details:**
  - Non-blocking remote gesture handlers (long-press, double-tap, swipe-to-scrub).
  - Game controller and Bluetooth keyboard support (UI-1).
- **Unit Tests:**
  - Test auto-hide timer resets on user interaction.
  - Test scrub bar seek event debouncing.
- **Verification:** `swift test --filter PlayerOverlayViewModelTests`
- **Dependencies:** `TASK-1.6.10`

#### [ ] TASK-1.7.8: Quality Badge Overlay & Pipeline Sheet
- **Requirements Ref:** `PRD-D1`, `PB-5`, `UI-3`, `doc 01 §2`, `doc 06 §2.4`
- **Objective:** Implement quality badge in top-right of player (subtle, dimmable) and modal pipeline sheet detailing decoding, color transformation, audio mixing, and thermal status.
- **Target Files:**
  - `Sources/PlayItRight/Views/Player/QualityBadgeView.swift`
  - `Sources/PlayItRight/Views/Player/PipelineDetailSheet.swift`
  - `Tests/PlayItRightTests/PipelineDetailSheetTests.swift`
- **Implementation Details:**
  - Focusable badge opens pipeline sheet.
  - Includes user action: "Lock this path for this source / codec".
- **Unit Tests:**
  - Test pipeline sheet renders correct explanations for R1, R2, R3, R4, R5.
  - Test lock action invokes `PipelinePlanner` preference update.
- **Verification:** `swift test --filter PipelineDetailSheetTests`
- **Dependencies:** `TASK-1.6.11`

#### [ ] TASK-1.7.9: Settings & Capability Sheet View
- **Requirements Ref:** `UI-3`, `doc 06 §2.5`
- **Objective:** Implement comprehensive settings: Sources management, Playback preferences (display profile, audio setup, quality bias), Library settings (cache size, rescan), Privacy & Diagnostics, and "About This Apple TV" (visual hardware capability sheet).
- **Target Files:**
  - `Sources/PlayItRight/Views/Settings/SettingsView.swift`
  - `Sources/PlayItRight/Views/Settings/CapabilitySheetView.swift`
  - `Sources/PlayItRight/Views/Settings/SourceManagementView.swift`
  - `Tests/PlayItRightTests/SettingsViewModelTests.swift`
- **Implementation Details:**
  - "About This Apple TV" renders active `CapabilityRegistry` facts with plain-language explanations.
  - Artwork cache clear action with current byte usage indicator.
- **Unit Tests:**
  - Test settings modifications persist to database and configuration files.
  - Test cache clear triggers `ArtworkCache.clear()`.
- **Verification:** `swift test --filter SettingsViewModelTests`
- **Dependencies:** `TASK-1.2.3`, `TASK-1.4.5`

#### [ ] TASK-1.7.10: Search & Unmatched Media Review Views
- **Requirements Ref:** `MD-1`, `MD-2`, `doc 05 §1`, `doc 06 §2.6`
- **Objective:** Implement instant search interface (FTS5 local index $\le 300$ ms per keystroke) and "Fix Matching" view allowing users to resolve unmatched or low-confidence media items.
- **Target Files:**
  - `Sources/PlayItRight/Views/Search/SearchView.swift`
  - `Sources/PlayItRight/Views/Search/FixMatchingView.swift`
  - `Sources/PlayItRight/ViewModels/SearchViewModel.swift`
  - `Tests/PlayItRightTests/SearchViewModelTests.swift`
- **Implementation Details:**
  - Real-time debounced query execution using `MediaDatabaseReader.search()`.
  - Fix matching view presents candidate titles from TMDB search with poster previews.
- **Unit Tests:**
  - Test search results update on keystroke with prefix token matching.
  - Test manual match selection updates `media_files.matched_movie` and records `matchOverride`.
- **Verification:** `swift test --filter SearchViewModelTests`
- **Dependencies:** `TASK-1.3.6`, `TASK-1.4.3`

#### [ ] TASK-1.7.11: Diagnostics Export & Error Recovery Card
- **Requirements Ref:** `NFR-12`, `NFR-15`, `doc 06 §2.4`, `doc 09 §4`
- **Objective:** Implement playback error recovery card ("Try software", "Try server transcode", "Report diagnostics") and user-initiated diagnostic report export.
- **Target Files:**
  - `Sources/PlayItRight/Views/Player/PlaybackErrorCard.swift`
  - `Sources/PlayItRight/Views/Settings/DiagnosticsExportView.swift`
  - `Tests/PlayItRightTests/DiagnosticsExportTests.swift`
- **Implementation Details:**
  - Graceful recovery: on unrecoverable decode error, offer next lower rung automatically or via error card.
  - Export diagnostics to local file shareable via AirDrop/Files app.
- **Unit Tests:**
  - Test diagnostic package generation produces valid redacted JSON report.
- **Verification:** `swift test --filter DiagnosticsExportTests`
- **Dependencies:** `TASK-1.1.3`, `TASK-1.6.10`

---

### Workstream 1.8: Alpha Conformance & Verification Gate

#### [ ] TASK-1.8.1: Media Test Asset Fixtures & Conformance Suite
- **Requirements Ref:** `NFR-25`, `PB-G1`, `PB-G2`, `doc 09 §8`, `doc 10 §Phase 1`
- **Objective:** Create automated test suite running against real mini-assets ($\le 5$ MB) covering H.264, HEVC 8/10-bit, HDR10, HLG, Dolby Vision Profile 5/8/8.1, AAC, AC3, and E-AC3 Atmos.
- **Target Files:**
  - `Tests/ConformanceTests/PlaybackConformanceTests.swift`
  - `Tests/ConformanceTests/AssetRegistry.swift`
- **Implementation Details:**
  - Assert playback starts within target latency ($\le 2$ s local).
  - Assert correct pipeline rung is selected.
  - Assert quality badge matches plan.
- **Unit Tests:**
  - Run all conformance matrix assertions in CI test runner.
- **Verification:** `swift test --filter PlaybackConformanceTests`
- **Dependencies:** `TASK-1.6.10`, `TASK-1.6.3`

---

## 5. Phase 2 — Public Beta (Pro Formats, Cloud, Sync, & Monetization)

### Workstream 2.1: Pro Tier Codecs & Software Decoders

#### [ ] TASK-2.1.1: Extended Video Codecs (AV1, VP8/VP9, VVC, VC-1, MPEG-2)
- **Requirements Ref:** `PB-G2`, `doc 04 §2.1`, `doc 08 §1`
- **Objective:** Integrate software decode paths via FFmpeg for AV1 (on gen 2/3), VP8/VP9, VVC/H.266, VC-1, MPEG-1/2, WMV, and DivX/Xvid.
- **Target Files:**
  - `Sources/PlaybackKit/FFmpeg/ExtendedCodecsDecoder.swift`
  - `Tests/PlaybackKitTests/ExtendedCodecsTests.swift`
- **Unit Tests:**
  - Test decoding frames for each extended codec format.
  - Test gating extended codecs behind Pro entitlement.
- **Verification:** `swift test --filter ExtendedCodecsTests`
- **Dependencies:** `TASK-1.6.7`

#### [ ] TASK-2.1.2: HD Audio Decoders (DTS, DTS-HD MA, Dolby TrueHD)
- **Requirements Ref:** `PB-12`, `doc 04 §2.2`, `doc 08 §1`
- **Objective:** Implement software decoders for DTS, DTS-HD Master Audio, and Dolby TrueHD with downmixing to 5.1/stereo LPCM.
- **Target Files:**
  - `Sources/PlaybackKit/Audio/HDAudioDecoder.swift`
  - `Tests/PlaybackKitTests/HDAudioDecoderTests.swift`
- **Unit Tests:**
  - Test DTS-HD MA bitstream decoding into multi-channel float buffers.
  - Test TrueHD Atmos bed extraction.
- **Verification:** `swift test --filter HDAudioDecoderTests`
- **Dependencies:** `TASK-1.6.8`

#### [ ] TASK-2.1.3: Disc Images & Folder Playback (ISO, BDMV, VIDEO_TS)
- **Requirements Ref:** `SRC-17`, `PB-3`, `doc 03 §5`, `doc 04 §2.1`
- **Objective:** Implement virtual disc image reader mounting `.iso`/`.img` and `BDMV`/`VIDEO_TS` folders as playable titles with playlist and title selection.
- **Target Files:**
  - `Sources/SourceAdapters/Disc/DiscImageAdapter.swift`
  - `Sources/SourceAdapters/Disc/ISO9660Parser.swift`
  - `Sources/SourceAdapters/Disc/BDMVParser.swift`
  - `Tests/SourceAdaptersTests/DiscImageAdapterTests.swift`
- **Unit Tests:**
  - Test ISO 9660 filesystem header parsing and file extraction.
  - Test BDMV `index.bdmv` title playlist enumeration.
- **Verification:** `swift test --filter DiscImageAdapterTests`
- **Dependencies:** `TASK-1.5.1`

---

### Workstream 2.2: Cloud Drives & Network Protocols (Pro)

#### [ ] TASK-2.2.1: Cloud Drive OAuth 2.0 Engine (Device Code Flow)
- **Requirements Ref:** `SRC-12`, `doc 03 §4`
- **Objective:** Implement OAuth 2.0 device authorization grant flow (RFC 8628) for 10-foot TV: display verification URI and user code, poll for tokens, and store in Keychain.
- **Target Files:**
  - `Sources/SourceAdapters/Cloud/OAuthDeviceFlow.swift`
  - `Tests/SourceAdaptersTests/OAuthDeviceFlowTests.swift`
- **Unit Tests:**
  - Test device code response parsing, polling interval timer, and token refresh.
- **Verification:** `swift test --filter OAuthDeviceFlowTests`
- **Dependencies:** `TASK-1.1.2`

#### [ ] TASK-2.2.2: Cloud Drive Adapters (Google Drive, Dropbox, OneDrive, Box)
- **Requirements Ref:** `SRC-12`, `SRC-13`, `SRC-14`, `doc 03 §4`
- **Objective:** Implement ranged-streaming cloud storage adapters for Google Drive, Dropbox, OneDrive, and Box without requiring full file downloads.
- **Target Files:**
  - `Sources/SourceAdapters/Cloud/GoogleDriveAdapter.swift`
  - `Sources/SourceAdapters/Cloud/DropboxAdapter.swift`
  - `Sources/SourceAdapters/Cloud/OneDriveAdapter.swift`
  - `Sources/SourceAdapters/Cloud/BoxAdapter.swift`
  - `Tests/SourceAdaptersTests/CloudAdaptersTests.swift`
- **Unit Tests:**
  - Test folder hierarchy enumeration and file stream range requests for each provider.
- **Verification:** `swift test --filter CloudAdaptersTests`
- **Dependencies:** `TASK-2.2.1`

#### [ ] TASK-2.2.3: FTP / FTPS / SFTP Source Adapters
- **Requirements Ref:** `SRC-2`, `SRC-9`, `doc 03 §3`
- **Objective:** Implement FTP, FTPS (explicit/implicit TLS), and SFTP (SSH-2) source adapters with directory walks and ranged reads.
- **Target Files:**
  - `Sources/SourceAdapters/FTP/FTPSourceAdapter.swift`
  - `Sources/SourceAdapters/SFTP/SFTPSourceAdapter.swift`
  - `Tests/SourceAdaptersTests/FTPSourceAdapterTests.swift`
- **Unit Tests:**
  - Test directory parsing (UNIX and Windows format) and ranged byte retrieval.
- **Verification:** `swift test --filter FTPSourceAdapterTests`
- **Dependencies:** `TASK-1.5.1`

#### [ ] TASK-2.2.4: UPnP / DLNA Discovery & Browse Adapter
- **Requirements Ref:** `SRC-9`, `doc 03 §3`
- **Objective:** Implement SSDP discovery (`M-SEARCH`) and ContentDirectory SOAP browse client for UPnP/DLNA servers.
- **Target Files:**
  - `Sources/SourceAdapters/UPnP/SSDPDiscovery.swift`
  - `Sources/SourceAdapters/UPnP/UPnPBrowseAdapter.swift`
  - `Tests/SourceAdaptersTests/UPnPAdapterTests.swift`
- **Unit Tests:**
  - Test SSDP advertisement packet parsing.
  - Test DIDL-Lite XML response parsing into media items.
- **Verification:** `swift test --filter UPnPAdapterTests`
- **Dependencies:** `TASK-1.5.1`

---

### Workstream 2.3: CloudKit SyncKit & Multi-Device Continuity

#### [ ] TASK-2.3.1: CloudKit Record Schema & Zone Manager
- **Requirements Ref:** `SYNC-1`, `SYNC-2`, `doc 07 §1`, `doc 11 §3.3`
- **Objective:** Define CloudKit custom zone and record converters for `watchState`, `userRating`, `matchOverride`, `library`, `collection`, `playlist`, and `pin`.
- **Target Files:**
  - `Sources/SyncKit/CloudKit/CloudKitZoneManager.swift`
  - `Sources/SyncKit/Models/CloudKitRecords.swift`
  - `Tests/SyncKitTests/CloudKitZoneManagerTests.swift`
- **Implementation Details:**
  - Strictly enforce sync boundary: provider metadata, media file paths, and credentials NEVER sync.
- **Unit Tests:**
  - Test encoding and decoding domain entities to/from `CKRecord`.
  - Assert sensitive fields are rejected from serialization.
- **Verification:** `swift test --filter CloudKitZoneManagerTests`
- **Dependencies:** `TASK-1.3.4`

#### [ ] TASK-2.3.2: SyncEngine & Offline Delta Queue
- **Requirements Ref:** `SYNC-2`, `SYNC-3`, `doc 07 §1.2`
- **Objective:** Implement `SyncEngine` using `CKSyncEngine` pattern with persistent local delta queue, network reachability listener, and exponential retry.
- **Target Files:**
  - `Sources/SyncKit/Engine/SyncEngine.swift`
  - `Sources/SyncKit/Engine/DeltaQueue.swift`
  - `Tests/SyncKitTests/SyncEngineTests.swift`
- **Unit Tests:**
  - Test offline writes accumulate in delta queue and flush on reconnect.
  - Test batching envelope ($\le 1$ write / 30 s / item).
- **Verification:** `swift test --filter SyncEngineTests`
- **Dependencies:** `TASK-2.3.1`, `TASK-1.3.5`

#### [ ] TASK-2.3.3: Conflict Resolution & Multi-Apple TV Resume
- **Requirements Ref:** `SYNC-2`, `SYNC-4`, `SYNC-9`, `doc 07 §1.2`
- **Objective:** Implement deterministic merge rules: scalar last-writer-wins, watch position = max(`position`) with recency guard, and cross-Apple TV resume synchronization.
- **Target Files:**
  - `Sources/SyncKit/Merge/ConflictResolver.swift`
  - `Tests/SyncKitTests/ConflictResolverTests.swift`
- **Unit Tests:**
  - Test conflict resolution when remote progress is newer than local.
  - Test conflict resolution when playback was reset to 0:00 (recency guard).
- **Verification:** `swift test --filter ConflictResolverTests`
- **Dependencies:** `TASK-2.3.2`

---

### Workstream 2.4: Casting, AirPlay & Long-Tail Subtitles

#### [ ] TASK-2.4.1: AirPlay Audio & Video Route Integration
- **Requirements Ref:** `SYNC-6`, `doc 07 §2`
- **Objective:** Integrate `AVRoutePickerView` and route change observers for HomePod audio streaming and Apple TV video routing.
- **Target Files:**
  - `Sources/PlaybackKit/Casting/AirPlayController.swift`
  - `Tests/PlaybackKitTests/AirPlayControllerTests.swift`
- **Unit Tests:**
  - Test audio route change updates `SinkProfile` and triggers planner re-evaluation.
- **Verification:** `swift test --filter AirPlayControllerTests`
- **Dependencies:** `TASK-1.6.2`

#### [ ] TASK-2.4.2: Google Cast Sender Integration (Pro)
- **Requirements Ref:** `SYNC-7`, `SYNC-8`, `doc 07 §3`
- **Objective:** Implement Google Cast sender for tvOS streaming compatible video/audio streams to Chromecast devices with plain-language failure explanations.
- **Target Files:**
  - `Sources/PlaybackKit/Casting/GoogleCastController.swift`
  - `Tests/PlaybackKitTests/GoogleCastControllerTests.swift`
- **Unit Tests:**
  - Test device capability negotiation and declining unsupported private shares.
- **Verification:** `swift test --filter GoogleCastControllerTests`
- **Dependencies:** `TASK-1.6.2`

#### [ ] TASK-2.4.3: Long-Tail Subtitle Formats & Advanced Styling
- **Requirements Ref:** `PB-1`, `PB-2`, `doc 04 §2.3`
- **Objective:** Add support for DVB, DVDSub, MicroDVD, MPL2, Timed Text, TMP, TXT, XSUB, and advanced ASS style presets.
- **Target Files:**
  - `Sources/PlaybackKit/Subtitles/Parsers/ExtendedSubtitleParsers.swift`
  - `Tests/PlaybackKitTests/ExtendedSubtitleTests.swift`
- **Unit Tests:**
  - Test decoding each extended subtitle format and extracting timestamped cues.
- **Verification:** `swift test --filter ExtendedSubtitleTests`
- **Dependencies:** `TASK-1.6.9`

---

### Workstream 2.5: StoreKit 2 & Monetization

#### [ ] TASK-2.5.1: StoreKit 2 Subscription & Purchase Manager
- **Requirements Ref:** `BIZ-1`, `BIZ-2`, `BIZ-4`, `BIZ-5`, `doc 08 §2`
- **Objective:** Implement StoreKit 2 manager for auto-renewable subscriptions (Monthly $1.99, Yearly $16.99) and non-consumable (Lifetime $99.99) with Keychain-cached entitlements.
- **Target Files:**
  - `Sources/StoreKit/PurchaseManager.swift`
  - `Sources/StoreKit/Models/SubscriptionProduct.swift`
  - `Sources/StoreKit/Security/EntitlementCache.swift`
  - `Tests/StoreKitTests/PurchaseManagerTests.swift`
- **Unit Tests:**
  - Test transaction listener processes active subscriptions and trials.
  - Test entitlement caching works offline and validates expiry date.
  - Test restore purchases successfully syncs with App Store.
- **Verification:** `swift test --filter PurchaseManagerTests`
- **Dependencies:** `TASK-1.1.2`

#### [ ] TASK-2.5.2: Pro Feature Gating & Upsell Presentation
- **Requirements Ref:** `BIZ-3`, `BIZ-7`, `doc 08 §1`, `doc 08 §2`
- **Objective:** Implement `ProGate` service enforcing free vs Pro tiers at moment-of-value (adding 2nd source, playing DTS/extended codecs, cloud drive, iCloud sync) without blocking HDR/Atmos (free per D-1).
- **Target Files:**
  - `Sources/StoreKit/ProGate.swift`
  - `Sources/PlayItRight/Views/Subscription/ProPaywallSheet.swift`
  - `Tests/StoreKitTests/ProGateTests.swift`
- **Unit Tests:**
  - Test HDR10, Dolby Vision, and Atmos playback remain free (Decision D-1).
  - Test adding a second source is intercepted by Pro gate.
  - Test playing DTS or AV1 on gen 2/3 triggers Pro upsell.
- **Verification:** `swift test --filter ProGateTests`
- **Dependencies:** `TASK-2.5.1`

---

## 6. Phase 3 — v1.0 Launch & Accessibility / Localization

### [ ] TASK-3.1: VoiceOver & tvOS Accessibility P0 Audit
- **Requirements Ref:** `UI-4`, `UI-5`, `UI-6`, `NFR-23`, `doc 06 §4`, `doc 09 §7`
- **Objective:** Comprehensive accessibility implementation: VoiceOver labels for all media cards, tech badges, and player controls; high-contrast focus rings; closed caption customization.
- **Target Files:**
  - `Sources/PlayItRight/Accessibility/AccessibilityModifiers.swift`
  - `Tests/PlayItRightTests/AccessibilityAuditTests.swift`
- **Unit Tests:**
  - Test accessibility elements, traits, and values across all screens.
  - Test contrast ratios under high-contrast system setting.
- **Verification:** `swift test --filter AccessibilityAuditTests`
- **Dependencies:** `TASK-1.7.4`, `TASK-1.7.7`

### [ ] TASK-3.2: String Catalogs & Localization Infrastructure
- **Requirements Ref:** `NFR-22`, `doc 09 §7`
- **Objective:** Externalize 100% of user-visible strings into Xcode String Catalogs (`.xcstrings`) with English baseline and preparation for top 5 locales.
- **Target Files:**
  - `Sources/PlayItRight/Resources/Localizable.xcstrings`
  - `Tests/PlayItRightTests/LocalizationCoverageTests.swift`
- **Unit Tests:**
  - Test localization test crawler ensures zero hardcoded strings in UI views.
- **Verification:** `swift test --filter LocalizationCoverageTests`
- **Dependencies:** `TASK-1.7.9`

### [ ] TASK-3.3: App Store Privacy & Zero-Telemetry Audit
- **Requirements Ref:** `NFR-11`, `NFR-13`, `doc 01 §2`, `doc 09 §4`
- **Objective:** Automated build verification ensuring zero third-party telemetry SDKs and verifying App Store Privacy "Data Not Collected" compliance.
- **Target Files:**
  - `scripts/audit-privacy.sh`
  - `Tests/CoreKitTests/PrivacyAuditTests.swift`
- **Unit Tests:**
  - Assert zero network calls to non-whitelisted domains during full app navigation.
- **Verification:** `./scripts/audit-privacy.sh`
- **Dependencies:** `TASK-1.1.3`

### [ ] TASK-3.4: iOS / iPadOS Companion Build Target
- **Requirements Ref:** `ARCH-7`, `SYNC-4`, `doc 02 §1`, `doc 10 §Phase 3`
- **Objective:** Configure iOS/iPadOS companion target in Package.swift utilizing shared core packages for remote library browsing and AirPlay-to-Apple-TV.
- **Target Files:**
  - `Package.swift`
  - `Sources/PlayItRightCompanion/...`
- **Unit Tests:**
  - Build and run core package tests under iOS destination.
- **Verification:** `swift test --destination 'platform=iOS Simulator,name=iPhone 16'`
- **Dependencies:** `TASK-1.6.10`, `TASK-2.3.3`

### [ ] TASK-3.5: Full Device Lab Conformance Gate
- **Requirements Ref:** `NFR-25`, `PB-G1`, `PB-G2`, `doc 10 §Phase 3`
- **Objective:** Execute full 100% test asset conformance matrix across physical Apple TV 4K gen 2, gen 3, and gen 4 hardware; assert $\ge 99.5\%$ crash-free rate.
- **Target Files:**
  - `scripts/run-device-conformance.sh`
- **Unit Tests:**
  - Automated report generation verifying all formats and rungs.
- **Verification:** `./scripts/run-device-conformance.sh`
- **Dependencies:** `TASK-1.8.1`, `TASK-2.1.1`, `TASK-2.1.2`

### [ ] TASK-3.6: App Store Release Packaging & Metadata
- **Requirements Ref:** `doc 01 §2`, `doc 10 §Phase 3`
- **Objective:** Configure App Store provisioning, entitlements (`kSecAttrAccessibleAfterFirstUnlock`, CloudKit, StoreKit), screenshots, and release notes.
- **Target Files:**
  - `PlayItRight.entitlements`
  - `AppStoreMetadata/...`
- **Verification:** Xcode archive validation for App Store submission.
- **Dependencies:** `TASK-3.1`, `TASK-3.3`, `TASK-3.5`

---

## 7. Phase 4 — v1.x Post-Launch Continuous Roadmap

### [ ] TASK-4.1: macOS & visionOS Target Builds
- **Requirements Ref:** `ARCH-7`, `doc 10 §Phase 4`
- **Objective:** Enable shared SPM packages on macOS (14+) and visionOS (2+) targets with platform-adaptive UI wrappers.
- **Target Files:**
  - `Package.swift`
  - `Sources/PlayItRightMac/...`
  - `Sources/PlayItRightVision/...`
- **Verification:** `swift test` on macOS; Xcode test runner for visionOS simulator.
- **Dependencies:** `TASK-3.6`

### [ ] TASK-4.2: HDR10+ Dynamic Video Metadata (DVM) Processing
- **Requirements Ref:** `PB-16`, `doc 04 §7`, `doc 10 §Phase 4`
- **Objective:** Implement parsing and translation of HDR10+ dynamic metadata for tone-mapping and conversion.
- **Target Files:**
  - `Sources/PlaybackKit/Color/HDR10PlusProcessor.swift`
- **Verification:** Conformance test with HDR10+ test clips.
- **Dependencies:** `TASK-1.6.6`

### [ ] TASK-4.3: Dolby Vision Profile Remapping (P7/P8 to P8.1)
- **Requirements Ref:** `doc 04 §7`, `doc 10 §Phase 4`
- **Objective:** Real-time Dolby Vision profile conversion: rewrite Profile 7 (dual-track UHD BD) and Profile 8 RPUs to Profile 8.1 for Apple TV 4K gen 4 hardware decoding.
- **Target Files:**
  - `Sources/PlaybackKit/Color/DoViProfileRemapper.swift`
- **Verification:** Verification of converted RPU bitstreams against Dolby reference parser.
- **Dependencies:** `TASK-1.6.5`, `TASK-2.1.1`

### [ ] TASK-4.4: In-App Subtitle Provider Downloads
- **Requirements Ref:** `PB-2.3`, `doc 04 §2.3`, `doc 10 §Phase 4`
- **Objective:** Implement user-initiated search and download from OpenSubtitles / Subscene with language matching and automatic sidecar caching.
- **Target Files:**
  - `Sources/MetadataKit/Subtitles/SubtitleDownloadClient.swift`
- **Verification:** Integration tests against mock OpenSubtitles API.
- **Dependencies:** `TASK-1.6.9`

### [ ] TASK-4.5: 21:9 Ultra-Wide & Anamorphic Stretch Processing
- **Requirements Ref:** `doc 06 §2.4`, `doc 10 §Phase 4`
- **Objective:** Support 2.39:1 / 21:9 anamorphic de-squeeze and custom aspect ratio letterboxing modes.
- **Target Files:**
  - `Sources/PlaybackKit/Pipelines/AspectScaler.swift`
- **Verification:** Unit tests verifying output viewport matrix transformations.
- **Dependencies:** `TASK-1.6.6`

---

## 8. Agent Development Quick-Start & Verification Cheatsheet

### 8.1 Local Environment Setup
```bash
# Verify active environment and database path
make env-info ENV=dev

# Initialize dev SQLite database
make db ENV=dev

# Run full test suite with CLT frameworks
make test

# Run a specific test suite
PLAYITRIGHT_ENV=test swift test -Xswiftc -F/Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  --filter <SuiteOrTestName>
```

### 8.2 Adding a New Module to Package.swift
When adding a new SPM target (e.g. `CoreKit`, `PlaybackKit`):
1. Define target in `Package.swift` under `targets`.
2. Ensure platform-neutral availability (`macOS(.v14)`, `iOS(.v17)`, `tvOS(.v17)`).
3. Add corresponding test target with the CLT framework flags established in `Package.swift`.
4. Run `swift build` and `make test` to ensure zero compilation or linker errors.
