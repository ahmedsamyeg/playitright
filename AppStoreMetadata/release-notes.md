# PlayItRight 1.0 — Release Notes

PlayItRight 1.0 is the first public release for Apple TV 4K (gen 2 and later).

## Highlights

- Play MKV, MP4, ISO, BDMV, WEBM, and more, with hardware acceleration wherever the Apple TV supports the format.
- Dolby Vision, HDR10, HDR10+, HLG, Dolby Atmos, and DTS playback.
- Local-first library with automatic metadata, artwork, cast, ratings, and trailers.
- Plex, Jellyfin, Emby, SMB, NFS, WebDAV, FTP/SFTP, UPnP, cloud drives, and local files.
- CloudKit sync for libraries, watch state, resume position, ratings, collections, and playlists.
- AirPlay and Google Cast.
- An honest quality badge and pipeline explanation for every title.
- VoiceOver labels, high-contrast focus rings, adjustable captions, and an English String Catalog baseline.
- Zero telemetry and an App Privacy label of Data Not Collected.

## Known Limitations

- The iOS/iPadOS companion is a separate target in this release.
- The physical Apple TV gen 2/3/4 device-lab sign-off must be run with `scripts/run-device-conformance.sh --device <UDID>` before submission.
- Additional locale translations are prepared through the String Catalog but ship after the English baseline.
