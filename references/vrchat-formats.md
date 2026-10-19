# VRChat video format authority

VRChat's players are `VRCAVProVideoPlayer` (PC) and `VRCUnityVideoPlayer`, built on AVPro Video, which "doesn't include native support for any codecs (except for Hap and NotchLC) and relies on codecs that are natively supported by the operating system".

## AVPro Video supported media (the engine VRChat uses)

| | Windows | Android (Quest) | iOS |
|---|---|---|---|
| **Container MP4** | yes | yes | yes |
| **Container MKV** | yes (Win10+) | yes | no |
| **Container WebM** | yes (Win10 1607+) | yes | no |
| **Video H.264** | yes — 4:2:0 and 8-bit only, up to profile L5.1 | yes | yes |
| **Video HEVC/H.265** | yes, but requires a Store "HEVC Video Extension" download | yes | yes |
| **Video VP9** | yes, Windows 10 1607+, 4:2:0 only; **with Media Foundation, no audio codec is supported and including one makes the video fail to load** | yes | no |
| **Audio AAC** | yes | yes | yes |
| **Audio MP3** | yes | yes | **not as an audio track inside a video file** |
| **Audio AC-3** | yes | ? (unknown) | yes |
| **Audio E-AC-3** | **not listed at all** | not listed | not listed |
| **Audio FLAC** | yes (Win10+) | yes | yes |
| **Audio Opus** | yes on 1607+ | yes | no — `.caf` only |
| **Audio Vorbis** | **no** | yes | no |
| **Audio DTS / TrueHD** | not listed | not listed | not listed |

Streaming: HTTP progressive MP4 is supported on every platform; HLS, DASH, RTSP, RTMP vary. Quest requires HTTPS.

Sources:

- [AVPro Video — Supported Media](https://www.renderheads.com/content/docs/AVProVideo/articles/supportedmedia.html)
- [VRChat Video Formats (gist)](https://gist.github.com/200Tigersbloxed/30fc61da24bf71706182f30f7e902983) — streaming-method compatibility matrix
- [VRChat Video Players (creator docs)](https://creators.vrchat.com/worlds/udon/video-players/)
- [VRChat's unofficial wiki — FFmpeg page](https://vrchat.wikidot.com/info:ffmpeg) — where the community recipe comes from: H.264 + AAC, `-movflags +faststart`, dimensions divisible by two, 24 fps floor, 30 fps recommended

## Unity's own constraints (the players ride on Unity)

- H.264 and AAC are what Unity handles best; the community recipe is H.264 + AAC.
- Width and height **must be divisible by two**, or Unity fails to play the file.
- Frame rate can go as low as 24 fps "before Unity will fail to play the video" — 23.976 fps sources are a real risk; convert to 24 or 30 when re-encoding.
- 4K is supported in practice; 1080p is the safe target.

## Windows codec availability (why PC audio breaks)

- Microsoft's own table: AC-3 was included before Windows 11 24H2 and **"is no longer included with Windows"** from 24H2 on. Many OEMs pre-install a Dolby package; clean installs do not have one.
- The Dolby decoder MFT (CLSID `CMSDDPlusDecMFT`, `Msauddecmft.dll`) handles AC-3 and E-AC-3 to PCM, but it "is registered with the flag `MFT_ENUM_FLAG_FIELDOFUSE`, which indicates that the MFT that must be unlocked by the application before use" — i.e. third-party apps do not get it by default.
- On 24H2+ machines the registered implementation is `DolbyDecMFT_redirect.dll`, a small redirect stub to a Store-delivered Dolby package. Without that package installed, decoding fails.
- Consequence: a video that plays fine in VLC/mpv (which ship their own decoders) can be silent in VRChat. Players with bundled decoders prove nothing about VRChat.

Sources:

- [Supported codecs — Windows apps, Microsoft Learn](https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/supported-codecs)
- [Dolby Audio Decoder — Win32 apps, Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/medfound/dolby-audio-decoder)

## What a machine actually decodes (measured, not assumed)

The table above is what the *engine* can use. What a given PC can use depends on which media
codec packages are installed from the Store, so inventory the machine before ruling anything out:

```powershell
Get-AppxPackage | Where-Object { $_.Name -match 'HEVC|AV1|VP9|WebMedia|MPEG2|MediaExtensions' } |
  Select-Object Name, Version
```

| Package | What it adds to Media Foundation |
|---|---|
| `Microsoft.WebMediaExtensions` | **MKV / WebM containers**, Vorbis, Opus, Theora |
| `Microsoft.HEVCVideoExtension` | HEVC/H.265 decode |
| `Microsoft.VP9VideoExtensions` | VP9 decode |
| `Microsoft.AV1VideoExtension` | AV1 decode |

Measured matrix — Windows 11 24H2, Intel Arc A770, all four packages installed. Each row is a
10 s file of real H.264 1080p plus one audio track, run through `scripts/probe-wmf-audio.ps1`:

| Container | Audio | Verdict |
|---|---|---|
| MP4 | AAC-LC 5.1 (6 ch) | DECODABLE |
| MKV | AAC-LC 5.1 | DECODABLE |
| MOV | AAC-LC 5.1 | DECODABLE |
| MPEG-TS | AAC-LC 5.1 | DECODABLE |
| MP4 / MKV | **AAC-LC 8 ch (7.1)** | **NOT DECODABLE** — Windows' AAC decoder has no 7.1 |
| MKV | FLAC 5.1 (6 ch) | DECODABLE |
| MKV / MP4 | **FLAC 8 ch (7.1)** | **DECODABLE** — the only route to a true 7.1 track |
| MKV | Vorbis 5.1 | DECODABLE (AVPro's table says no) |
| MKV | Opus 5.1 **and** 7.1 | NOT DECODABLE (AVPro's table says yes) |
| MKV | AC-3 5.1 | NOT DECODABLE (24H2 removed the decoder; AVPro's "yes" predates that) |
| MKV | TrueHD 7.1 | NOT DECODABLE |

Three conclusions:

- **MKV is playable on PC** once Web Media Extensions is installed. Preferring MP4 in the
  workflow is about *delivery certainty* — Quest and iOS cannot play MKV, and the next PC may
  lack the package — not about a hard PC limit.
- **AAC stops at 5.1.** A 7.1 AAC track is simply not decodable, so an 8-channel AAC deliverable
  is a silent one. If 8 channels are genuinely wanted, FLAC in MKV is the only codec here that
  decodes.
- **Check whether the "7.1" is real before paying for it.** One remux's 7.1 TrueHD measured
  SL/SR at −91 dB (digital silence) while its 5.1 AC-3 carried the same six channels within
  1 dB — a 5.1 mix in a 7.1 wrapper. Measure over an *action* scene, not a quiet dialogue
  scene, and per channel: `-af "pan=mono|c0=cN,volumedetect"` (see
  [audio-fidelity-diagnostics.md](audio-fidelity-diagnostics.md)).

Delivery default stays **MP4 + H.264 8-bit + AAC-LC ≤5.1**: no Store package needed, works on
every platform, and it is what `verify-vrchat-mp4.ps1` asserts.

## Playback in VRChat itself

VRChat video players consume a **URL**, not a file path. Local files are served by pointing the player at a local HTTP server; `file://` is not a general solution. The setting to allow non-whitelisted hosts is **Allow Untrusted URLs**, and Quest clients require HTTPS.

- [VRChat-Local-Video-Player](https://github.com/UbootVRC/VRChat-Local-Video-Player) — hosts local files over HTTP with range requests so VRChat can buffer and seek
