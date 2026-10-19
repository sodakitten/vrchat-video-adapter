---
name: vrchat-video-encode
description: Turn a local video (MKV, MP4, WEB-DL, ...) into an MP4 that VRChat can actually play, using ffmpeg. It covers probing the source, copying the video stream when it is already VRChat-safe, transcoding audio VRChat cannot decode (E-AC-3/DDP, AC-3, DTS, TrueHD, FLAC) to AAC, burn in subtitles or danmaku (弹幕), raise the frame rate with RIFE, verify the result. Also covers "the audio sounds wrong in VRChat" — proving whether the encode or the player's 5.1 downmix is at fault, then delivering a stereo track. Use for a VRChat-compatible/Quest-safe MP4, burned-in subtitles, smoother playback, or reports of no sound or odd-sounding audio in VRChat.
whenToUse: The user asks to transcode/compress/remux a video for VRChat or a VRChat world, asks whether VRChat supports a given codec, wants it smoother or interpolated to a higher frame rate, or reports silence, no audio, or strange-sounding dialogue for a video played in VRChat, or asks for danmaku (弹幕) to go with a video.
---

# VRChat video encoding

VRChat plays media through **AVPro Video → Windows Media Foundation** on PC and ExoPlayer on Android/Quest. It relies on *operating-system* codecs, so a file it cannot decode fails silently — usually as video with no audio.

## What VRChat can play

| | Safe | Avoid |
|---|---|---|
| Container | MP4 (`.mp4`, `avc1`/`mp4a` tags) | MKV, AVI, MOV on Quest |
| Video | H.264 8-bit 4:2:0 (`yuv420p`), even width/height, ≥24 fps, up to High profile L5.1 | H.265/HEVC, 10-bit, 4:4:4, odd dimensions, <24 fps |
| Audio | **AAC-LC** (up to 5.1), MP3 on PC | **E-AC-3/DDP, AC-3, DTS, TrueHD** — undecodable; FLAC/Vorbis/Opus unreliable |
| Layout | `moov` at the front (`+faststart`), served over HTTP(S) | local `file://` paths |

Authority and evidence (read when the user disputes a codec): [references/vrchat-formats.md](references/vrchat-formats.md).

## Workflow

1. **Resolve tools.** `ffmpeg`/`ffprobe` on PATH, else `Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffprobe.exe`. Never install before checking.
2. **Probe the source**: codecs, `pix_fmt`, dimensions, frame rate, audio channels, chapters, subtitles.
3. **Video — copy before encoding.** Already H.264 `yuv420p`, even-sized, ≥24 fps, ≤ High L5.1? `-c:v copy` is lossless and takes seconds per GB. Re-encode only otherwise, or to burn subtitles or interpolate — then benchmark `libx264 -crf 20` against `h264_nvenc -preset p5 -cq 23` by SSIM; NVENC often wins at a quarter of the runtime ([references/ffmpeg-recipes.md](references/ffmpeg-recipes.md)).
4. **Audio — check the codec, do not assume.** Copy only if already AAC (or MP3 for PC-only). Everything else becomes `-c:a aac -b:a 512k -ac 6 -ar 48000`, and keep ≤6 channels: Windows' AAC decoder has no 7.1.
5. **Subtitles.** MKV tracks are invisible to VRChat; see below.
6. **Mux.** `-map_metadata -1 -map_chapters -1 -movflags +faststart -disposition:a:0 default`.
7. **Verify** with [scripts/verify-vrchat-mp4.ps1](scripts/verify-vrchat-mp4.ps1).

## Audio is the usual failure

