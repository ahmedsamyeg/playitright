# 04 · Playback Engine

The engine's contract: **any item in the supported format matrix plays on
every supported Apple TV 4K (gen 2–4, PRD D-2)** — using **Apple hardware
acceleration wherever the model supports the format, and bundled software
only where it doesn't** (ARCH-P6) — with an
honest badge telling the user exactly what is happening — and with a graceful
ladder when the hardware can't do it.

## 1. Goals

| ID | Goal |
|---|---|
| PB-G1 | 100% of supported-container files *start* playback; ≥98% complete without user intervention |
| PB-G2 | **Hardware acceleration first (ARCH-P6):** every supported format plays on **Apple hardware** (VideoToolbox decode/encode, system HDR compositing, native audio) on every model that supports it in hardware; the software path (FFmpeg/openh264) is used **only** for formats/operations the model lacks in hardware — and is always visible in the badge. Additionally: no transcode ever if direct play is viable |
| PB-G3 | Fidelity ladder with explicit rungs: **Direct → Remux → HW-transcode → SW-transcode → Remote-transcode** (doc §4) |
| PB-G4 | HDR content always plays, whatever the display: full-range output when possible, otherwise tone-mapped |
| PB-G5 | Spatial/lossless audio always plays: passthrough when the sink supports it, otherwise clean downmix |
| PB-G6 | Deterministic: same file + same device + same sink ⇒ same plan; plans are reproducible and logged |
| PB-G7 | Thermal-safe: sustained sessions on a fanless box must not brown out the CPU |

## 2. Media format matrix (parity floor: Infuse, [appendix A](appendix-a-infuse-reference.md))

"HW" = decoded on Apple silicon hardware (VideoToolbox); "SW" = bundled
FFmpeg. Per **ARCH-P6**, the *Decode* column is the **default** route on the
supported fleet (Apple TV 4K gen 2–4): **HW where that model has hardware
support for the codec, SW only where the hardware lacks it** — the rows below
state that per model. Container = demux route (A = AVFoundation native,
F = FFmpeg demux/remux).

### 2.1 Video

