---
name: vrchat-video-encode
description: Turn a local video (MKV, MP4, WEB-DL, ...) into an MP4 that VRChat can actually play, using ffmpeg. It covers probing the source, copying the video stream when it is already VRChat-safe, transcoding audio VRChat cannot decode (E-AC-3/DDP, AC-3, DTS, TrueHD, FLAC) to AAC, burning subtitles (as the file's own ASS styling, or restyled after sourcing one) with the output sized to the subtitle canvas, grafting one release's audio onto another's picture with the timeline offset measured rather than guessed, raising the frame rate with RIFE, and verifying by measurement. It also covers sourcing danmaku — which services still answer, and how to prove the danmaku are aligned with the picture. Also covers "the audio sounds wrong in VRChat" — proving whether the encode or the player's 5.1 downmix is at fault, then delivering a stereo track — and "what can this PC actually decode", by probing rather than assuming. Use for a VRChat-compatible/Quest-safe MP4, burned-in subtitles, a font the user dislikes, combining two releases, finding danmaku (弹幕) for a title, smoother playback, or reports of no sound or odd-sounding audio in VRChat.
whenToUse: The user asks to transcode/compress/remux a video for VRChat or a VRChat world, asks whether VRChat (or their PC) supports a given container or codec, wants subtitles burned in or an existing subtitle font changed, wants one release's video and subtitles with another release's audio, wants smoother or interpolated playback, wants danmaku/弹幕 for a title, or reports silence, no audio, or strange-sounding dialogue for a video played in VRChat.
---

# VRChat video encoding

VRChat plays media through **AVPro Video → Windows Media Foundation** on PC and ExoPlayer on Android/Quest. It relies on *operating-system* codecs, so a file it cannot decode fails silently — usually as video with no audio.

## What VRChat can play

| | Safe | Avoid |
|---|---|---|
| Container | MP4 (`.mp4`, `avc1`/`mp4a` tags) | MKV, AVI, MOV on Quest |
| Video | H.264 8-bit 4:2:0 (`yuv420p`), even width/height, ≥24 fps, up to High profile L5.1 | H.265/HEVC, 10-bit, 4:4:4, odd dimensions, <24 fps |
| Audio | **AAC-LC** (up to 5.1), MP3 on PC | **E-AC-3/DDP, AC-3, DTS, TrueHD** — undecodable; **AAC 7.1** always fails; FLAC/Vorbis/Opus depend on the machine's codec packages |
| Layout | `moov` at the front (`+faststart`), served over HTTP(S) | local `file://` paths |

Authority and evidence (read when the user disputes a codec): [references/vrchat-formats.md](references/vrchat-formats.md).

## Workflow

1. **Resolve tools.** `ffmpeg`/`ffprobe` on PATH, else `Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffprobe.exe`. Never install before checking.
2. **Probe the source**: codecs, `pix_fmt`, dimensions, frame rate, audio channels, chapters, and the subtitles — *codec* (`hdmv_pgs_subtitle` is a bitmap, `ass`/`subrip` is text) and, for an ASS, its `PlayResX`/`PlayResY`. Those two facts decide what is even possible later.
3. **Video — copy before encoding.** Already H.264 `yuv420p`, even-sized, ≥24 fps, ≤ High L5.1? `-c:v copy` is lossless and takes seconds per GB. Re-encode otherwise, to burn subtitles, or to interpolate — then benchmark `libx264 -crf 20` against `h264_nvenc -preset p5 -cq 23` by SSIM (with the timebase fix in [references/measurement-pitfalls.md](references/measurement-pitfalls.md)); NVENC often wins at a quarter of the runtime ([references/ffmpeg-recipes.md](references/ffmpeg-recipes.md)). When burning, size the output to the subtitle canvas, not to 1080p out of habit.
4. **Audio — check the codec, do not assume.** Copy only if already AAC (or MP3 for PC-only). Everything else becomes `-c:a aac -b:a 512k -ac 6 -ar 48000`, and keep ≤6 channels: Windows' AAC decoder has no 7.1.
5. **Subtitles.** MKV tracks are invisible to VRChat; see below.
6. **Mux.** Map exactly the streams you want and nothing else: `-map 0:v:0 -map 0:a:0 -map_metadata -1 -map_chapters -1 -movflags +faststart -disposition:a:0 default`. Ship **one** audio track — spare tracks are a liability, not a convenience (see Pitfalls).
7. **Verify** with [scripts/verify-vrchat-mp4.ps1](scripts/verify-vrchat-mp4.ps1), then read the frame counts back against the source and — when audio was shifted or grafted — prove the sync content-wise (section 4 of [references/measurement-pitfalls.md](references/measurement-pitfalls.md)).

## Audio is the usual failure

E-AC-3 ("DDP") is the default audio of most WEB-DL rips and is **not** in AVPro's list. Windows 11 24H2 no longer ships the AC-3/E-AC-3 decoder (the registered CLSID is a stub to a Store package, and the decoder is field-of-use restricted). Prove it on the user's own machine instead of arguing:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\probe-wmf-audio.ps1 -Path <file.mp4>
```

`CanTranscode = False` means VRChat on PC plays that file silently. Worked example: [references/audio-decode-evidence.md](references/audio-decode-evidence.md). Never copy audio just because the user prefers it — say plainly that the copy is impossible for VRChat and why, then deliver AAC.

### When the user reports strange-sounding dialogue

Do not re-encode on a hunch. Measure source and output **per channel** over one window (`-af "pan=mono|c0=cN,volumedetect"`). Matching within ~0.2 dB, with the center in phase and no LFE swap, means the encode is faithful and the fault is the **player's multichannel handling**: Windows renders 5.1 → 2.0 and Unity downmixes behind that, so the fix is a 2.0 track — downmix with the ITU matrix (LFE dropped), reuse the verified video via `-c:v copy`, and prove the picture is untouched by the video stream's packet MD5. Battery, matrix and the PowerShell traps that corrupt these commands: [references/audio-fidelity-diagnostics.md](references/audio-fidelity-diagnostics.md).

## Burning in subtitles

A full video re-encode; say so and get consent when the user only asked for a remux.

**First establish what the subtitles are, because it decides what you can promise.** A PGS track
is a *picture* of text: the font belongs to whoever authored the disc, and burning the bitmaps
reproduces it exactly — including one the user hates. Changing a font therefore requires a text
track (SRT/ASS), from the file, from a subtitle site, or from OCR. If the source already carries
an **ASS** track, that is the best case: burn it **as authored** and do not impose a style of
your own — the author's `\pos`, `\fad`, `\blur`, `\c&H` and `\p1` drawings all render through
libass, but only if the file is left alone.

**Size the output to the subtitle canvas.** Read `PlayResX`/`PlayResY` from the ASS header and
scale the video to exactly that; rendering at any other size shifts every positioned line and
scales glyphs non-uniformly against the border. When the source is an exact multiple (a 3840×2072
master with `PlayRes 1920x1036`), use the canvas itself — 1:1 rendering, zero resampling, and the
cheapest encode. Which subtitle stream is which is a matter of the **subtitle ordinal**, not the
global stream index (see Pitfalls).

Only when styling a subtitle yourself: convert to `.ass`, set a CJK font and `PlayResX`/`PlayResY`
or Chinese renders as tofu boxes, then `-vf "subtitles=sub.ass"` with the work directory as the
process CWD (relative filter paths resolve against the CWD, **not** the input's); check a frame
with dialogue on screen, sampled from *inside* a cue.

Commands, the style line and the escaped absolute path form: [references/ffmpeg-recipes.md](references/ffmpeg-recipes.md). A muxed Chinese track is often machine-translated; sourcing a better one: [references/subtitle-sourcing.md](references/subtitle-sourcing.md). Fix a candidate's timeline with [scripts/align-subtitles.ps1](scripts/align-subtitles.ps1) and burn it with [scripts/burn-subs.ps1](scripts/burn-subs.ps1).

## Grafting one release's audio onto another's picture

A user may prefer one file's picture and subtitles with another file's audio. Both are the same
film, so this is a `-c copy` mux — but only after the two timelines are **proven** to agree.
Releases differ by a second or more (a different opening, an extra logo, a container whose
duration is inflated by one long audio track), and a whole-second error is audible.

Measure the offset by at least two independent methods, then apply it with `-itsoffset` (placed
before the input it shifts) and confirm it content-wise. Methods, the control that catches a
broken measurement, and the onset test: [references/measurement-pitfalls.md](references/measurement-pitfalls.md); the mux command: [references/ffmpeg-recipes.md](references/ffmpeg-recipes.md).

## Raising the frame rate (interpolation)

Match the headset, not 60. At 90 Hz, 45 and 30 fps divide evenly (a frame per 2 or 3 refreshes) while 60 fps gives 3:2 judder; at 72 Hz, 24 does. 1080p45 is Level 4.2 — inside VRChat's ceiling.

`rife-ncnn-vulkan` runs headless on current NVIDIA cards (verified on an RTX 5080 Laptop; ignore claims that Blackwell needs a rebuild), and it is worth it: ffmpeg's `minterpolate` manages ~3 fps of 1080p output (34 hours for 2h12m) against ~3.4 hours for the chunked pipeline. Expect ~1.5x the video bitrate at 45 fps, not the 1.9x the frame count suggests. Chunk arithmetic, measurements and pitfalls: [references/frame-interpolation.md](references/frame-interpolation.md); driver: [scripts/interpolate-rife.ps1](scripts/interpolate-rife.ps1). Keep a subtitle-free 45fps master: burning a variant is one NVENC pass, re-interpolating is hours.

## Danmaku (弹幕)

A danmaku track is worth hunting for separately from subtitles, and the answer is rarely "nowhere".
dandanplay keeps an archive keyed to a bangumi episode and still holds the 2014–2015 Bilibili
comments for shows Bilibili has since **delisted** — measured on 寄生獣 episodes 21–24: **2,200 /
2,794 / 2,417 / 2,069** danmaku there, against 135 / 51 / 84 / 105 from Tucao and nothing from
Bilibili, Bahamut, Tencent, iQiyi, Youku or AcFun (each with its HTTP evidence in the reference).

Reach dandanplay through the open-source **danmu_api** server, not its own signed API (403), and
**search then fetch one episode at a time**: the `episodeId` it returns is session-scoped, and an
unknown id comes back exactly like an empty source (`count: 0`) — read the server log before
concluding a title has no danmaku. Danmaku reach VRChat only by being **burned in**; as a sidecar
they serve local players only, so get consent for the extra encode.

Before burning, prove the times with the data you already have: the ASS you are burning names its
own OP/ED cue styles, so compare their first `Start` against the OP reactions and the `ed` /
`ed后正片` comments just after, and count how many comments fall past the video's duration. Setup,
endpoints, traps and the dead sources with evidence:
[references/danmaku-sourcing.md](references/danmaku-sourcing.md); driver:
[scripts/fetch-danmaku.ps1](scripts/fetch-danmaku.ps1).

## Verify before delivering

Report measured facts, not intentions: stream table, duration matching the source, **frame count
matching the source**, chapter count, `moov` offset near the start, colour tags actually written,
a full decode exiting 0, the audio's `CanTranscode`, and a frame when subtitles were burned.
When audio was shifted or grafted, add the offset check and the onset test; when a `-c copy` step
touched a verified file, add the video packet MD5 comparison. Prefer an ASCII filename: the world
needs **Allow Untrusted URLs**.

If a measurement contradicts the plan, say so and re-measure before shipping — a wrong number
reported confidently is worse than an extra ten minutes.

## Pitfalls

- **`-disposition:a:0 default` does not decide what VRChat plays.** A two-track MP4 (track 1 `eng` with `default=1`, track 2 `chi` with `default=0`) played the **Chinese** track in VRChat. Whatever AVPro uses — enumeration order, a locale match, an ignored disposition — the reliable answer is to leave nothing to choose: map one audio stream and drop the alternates. A second track is a trap even when it is the undecodable original, since picking it means silence. Verify with `ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 <out>`.
- ffmpeg 9 removed `-vsync`: use `-fps_mode passthrough|cfr|vfr`.
- ffmpeg writes a dangling `tref/chap` reference when the source has chapters and metadata is stripped; add `-map_chapters -1` (`-map_metadata -1` alone does not).
- `-ss` before `-i` resets output timestamps, so the `subtitles` filter then shows the wrong cues. For a sample, encode from 0 and cut the frame later, or add `-copyts`.
- **`0:s:N` counts subtitle streams, not global stream indices** — in `video,audio,sub,sub,audio,sub` the third subtitle is `0:s:2`. The same form applies inside `-filter_complex`. A wrong index usually errors (`Failed to set value '0:s:4'`) but passes whenever both numbering schemes coincide, so verify it rather than inheriting it.
- **Subtitle ordinals are not stable across episodes of one season.** In one batch E01/E03–E06/E08–E10 carried six subtitle streams (`简体` at ordinal 4) while E02 and E07 carried seven, because they add a `日本語 [Forced]` track at ordinal 1 — so a hardcoded `0:s:4` burned the **Japanese [CC]** track into two episodes, and one sample frame per file did not reveal it. Resolve the ordinal per file: `ffprobe -select_streams s -show_entries stream=index:stream_tags=language,title -of json`, take language `chi` whose title does not contain 繁 (code point `0x7E41`, so the helper can stay ASCII). Then verify the whole track, not one frame: count kana (`[\u3040-\u30FF]`) in the extracted SRT/ASS — a Chinese track is ~0 %, the Japanese one in this batch was 98 %.
- **An untagged source needs frame-level colour tags.** Output `-color_primaries`/`-color_trc` flags do not reach the encoder's VUI on their own; add `setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv` to the filter chain, or repair a finished file with a `-c copy` remux afterwards ([references/ffmpeg-recipes.md](references/ffmpeg-recipes.md) §7).
- Quality numbers are only comparable when both sides share a timebase: `ssim`/`psnr` pair frames by timestamp, so a reference in MKV and an encode in MP4 misalign and can report *higher bitrate at lower SSIM*. Pin them with `settb=1/24000,setpts=N`, and run a lossless-vs-lossless control that must return SSIM 1.000000 ([references/measurement-pitfalls.md](references/measurement-pitfalls.md)).
- A container's `format=duration` is not its video duration — one long audio track can add tens of seconds. Measure per stream before concluding the picture differs.
- `Start-Process -ArgumentList` joins an array unquoted, so a path with spaces splits and its tail binds to the next parameter. Pass one quoted string, or a zero-argument launcher `.ps1` (UTF-8 **with BOM**) holding the paths.
- `$ErrorActionPreference = 'Stop'` turns *any* native stderr line into a terminating error, so a tool that only prints a banner to stderr (rife-ncnn-vulkan) looks like it failed. Let `cmd /c "... > log 2>&1"` own the redirection.
- **A BOM-less `.ps1` with one non-ASCII character can compile into something *different*, with no error.** Windows PowerShell 5.1 reads the file as ANSI: here a CJK word in a comment silently deleted the declaration on the next line — the script lost its `-Episodes` parameter while reporting `parse errors: 0`, and the failure only surfaced as "a parameter cannot be found". Keep helper scripts pure ASCII (pass CJK and paths as arguments) — even a CJK parameter *default* is enough: `'*简体*'` reached the script as `*绠€浣?` and matched nothing, with no error. And when a plainly declared parameter is not found, read the parsed AST instead of the text: `[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errs).ParamBlock.Parameters`.
- PowerShell traps that corrupt an ffmpeg call (`$input` expanding to nothing, colliding aliases, `2>&1` misattribution, BOM-less scripts, **case-insensitive variable names**, a parameter named `$args`): [references/audio-fidelity-diagnostics.md](references/audio-fidelity-diagnostics.md).
- Two encoders writing identical pixels emit different bytes, so comparing compressed files by MD5 is not a pixel comparison; decode to rawvideo and hash that, or use `psnr`/`ssim`.
- **A danmaku source that answers `count: 0` may have failed a lookup, not found an empty title.** danmu_api reports a stale/unknown `episodeId` and a genuinely empty source identically; search and fetch in one breath and read the server log rather than the count.
- A log watcher that greps several trailing lines can match a *stale* completion marker from an earlier run in the same log. Match the last line only.
- Many machines ship only Windows PowerShell 5.1 (which WinRT probing requires) and no `pwsh`; invoke helpers as `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>`.
- A helper that logs with `Write-Output` and returns a value returns **both**: assigning the call to a variable captures the log lines too, and `if ($result)` is then true even when the command failed. Log with `Write-Host`, return only the boolean.