E-AC-3 ("DDP") is the default audio of most WEB-DL rips and is **not** in AVPro's list. Windows 11 24H2 no longer ships the AC-3/E-AC-3 decoder (the registered CLSID is a stub to a Store package, and the decoder is field-of-use restricted). Prove it on the user's own machine instead of arguing:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\probe-wmf-audio.ps1 -Path <file.mp4>
```

`CanTranscode = False` means VRChat on PC plays that file silently. Worked example: [references/audio-decode-evidence.md](references/audio-decode-evidence.md). Never copy audio just because the user prefers it — say plainly that the copy is impossible for VRChat and why, then deliver AAC.

### When the user reports strange-sounding dialogue

Do not re-encode on a hunch. Measure source and output **per channel** over one window (`-af "pan=mono|c0=cN,volumedetect"`). Matching within ~0.2 dB, with the center in phase and no LFE swap, means the encode is faithful and the fault is the **player's multichannel handling**: Windows renders 5.1 → 2.0 and Unity downmixes behind that, so the fix is a 2.0 track — downmix with the ITU matrix (LFE dropped), reuse the verified video via `-c:v copy`, and prove the picture is untouched by the video stream's packet MD5. Battery, matrix and the PowerShell traps that corrupt these commands: [references/audio-fidelity-diagnostics.md](references/audio-fidelity-diagnostics.md).

## Burning in subtitles

A full video re-encode; say so and get consent when the user only asked for a remux. Extract to `.srt`, convert to `.ass`, set a CJK font and `PlayResX`/`PlayResY` or Chinese renders as tofu boxes, then `-vf "subtitles=sub.ass"` with the work directory as the process CWD (relative filter paths resolve against the CWD, **not** the input's); check a frame with dialogue on screen. Exact commands, the style line and the escaped absolute path form: [references/ffmpeg-recipes.md](references/ffmpeg-recipes.md). A muxed Chinese track is often machine-translated; sourcing a better one: [references/subtitle-sourcing.md](references/subtitle-sourcing.md). Fix a candidate's timeline with [scripts/align-subtitles.ps1](scripts/align-subtitles.ps1) and burn it with [scripts/burn-subs.ps1](scripts/burn-subs.ps1).

## Danmaku (弹幕)

VRChat renders no sidecar, so danmaku are either burned into the picture (another full encode) or handed over as XML/ASS for local players (`DanmakuFactory -i x.xml -o x.ass`, then `mpv --sub-file=x.ass`). When a show has been delisted from Bilibili, **dandanplay (弹弹play) still holds the archived Bilibili comments**: 2,200 / 2,794 / 2,417 / 2,069 for four episodes where Tucao had 135 / 51 / 84 / 105 and every other source had none. Reach it through the open-source `danmu_api` server (`/api/v2/search/episodes?anime=<kw>&episode=<N>`, then `/api/v2/comment/<episodeId>` **immediately** — the ids are session-scoped and a wrong one returns the same `{"count":0}` as an empty source); driver: [scripts/fetch-danmaku.ps1](scripts/fetch-danmaku.ps1). Before burning, prove the timeline from the ASS's own OP/ED cue times — matching the text does not work. Setup, traps and the sources that do not work: [references/danmaku-sourcing.md](references/danmaku-sourcing.md).

## Raising the frame rate (interpolation)

Match the headset, not 60. At 90 Hz, 45 and 30 fps divide evenly (a frame per 2 or 3 refreshes) while 60 fps gives 3:2 judder; at 72 Hz, 24 does. 1080p45 is Level 4.2 — inside VRChat's ceiling.

`rife-ncnn-vulkan` runs headless on current NVIDIA cards (verified on an RTX 5080 Laptop; ignore claims that Blackwell needs a rebuild), and it is worth it: ffmpeg's `minterpolate` manages ~3 fps of 1080p output (34 hours for 2h12m) against ~3.4 hours for the chunked pipeline. Expect ~1.5x the video bitrate at 45 fps, not the 1.9x the frame count suggests. Chunk arithmetic, measurements and pitfalls: [references/frame-interpolation.md](references/frame-interpolation.md); driver: [scripts/interpolate-rife.ps1](scripts/interpolate-rife.ps1). Keep a subtitle-free 45fps master: burning a variant is one NVENC pass, re-interpolating is hours.

## Verify before delivering

Report measured facts: stream table, duration matching the source, chapter count, `moov` offset near the start, a full decode exiting 0, the audio's `CanTranscode`, and a frame when subtitles were burned. Prefer an ASCII filename: the world needs **Allow Untrusted URLs**.

## Pitfalls

- ffmpeg 9 removed `-vsync`: use `-fps_mode passthrough|cfr|vfr`.
- ffmpeg writes a dangling `tref/chap` reference when the source has chapters and metadata is stripped; add `-map_chapters -1` (`-map_metadata -1` alone does not).
- `-ss` before `-i` resets output timestamps, so the `subtitles` filter then shows the wrong cues. For a sample, encode from 0 and cut the frame later, or add `-copyts`.
- `Start-Process -ArgumentList` joins an array unquoted, so a path with spaces splits and its tail binds to the next parameter. Pass one quoted string, or a zero-argument launcher `.ps1` (UTF-8 **with BOM**) holding the paths.
- `$ErrorActionPreference = 'Stop'` turns *any* native stderr line into a terminating error, so a tool that only prints a banner to stderr (rife-ncnn-vulkan) looks like it failed. Let `cmd /c "... > log 2>&1"` own the redirection.
- PowerShell traps that corrupt an ffmpeg call (`$input` expanding to nothing, colliding aliases, `2>&1` misattribution, BOM-less scripts): [references/audio-fidelity-diagnostics.md](references/audio-fidelity-diagnostics.md).
- Two encoders writing identical pixels emit different bytes, so comparing compressed files by MD5 is not a pixel comparison; decode to rawvideo and hash that, or use `psnr`/`ssim`.
- A log watcher that greps several trailing lines can match a *stale* completion marker from an earlier run in the same log. Match the last line only.
- Many machines ship only Windows PowerShell 5.1 (which WinRT probing requires) and no `pwsh`; invoke helpers as `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>`.