| Codec | Containers (demux) | Decode | Notes |
|---|---|---|---|
| H.264/AVC | MP4, MKV, AVI, WebM, FLV, M2TS, TS, WTV, ASF, OGM, 3GP, MOV/M4V (A/F) | **HW (all supported models)** | baseline, always free |
| HEVC/H.265 | MP4, MKV, M2TS, TS, MOV, WEBM, MTS (A/F) | **HW (all supported models)** | 8/10-bit |
| **AV1** | MP4, MKV, WebM, OGV (F) | **HW on gen 4 (A19 dedicated decoder); SW on gen 2/3** | Free on gen 4; Pro elsewhere (doc 08) |
| VP8/VP9 | WebM, MKV, OGV, M2TS (F) | **HW on gen 4** (VP9 listed on Apple spec page) **[verify]**; SW on gen 2/3 (not in Apple spec lists) | Pro tier |
| **VVC/H.266** | MP4, MKV, M2TS, TS (F) | SW on gen 2/3 (not in Apple spec lists); HW on gen 4 **[verify]** | Pro tier |
| MPEG-1/2 (incl. MPEG-2) | VOB, TS, M2TS, MPG, SVCD (A/F) | **SW by default** (Apple's Apple TV spec pages list only H.264/HEVC/MPEG-4 — MPEG-2 absent); HW only if S1 probe proves VideoToolbox support **[verify]** | includes `VIDEO_TS`/VOB playback |
| VC-1 | TS, M2TS, ASF, WMV (F) | SW (all models — no Apple HW decode) | |
| DivX/Xvid | AVI, OGM (F) | SW (all models) | |
| DV/HDV (mts/m2ts) | MTS, M2TS (A/F) | same as MPEG-2 row (SW default, HW if probe) | |
| WMV/VC-1 + WMA | ASF/WMV (F) | SW (all models) | |
| BDMV (Blu-ray) | `BDMV/` folder (F, disc pseudo-fs) | per title's codec | P1 |
| ISO/IMG (DVD/BD) | image (F, disc pseudo-fs) | per title | P1 |

### 2.2 Audio

| Codec | Demux | Decode | Output notes |
|---|---|---|---|
| AAC (incl. HE-AAC) | A/F | **HW (all supported models)** | default re-encode target |
| AC-3 (Dolby Digital) | A/F | **HW (all supported models)** | passthrough where sink supports |
| E-AC-3 (Dolby Digital Plus / **Atmos**) | A/F | **HW (all supported models)** | passthrough to Atmos-capable sink, else downmix (§6) |
| Dolby TrueHD (Atmos) | F (MKV/M2TS) | **SW (all models** — Apple does not expose TrueHD decode to apps **)** | downmix; Pro |
| **DTS / DTS ES** | F | **SW (all models — no Apple HW decode)** | downmix; Pro |
| **DTS-HD MA** | F | **SW (all models — no Apple HW decode)** | downmix; Pro |
| DTS Express | F | SW (all models) | |
| PCM (incl. 24-bit) | A/F | native (all models) | lossless passthrough; Pro for 24-bit |
| FLAC, ALAC | F/A | **HW (all supported models)** **[verify per model]** | lossless; Pro |
| MP3, AIFF, WAV | A/F | **HW (all supported models)** | |
| Ogg Vorbis/Opus | F | SW (all models) | |
| WMA / WMA-Pro | F | SW (all models) | |
| TTA | F | SW (all models) | |

### 2.3 Subtitles

Demux/render all of: SRT, SSA/ASS, SUB (DVB/DVDSub), SUP/PGS, VTT, SMI,
MicroDVD, MPL2, Timed Text, TMP, TXT, XSUB, VobSub — parity with
[appendix A](appendix-a-infuse-reference.md).

| Class | Route |
|---|---|
| Text-based (SRT/ASS/VTT/…) | FFmpeg parse → our renderer: Metal text or `AVMetadata`-style styling; ASS override tags supported (fonts: bundled + user) |
| Image-based (PGS/SUB/SUP, VobSub) | FFmpeg decode → GPU blit with alpha |
| Embedding | PGS/SUB in MKV, MP4 (`tx3g`/`sbvl`), MPEG (SCTE), TS (DVB) |
| External | sidecar association by name; manual picker; optional download from subtitle providers (**[verify App Store policy — keep user-initiated only]**) P2 |

- **PB-1** Every subtitle format above must demux and render, sync-accurate to ±1 frame, with language/track switching mid-playback. *(P0 text + PGS/SUP; P1 the long tail)*
- **PB-2** Subtitle controls: +/− size, position, opacity, color, forced-only toggle, style presets (SDF-style). *(P0 core; P1 full presets)*

### 2.4 Containers

MP4/MOV/M4V/3GP/MP4-family (AVFoundation direct) · MKV (FFmpeg) · AVI ·
WebM/OGV/OGG · FLV · TS/M2TS/MTS · VOB/VIDEO_TS · ASF/WMV · MXF · OGM ·
RM/RMVB **[verify — low value, P2]** · DVR-MS/PDC/DVDMEDIA (P2) ·
`.strm`/`.strmlnk` (URL indirection, doc 03) · ISO/IMG · BDMV ·
DVD media folders.

- **PB-3** All containers above: demux, multi-track selection, chapter-aware seeking, and byte-range seeking. *(P0 for: MP4 family, MKV, WebM, M2TS/TS, AVI; P1 the rest)*

## 3. Sink capabilities (what the *output* can do)

Negotiated at session start and re-checked on display change:

| Capability | How detected |
|---|---|
| Display: SDR / HDR (PQ) / HLG / **Dolby Vision** | `AVPlayerViewController`/`AVSession` active format change + CMVideoFormatDescription of the *composited* output; tvOS gives the app the format the system will composite **[verify API — Spike S1]**. Fallback heuristic: `UIScreen` mode + user setting "my TV supports: SDR/HDR/DoVi" in Settings (per-output profile) |
| Max resolution/refresh | connected `UIScreen` mode (4K60 ceiling on **all** supported Apple TV 4K models — no 120 fps) |
| Audio sink: stereo / 5.1 / Atmos-capable / passthrough codec set | user profile + `AVAudioSession` route change events; HDMI consumer capability is **not** machine-readable on tvOS → **user-declared audio setup** (Stereo / Receiver-AC3 / Receiver-Atmos / HomePod / Speakers) is the authoritative input |
| AirPlay/Cast endpoint capabilities | `AVRoutePickerView`/AirPlay session APIs; Cast `CapabilityInfo` |

> **Design note (PB-4):** because tvOS does not expose the TV's capabilities
> to apps, sink profiles are *user-declared + auto-observed*: first run asks
> three questions (display HDR? DoVi? audio setup?) and afterwards the app
> learns from observed composite formats and lets the user lock/override.
> *(P0)*

## 4. The Pipeline Planner

### 4.1 Inputs

```
MediaGraph   ← demux probe (doc 03 read() + FFmpeg avformat/AVFoundation AVAsset)
  video: codec, profile, level, bitrate, res, fps, fields, colorPrimaries/transfer/matrix,
         bitDepth, HDR flags (DoVi profile{5|8|8.1} + RPU presence, HDR10 master/CLL,
         HDR10+ DVM, HLG), spatial layout, closed-caps, VFR
  audio: codec, layout (2.0/5.1/7.1 + Atmos bed?), samplerate, bits, track count
  subs: formats, languages, forced flags
  container, chapters, attachments
  source hint: .strm target, server direct-play hint, remote-transcode availability
SinkProfile  ← §3
DeviceCaps   ← CapabilityRegistry (§5)
UserPrefs    ← quality bias (best-quality | balanced | lowest-CPU),
               per-source & per-codec locks, audio setup, subtitle prefs
```

### 4.2 Path rungs (in preference order)

| Rung | Name | When | Cost |
|---|---|---|---|
| R1 | **Direct play** | container Apple demuxes natively **and** video codec HW-decodable on this model **and** color pipeline the display handles (or system tone-map is acceptable per user bias) **and** audio is native-output or user accepts | zero |
| R2 | **Remux** | any non-Apple container (MKV/AVI/WebM/FLV/…) whose video is HW-decodable: FFmpeg demux → fMP4 pipe → AVPlayer | low (CPU: demux only) |
| R3 | **HW transcode** | HW-decodable video **but** display can't take the color pipeline and user wants explicit tone-map (or DoVi→HDR10), or audio needs decode+downmix: VideoToolbox decode → Core Image/Metal color transform → VideoToolbox encode → output | medium (GPU + HW encoder) |
| R4 | **SW transcode** | video codec has **no Apple HW support on this model** (gen 2/3: AV1/VP9/VVC/MPEG-2/VC-1/WMV/DivX — gen 4 HW-decodes AV1+VP9; see §5.2), or FFmpeg is required for DoVi RPU processing: FFmpeg decode (+`zscale`/`tonemap`) → (Metal) → VideoToolbox encode if available, else openh264/H.264 **SW** encode | high (CPU) |
| R5 | **Remote transcode** | source server offered it (Plex/Jellyfin/Emby) **and** user selected "let my server transcode" for this source | off-device, but quality-limited by server |

### 4.3 Decision rules (normative)

1. **Start at R1.** Descend one rung at a time; each rung has explicit
   feasibility predicates (codec ∈ device HW set? color transform feasible?
   audio resolvable? container demuxable?).
2. **Color is a video decision, audio is an audio decision; they are planned
   independently** but both must resolve before `play()`.
3. **DoVi content:** if display is DoVi-capable and device decodes the
   profile → R1 (system does DoVi). If display is HDR-but-not-DoVi:
   - P8/P8.1 → strip RPU, present base HEVC layer as HDR10 (R2/R3, zero re-encode of picture needed beyond color passthrough)
   - P5 → **all supported models HW-decode P5** (gen 2: 5+8, gen 3: 5, gen 4: 5+8.1) → R1-class decode; FFmpeg `dolbyvision` SW decode remains only as a last-resort fallback rung; then HDR10-ish output or tone-map per display.
4. **HDR→SDR (any HDR flavor on SDR display):**
   - default: rely on Apple's system tone-map when outputting via AVPlayer
     with a native HEVC/10-bit decode (R1/R2) — verified good; user setting
     `color: system | precise | off` selects:
     - `precise` → R3 explicit pipeline: `zscale`/Core Image `CIToneMap`-equivalent
       with user tunables (target nits, BT.2020→709, gamma) — used when the
       system output isn't controllable (R4 path **must** use explicit tone-map).
5. **Audio resolution** (per track, see §6): passthrough > native decode >
   FFmpeg decode → downmix → PCM/AAC.
6. **User locks:** `preferredRung` (auto|≤R3|≤R2|forceR5) per source/codec;
   a lock only *caps* the ladder (never forces a lower rung than needed for
   feasibility — unplayable is never accepted over a needed rung).
7. **Fallback on failure:** a rung that fails at runtime (decode error,
   buffer underrun ×3) drops one rung, re-plans, and continues from current
   timestamp; the badge updates. Auto-retry max 2× then surfaces an error
   card with the exact failure (codec/color/audio) and a "try software"
   button.
8. **Server hints:** Plex `DirectStream`-able + our box can't play natively →
   planner offers R5 *or* local R3/R4, user picks once per source
   ("prefer my box" / "prefer my server").
- **PB-5** The planner must emit a full `PipelinePlan` (each rung's choice + reason strings) before first frame; the UI renders it as the **quality badge**: `Direct` · `Remuxed` · `Transcoded (HW)` · `Transcoded (SW)` · `Server-transcoded` with a detail sheet (in/out codec, color, audio path, why). *(P0)*
- **PB-6** Re-plan triggers: display change, audio route change, thermal state change, source error. Re-plan must be seamless (crossfade ≤1 frame, no audio gap > 200 ms). *(P0)*
- **PB-7** Plans are deterministic for (item, device, sink, prefs); any non-determinism (server availability) is recorded in the plan. *(P1 — testability)*

## 5. CapabilityRegistry (device side)

The single authority for "can this Apple TV do X?" (ARCH-1).

### 5.1 Two layers

1. **Data layer** — `Capabilities.json` per (Apple TV 4K model × tvOS version)
   for the supported fleet (gen 2–4, PRD D-2): built from Apple spec pages +
   our conformance runs, shipped in the app, overridable by the runtime
   layer. Baseline matrix below.
2. **Runtime layer** — **probes** executed on launch (cached, ~1–2 s):
   attempt `VTDecompressionSession` creation per (codec × bit-depth × profile)
   from tiny embedded test assets; `VTCompressionSession` for encoders;
   `AVAssetReader`/`CMFormatDescription` for container+codec; observe the
   first real composite `CMVideoFormatDescription` from the system to learn
   the display's actual output format. Runtime results override the data
   layer and are persisted.

### 5.2 Baseline device matrix (supported fleet: **Apple TV 4K gen 2–4**)

"HW dec" = hardware decode. Sources: Apple's per-model spec pages
(gen 3/4 comparisons: [Mac Observer 2026-10-14](https://www.macobserver.com/news/apple-tv-4k-av1-dolby-vision-profile-8-1/));
★ = needs runtime probe confirmation; **❌ → SW = exactly where the bundled
software path applies (ARCH-P6)**.

| | Apple TV 4K **gen 4** (2026, A19) | **gen 3** (2022, A15) | **gen 2** (2021, A12Z) |
|---|---|---|---|
| H.264 HW | ✅ | ✅ | ✅ |
| HEVC HW (8/10-bit) | ✅ | ✅ | ✅ ★10-bit |
| **AV1 HW** | ✅ **(dedicated A19 decoder)** | ❌ → SW | ❌ → SW |
| VP8/VP9 HW | ✅ listed ★ | ❌ → SW | ❌ → SW |
| VVC HW | ★ | ❌ → SW | ❌ → SW |
| MPEG-2 HW | ★ (not in Apple spec list → SW until S1 probe) | ★ (same) | ★ (same) |
| VC-1/WMV/DivX/TTA/Ogg… | ❌ → SW | ❌ → SW | ❌ → SW |
| **Dolby Vision** | **Profile 5 + 8.1** | Profile 5 | Profile 5 + 8 |
| HDR10 / HDR10+ / HLG | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ | ✅ / ★ / ✅ |
| **HW encode** | H.264 + HEVC ★(10-bit) | H.264 + HEVC ★ | H.264 + HEVC ★ |
| Audio decode HW | AC3, EAC3, AAC, ALAC, FLAC, PCM, MP3 (DTS/TrueHD → **SW via FFmpeg**) | same | same ★ |
| Audio **output** (HDMI) | user-declared sink; Apple outputs AC3/EAC3/TrueHD/DTS/PCM/AAC/ALAC/FLAC to supported receivers ★ | ★ | ★ |
| Max video out | 4K60 (HDMI 2.1, **no 120 fps**) | 4K60 | 4K60 |
| Max HDR out | HDR/DoVi 2160p60 | 2160p60 | 2160p60 |
| Wi-Fi | Wi-Fi 7 | Wi-Fi 6 | Wi-Fi 6 |

> Out of scope by PRD D-2: 1080p "Apple TV HD" models and the 2017 gen 1 box
> (A10X; tvOS 15 ceiling **[verify]**) — the app rejects them at first launch
> (NFR-19). If gen 2 (A12Z) fails tvOS 18 support **[verify]**, the floor
> tightens to gen 3 and this matrix loses a column.

### 5.3 Requirements

- **PB-8** CapabilityRegistry with data + runtime-probe layers as above; probe results cached and overridable in a developer setting ("force software path" for testing). *(P0)*
- **PB-9** The shipped `Capabilities.json` must be updated in the same release as any new Apple TV 4K hardware support; CI runs the conformance suite (real test assets per rung) on every supported model in the lab (gen 2–4). *(P0 for the models in the floor; P1 ongoing)*
- **PB-10** If the runtime probe disagrees with the data layer, runtime wins, and the discrepancy is logged (opt-in upload) to fix the data. *(P1)*

## 6. Audio pipeline

Per selected track, resolved against the **declared audio setup**:

| Setup | AC3 | EAC3 (Atmos) | TrueHD | DTS family | Lossless (FLAC/ALAC/PCM) | AAC/MP3 |
|---|---|---|---|---|---|---|
| **Stereo speakers** | decode → 2.0 downmix | decode → downmix (Atmos bed+heights folded) | SW decode → downmix | SW decode → downmix | decode (HW) → stereo | native |
| **5.1 receiver (no Atmos)** | **passthrough** | decode → 5.1 (or passthrough EAC3-5.1) | SW decode → 5.1 PCM | SW decode → 5.1 PCM | PCM 5.1 | native/upmix |
| **Atmos receiver/soundbar** | upmix→EAC3? no: **passthrough AC3** | **passthrough E-AC3** (receiver renders Atmos) | SW decode → downmix to bed (TrueHD can't passthrough-decode by receiver without our help — offer 5.1.1/5.1) | SW decode → bed | PCM | native |
| **HomePod (AirPlay 2)** | decode → stereo/5.1 (HomePod's own processing) | decode → stereo (Atmos bed) | SW decode → stereo | SW decode → stereo | decode | native |

Rules:

- **PB-11** Passthrough is used only when the *declared* sink supports the codec; never blindly. A wrong passthrough (silence) must be detected (no `AVAudioSession` level activity) and auto-fallen-back to decode+downmix within 2 s. *(P0)*
- **PB-12** All DTS/TrueHD/Atmos decode+downmix uses FFmpeg (Sw decode) → `AVAudioEngine`/manual matrix downmix with perceptual presets (stereo: ITU BS.775 + dialog center; 5.1: standard LFE/center split) — no "mystery mud": presets are named and user-selectable. *(P0)*
- **PB-13** Track UI: list all audio tracks with codec/layout/lang badges; switching mid-playback without seek; remember per-item last choice. *(P0)*
- **PB-14** Lossless 24-bit: PCM passthrough to sink where supported; else bit-depth reduce to 16-bit cleanly (SW, dithered). *(P0 for 16-bit; P1 for 24-bit — Pro)*
- **PB-15** Audio-only files (FLAC/MP3/…) play as "video" with a generated still/cover frame; no special music app. *(P1)*

## 7. Video color pipeline detail

| Source color | Display: DoVi | Display: HDR (no DoVi) | Display: SDR |
|---|---|---|---|
| **DoVi P8/P8.1** (HEVC base + RPU) | R1 direct (system DoVi) | R2/R3: drop RPU → base layer as HDR10 passthrough | system tone-map (R2) or explicit `zscale/tonemap` (R3/R4) per user setting |
| **DoVi P5** | R1 direct (**P5 HW-decodes on all supported models**) | HW decode P5 → FFmpeg RPU→HDR10 metadata step (SW, picture not re-encoded) → HDR10 out | HW decode → tone-map (system or explicit) |
| **HDR10** | remap: present as HDR10 (DoVi display accepts; badge "HDR10 on DoVi display") | direct (R1) | system or explicit tone-map |
| **HDR10+** (DVM) | process DVM → DoVi? (P2, FFmpeg) else treat as HDR10 | direct if gen supports 10+ ★; else treat as HDR10 (static) | tone-map (DVM-aware in `precise` mode, P1) |
| **HLG** | treat as HDR (HLG-on-DoVi display via PQ conversion P2; else direct HLG if display HLG-capable) | direct | HLG→SDR tone-map (HLG has built-in SDR base — cheap) |
| **SDR** | direct | direct | direct |

- **PB-16** Every matrix cell above must yield a playable, correctly-gamut output; "treat as" cells degrade metadata only, never picture quality. *(P0 for all SDR/HDR targets; DoVi-target cells P1)*
- **PB-17** Explicit tone-map (`precise` mode) exposes: target transfer (BT.1886 / sRGB), peak nits (slider, default from display profile), BT.2020→709 gamut mapping (SAT vs VUI-style), input = file's mastering metadata when present, fallback = content-adaptive. Runs on GPU (Core Image) in HW path, in FFmpeg `zscale`/`tonemap` in SW path; both implement the same parameters. *(P0 basic; P1 tuning UI)*

## 8. Timing, framing, buffering

- **PB-18** Frame pacing: source fps preserved exactly (23.976/24/25/29.97/30/48/50/59.94); no frame-rate conversion; VFR content (screen-caps) timestamped pass-through; display is 60 Hz → standard 3:2/2:2 cadence. *(P0)*
- **PB-19** Audio/video sync: continuous drift correction (A/V clock difference measured, corrected at ≤ 40 ms with audio time-stretch ≤ ±2%, video never stretched); out-of-sync indicator in debug sheet. *(P0)*
- **PB-20** Buffering: adaptive network buffer (start threshold scales with bitrate: 4K@80 Mbps ⇒ ~6 s priming), mid-stream target ≥ 4 s for network sources, ≥ 1 s local; stall recovery resumes from buffer without re-planning. *(P0)*
- **PB-21** Seeking: local/instant for ranged sources; remote-transcode seeks issue server seek; seeks within ±10 s of current use cached window; deep-seek shows progress ring. *(P0)*
- **PB-22** Resume: resume point per (item, account); auto-resume after 60 s of inactivity → back to library with "Continue" badge; in-progress stored continuously (1 s cadence). *(P0)*
- **PB-23** Gapless-ish: no more than one frame of blank on track/subtitle switches; chapter skip uses keyframe-accurate seek. *(P1)*

## 9. Performance & thermal

- **PB-24** SW transcode CPU budget: default `balanced` = ≤ 60% of sustained CPU at 1080p60 H.264/HEVC encode target; 4K SW decode allowed only in `best-quality` bias or on gen 4/3. At `thermalState ≥ .serious`: auto-drop encode res one rung (4K→1080p), notify badge `Thermal: reduced`. *(P0)*
- **PB-25** Power: idle playback (direct play, HEVC 10-bit 4K) measured ≤ 4 W sustained box power as a design target on gen 3/4. *(P1 — instrumented, not gated)*
- **PB-26** First-frame latency targets: local 4K HEVC ≤ 2 s; network ≤ 5 s (R1/R2), ≤ 8 s (R3/R4); every rung shows the latency cost in the badge detail. *(P0)*
