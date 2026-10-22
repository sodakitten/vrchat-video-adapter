# Copyable ffmpeg recipes

Windows examples; `<ff>` is the resolved `ffmpeg.exe`, `<src>` the input, `<out>` the output. Keep advanced options after the input they apply to.

## 1. Probe

```powershell
& $ffprobe -v error -hide_banner -show_format -show_streams -of json <src>
& $ffprobe -v error -show_chapters -of csv=p=0 <src>     # chapter count
```

## 2. Lossless remux (fastest path — video copied, audio fixed)

```powershell
& $ff -hide_banner -v warning -stats -y -i <src> `
  -map 0:v:0 -map 0:a:0 -map_metadata -1 -map_chapters -1 `
  -c:v copy -c:a aac -b:a 512k -ac 6 -ar 48000 `
  -movflags +faststart -disposition:a:0 default <out>
```

A 2h12m / 6.6 GB source ran at ~20x realtime: about 7 minutes, and the video stream was bit-identical. Verify the copy with `ffprobe` (same `bit_rate` on the video stream as the source).

Add `-copyts` only when you need original timestamps preserved (e.g. cutting a sample through a subtitle filter).

### Audio-only variants

```powershell
-c:a copy                     # only when the source audio is already AAC (or MP3, PC-only)
-c:a aac -b:a 512k -ac 6      # E-AC-3/AC-3/DTS/TrueHD -> AAC 5.1
-c:a aac -b:a 256k -ac 2      # stereo: smallest and safest for Quest
```

### Ship exactly one audio track

`-disposition:a:0 default` does **not** decide what VRChat plays. A file whose track 1 was `eng`
with `default=1` and whose track 2 was `chi` with `default=0` played the **Chinese** track in
VRChat — the user heard a dub they had not chosen, in a file that looked correctly tagged to
every probe. Whether AVPro ignores the disposition, matches a system locale, or enumerates in
another order does not matter: the fix is to leave nothing to choose. Map one audio stream and let
the alternates go unmapped; they are simply absent from the output, and the source still has them.

```powershell
# source has 2 audio tracks; ship only the one you want
& $ff -hide_banner -y -i <src-with-2-audio-tracks.mp4> -map 0:v:0 -map 0:a:0 -c copy `
  -metadata:s:a:0 language=eng -metadata:s:a:0 title="English 5.1" -disposition:a:0 default `
  -movflags +faststart -map_metadata -1 -map_chapters -1 <out.mp4>
```

This is a `-c copy` operation, so it costs a minute and loses nothing: prove it with the video
packet MD5 ([measurement-pitfalls.md](measurement-pitfalls.md) §5) and by matching the surviving
track's decoded PCM against the source track's:

```powershell
& $ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 <out.mp4>   # expect one line
& $ff -v error -i <src> -map 0:a:0 -f md5 -        # same hash == same track
& $ff -v error -i <out> -map 0:a:0 -f md5 -
```

A spare track is a liability even when it is an undecodable original (the AC-3 or TrueHD "just in
case" track): if the player picks it, the result is silence rather than the wrong language.

### Two inputs (reuse already-encoded audio)

```powershell
& $ff -y -i <video-source.mkv> -i <already-aac.mp4> -map 0:v:0 -map 1:a:0 ... -c:a copy
```

This avoids a second AAC generation when the audio was already produced once.

### Fix only the audio of a file whose picture is already good

When the video (burned-in subtitles included) is verified and only the audio needs redoing — e.g. replacing a 5.1 track that sounds wrong in the player with a stereo one — do not re-encode the video:

```powershell
& $ff -hide_banner -v warning -stats -y -i <burned.mp4> -i <master.mkv> `
  -map 0:v:0 -map 1:a:0 -c:v copy `
  -af "pan=stereo|c0=0.891*c0+0.630*c2+0.630*c4|c1=0.891*c1+0.630*c2+0.630*c5" `
  -c:a aac -b:a 320k -ar 48000 `
  -movflags +faststart -map_metadata -1 -map_chapters -1 -disposition:a:0 default <out.mp4>
```

That matrix is ITU-R BS.775 for 5.1(side) (`c0..c5 = FL,FR,FC,LFE,SL,SR`) with LFE dropped and 1 dB of headroom (`0.891 = -1 dB`; `0.630 = 0.707 * 0.891` folds center and surrounds in at -3 dB). A 2h12m run took 3.5 minutes at ~39x realtime.

Prove the picture is untouched — the video stream's packet MD5 must be unchanged:

```powershell
& $ff -v error -i <burned.mp4> -map 0:v:0 -c copy -f md5 -
& $ff -v error -i <out.mp4>    -map 0:v:0 -c copy -f md5 -
```

Check both inputs report the same `start_time` (`ffprobe -show_entries stream=start_time`) so the copied video and new audio stay in sync, and confirm headroom on the decoded output (this number already includes codec overshoot):

```powershell
& $ff -hide_banner -v info -i <out.mp4> -af ebur128=peak=true -f null - 2> ebur.txt
Select-String -Path ebur.txt -Pattern 'I:|LRA:|Peak:'
```

## 3. Burn in subtitles (forces a full video re-encode)

### 3a. Bitmap or text? This decides whether the font is changeable at all

PGS/VobSub tracks are **pictures of text** — the font was baked in by whoever authored the disc,
and burning them reproduces it exactly, including a font the user dislikes (a rounded 幼圆 on a
serious film, for instance). Only a text track (SRT/ASS/SSA) lets you choose a font, so probe
before promising anything:

```powershell
& $ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language -of csv=p=0 <src>
```

`hdmv_pgs_subtitle` → bitmap, font not changeable without OCR. `ass`/`subrip` → text. A 字幕组
MKV often already carries an ASS track, which is the best case: the disc's translation, editable.

### 3b. A text track that is already styled: burn it as authored

Do **not** impose a style line of your own. The author placed karaoke, signs and staff credits
with `\pos`, `\fad`, `\blur`, `\c&H` and `\p1` vector drawings; libass renders all of them, but
only if the file is left alone.

```powershell
# extract the track as-is (N is the SUBTITLE ordinal — see the gotchas below)
& $ff -v error -y -i <src> -map 0:s:0 -c:s copy <work>\sub.ass

# burn it, with <work> as the process CWD so the relative filter path resolves
& $ff -hide_banner -v warning -stats -y -i <src> -i <already-aac.mp4> `
  -map 0:v:0 -map 1:a:0 -map_metadata -1 -map_chapters -1 `
  -vf "scale=<W>:<H>,subtitles=sub.ass" `
  -c:v h264_nvenc -preset p5 -cq 23 -g 120 -pix_fmt yuv420p `
  -c:a copy -movflags +faststart -disposition:a:0 default <out-subbed.mp4>
```

### 3c. Take the output size from the subtitle canvas, not from habit

Read `PlayResX`/`PlayResY` out of the ASS header and scale the video to exactly that canvas.
libass maps PlayRes onto the frame, so rendering at any other size **shifts every `\pos` and
scales text non-uniformly against the border** — a 1920×1080 output from a 1864×1008 canvas
moves positioned signs ~3 % and resizes glyphs differently in x and y.

| Source | ASS PlayRes | Output | Why |
|---|---|---|---|
| 3728×2016 | 1864×1008 | **1864×1008** | exactly half the source — 1:1, no resampling |
| 3840×2072 | 1920×1036 | **1920×1036** | exactly half the source — 1:1, no resampling |

Check for the exact-half case first: it is the most faithful *and* the cheapest to encode. If
PlayRes is missing entirely, libass falls back to 384×288 and the result is badly stretched —
use the header's `Original Script`/`Video AR Value` hints or re-author the header rather than
shipping it.

**Two ASS gotchas worth checking before burning:**

- `0:s:N` counts **subtitle streams**, not global stream indices. In
  `video,audio,sub,sub,audio,sub`, the third subtitle is `0:s:2`, never its global index. The
  same specifier form (`[0:s:2]`) applies inside `-filter_complex`. A wrong index usually fails
  loudly (`Failed to set value '0:s:4' for option 'map'`) — except when the two numbering
  schemes happen to coincide, which is how an incorrect rule passes its first test.
- A `Dialogue:` style field can name a style the file does not define (`*Default` where only
  `Default` exists — a PopSub/Aegisub artifact). libass silently falls back to the **first**
  defined style, so the render often looks right while not being what the line asked for.
  Diff the `Style:` names against the style fields before trusting a stylesheet.

### 3d. Styling a subtitle you sourced or OCR'd

```powershell
& $ff -v error -y -i <src> -map 0:s:0 <work>\sub.srt
& $ff -v error -y -i <work>\sub.srt <work>\sub.ass
```

Edit `sub.ass`: `PlayResX: 1920`, `PlayResY: 1080`, and replace the style line with

```
Style: Default,Microsoft YaHei,56,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,2,10,10,45,1
```

(`Fontname` must cover the subtitle language — `Microsoft YaHei` for Simplified Chinese, `Microsoft JhengHei` for Traditional, `Meiryo`/`Yu Gothic` for Japanese, `Malgun Gothic` for Korean. Without a CJK-capable font, libass renders tofu boxes. Verify the name resolves: list installed families with `[System.Drawing.FontFamily]::Families`, and remember a file can reference the *localised* name — `微软雅黑` matches `Microsoft YaHei` only because libass uses DirectWrite.)

```powershell
# run with <work> as the process CWD so the relative filter path resolves
& $ff -hide_banner -v warning -stats -y `
  -i <src> -i <already-aac.mp4> `
  -map 0:v:0 -map 1:a:0 -map_metadata -1 -map_chapters -1 `
  -vf "subtitles=sub.ass" `
  -c:v h264_nvenc -preset p5 -cq 23 -g 120 -pix_fmt yuv420p `
  -c:a copy -movflags +faststart -disposition:a:0 default <out-subbed.mp4>
```

Escaped absolute form instead of a work directory: `-vf "subtitles='D\:/work/sub.ass'"`.

### 3e. Sampling a burned-in frame

**`-ss` before `-i` resets output timestamps**, so the subtitle filter then shows cues from the
start of the file — a sample taken that way looks exactly like a failed burn-in. Either encode a
short span **from 0** (`-t 40`) and cut the frame afterwards, or keep the real timeline:

```powershell
& $ff -v error -y -copyts -ss 2402.0 -i <src> -to 2403.0 -vf "scale=<W>:<H>,subtitles=sub.ass" -frames:v 1 <work>\frame.png
```

Pick the timestamp from **inside** a cue: parse the ASS for start/end and take the midpoint. A
frame sampled at the exact cue start can still show the outgoing picture, since one frame is
42 ms at 23.976 fps — a clean frame there proves nothing.

### 3f. Pick the subtitle track per file, and verify the whole track

`0:s:N` is an ordinal inside that file, and releases do not keep it stable across a season. Measured
in one 10-episode batch: eight episodes had six subtitle streams (`中文（简体）` at ordinal 4), but two
added a `日本語 [Forced]` track at ordinal 1, which pushed the Simplified track to **5** — a hardcoded
`0:s:4` silently burned the **Japanese [CC]** track into exactly those two episodes.

Resolve it from the tags, keeping the helper ASCII-only by testing the 繁 code point:

```powershell
$j = (& $ffprobe -v error -select_streams s -show_entries stream=index:stream_tags=language,title -of json $src | ConvertFrom-Json)
$trad = [string][char]0x7E41      # 繁 — keeps the script ASCII
$i = 0; $pick = -1
foreach ($s in $j.streams) {
  if ("$($s.tags.language)" -eq 'chi' -and "$($s.tags.title)" -notlike "*$trad*") { $pick = $i; break }
  $i++
}
```

Then prove the track itself, not one frame — extract it and count kana:

```powershell
& $ff -y -i $src -map 0:s:$pick -c:s srt $wd\sub.srt
$cues = @(Get-Content $wd\sub.srt -Encoding UTF8 | Select-String '^\d\d:\d\d:\d\d,\d\d\d --> ').Count
$kana = @(Get-Content $wd\sub.srt -Encoding UTF8 | Select-String '[\u3040-\u30FF]').Count
```

A Chinese track reports ~0 % kana; the Japanese `[CC]` track here reported 98 % (485 of 493 lines).
Cross-check `$cues` against the source's per-stream `NUMBER_OF_FRAMES` tag, which names the track you
actually grabbed (493 = `日本語 [CC]`, 411 = `中文（简体）`).


## 4. Choose the encoder by measurement

```powershell
# settb/setpts pin both sides to one timebase, so frames are paired by INDEX.
# Without it, an MKV source and an MP4 encode are paired by timestamp and the
# comparison drifts (see measurement-pitfalls.md §1).
$m = '[0:v]settb=1/24000,setpts=N[a];[1:v]settb=1/24000,setpts=N[b];[a][b]'
foreach ($t in 600, 4200, 6900) {
  & $ff -v error -y -ss $t -t 30 -i <src> -an -c:v libx264   -preset medium -crf 20 -pix_fmt yuv420p <work>\a.mp4
  & $ff -v error -y -ss $t -t 30 -i <src> -an -c:v h264_nvenc -preset p5    -cq 23  -pix_fmt yuv420p <work>\b.mp4
  & $ff -hide_banner -v info -ss $t -t 30 -i <src> -i <work>\a.mp4 -lavfi "${m}ssim" -f null -
  & $ff -hide_banner -v info -ss $t -t 30 -i <src> -i <work>\b.mp4 -lavfi "${m}psnr" -f null -
}
```

Run a control first — encode the reference losslessly and compare it with itself. It must report
`SSIM All:1.000000 (inf)`; anything less means the measurement, not the encoder, is being tested.

Measured on an i9-13900HX + RTX 5080 Laptop, 1080p24 film source (3 segments, `SSIM All`):

| Encoder | Speed | Average bitrate | SSIM (600 / 4200 / 6900 s) |
|---|---|---|---|
| `libx264 -preset medium -crf 20` | 118 fps (≈27 min for 2h12m) | 3249 kbps | 0.9852 / 0.9924 / 0.9795 |
| `h264_nvenc -preset p5 -cq 23` | 283 fps (≈12 min for 2h12m) | 3149 kbps | 0.9861 / 0.9927 / 0.9804 |

NVENC won on both size and SSIM here, so it was used. On other hardware or with heavy grain, `libx264 -preset slow` can win — measure, do not assume. Add `-g 120` (5-second GOP) for friendlier seeking over HTTP; it costs a little size.

Intel GPUs: `h264_qsv` with ICQ (`-global_quality`) is the equivalent, and the curve is flat
enough that the middle setting is the right one. 1080p output from a 4K HDR10 source on an Arc
A770, scored against a **lossless reference of the same tonemapped frames** (timebase-pinned
SSIM — see [measurement-pitfalls.md](measurement-pitfalls.md) §1):

| `h264_qsv` setting | Bitrate (20 s window) | SSIM |
|---|---|---|
| `-global_quality 21 -preset veryslow -look_ahead 1` | 4122 kbps | 0.9857 |
| `-global_quality 18` | 4718 kbps | 0.9879 |
| `-global_quality 15` | 7428 kbps | 0.9895 |

ICQ 21 sits at the knee: half again the bitrate buys 0.002 SSIM. Throughput with subtitle burn-in
included was **129 fps** with software decode and **173 fps** with
`-hwaccel qsv -hwaccel_output_format qsv` (142,560 frames took 16.5 min).

**The decode side matters too.** A 3840×2072 HEVC 10-bit source on an Intel Arc A770, 60 s
sample, encode held constant:

| Decode path | Speed |
|---|---|
| software (default) | 124 fps |
| `-hwaccel qsv` alone (frames to system memory) | failed on this input |
| `-hwaccel qsv -hwaccel_output_format qsv` + `-vf "hwdownload,format=p010le,…"` | **173 fps** |

The hardware path is ~40 % faster but not bit-identical to the reference decoder: the same
frame compared at **PSNR 43.8 dB / SSIM 0.988**, i.e. 10-bit→8-bit rounding. Either is fine for
delivery; take software decode when you want the reference result and can spare the minutes.

## 5. Verify the result

```powershell
& $ffprobe -v error -show_entries "stream=index,codec_type,codec_name,profile,level,pix_fmt,width,height,r_frame_rate,channels,channel_layout,sample_rate,bit_rate,codec_tag_string,nb_frames" -show_entries "format=duration,size,bit_rate,nb_streams" -of default=noprint_wrappers=0 <out>

# faststart: moov must appear before mdat inside the first megabytes
$fs=[System.IO.File]::OpenRead(<out>); $buf=New-Object byte[] (2MB); $n=$fs.Read($buf,0,$buf.Length); $fs.Close()
$txt=[System.Text.Encoding]::ASCII.GetString($buf,0,$n); $txt.IndexOf('moov')

& $ff -v error -i <out> -map 0:v:0 -c copy -f null -   # container/bitstream parse
& $ff -v error -i <out> -map 0:a:0 -f null -            # full audio decode
```

Or run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\verify-vrchat-mp4.ps1 -Path <out> -Integrity`, which performs these checks and prints a PASS/FAIL verdict.

Frame inspection when subtitles were burned in (stack several timestamps into one image and read it):

```powershell
& $ff -v error -y -ss 5019.5 -i <out> -frames:v 1 <work>\f2.png
& $ff -v error -y -i <work>\f1.png -i <work>\f2.png -i <work>\f3.png `
  -filter_complex "[0:v]scale=960:-1[a];[1:v]scale=960:-1[b];[2:v]scale=960:-1[c];[a][b][c]vstack=inputs=3" <work>\montage.png
```

Pick timestamps from the subtitle file, not at random: a cue that ended 0.04 s before the sampled frame looks exactly like a failed burn-in.

## 6. Graft another release's audio onto this video

A user may want one file's picture and subtitles together with a different file's audio — an
already-approved track, or a better mix. If both are the same film this is a `-c copy` mux, but
only once the timelines are *proven* to agree. Releases routinely differ by a second or more: a
different opening logo, a slightly different cut, or a container duration inflated by one long
audio track (see [measurement-pitfalls.md](measurement-pitfalls.md)).

Measure the offset, then shift the audio input:

```powershell
& $ff -hide_banner -v warning -stats -y -i <new-video.mp4> -itsoffset 1.0 -i <old-audio.mp4> `
  -map 0:v:0 -map 1:a:0 -map 1:a:1 -c copy `
  -movflags +faststart -map_metadata -1 -map_chapters -1 <out.mp4>
```

`-itsoffset` shifts that input's timestamps so the audio is still *copied*, not re-encoded — no
second generation. It must sit **before** the input it applies to. Verify the shift landed:

```powershell
& $ffprobe -v error -select_streams a:0 -show_entries packet=pts_time -read_intervals "%+#1" -of default=nw=1 <out.mp4>
# expect the offset value itself, e.g. pts_time=0.978667 for -itsoffset 1.0
```

Then confirm it *content-wise*, because a structurally correct offset can still be the wrong
number: a correct offset makes speech onsets land on the subtitle cue starts (+11.2 dB mean rise
across 8 cues, against −3.4 dB for a deliberately wrong one) — procedure in
[measurement-pitfalls.md](measurement-pitfalls.md).

Encode the video once and mux audio variants afterwards: with the subtitle-free or burned master
kept, changing the audio is a one-minute operation instead of a re-encode.

## 7. Tag an untagged source, and repair tags afterwards

`color_space`/`color_transfer`/`color_primaries = unknown` is common, especially in fan remuxes.
Players then guess, and the guess is not always 709. The encoder writes its VUI from the
**frames'** metadata, so output flags alone are not enough:

```powershell
# WRONG for an untagged source — the flags never reach the encoder's VUI
-vf "scale=1920:1036,subtitles=sub.ass" … -color_primaries bt709 -color_trc bt709
#   -> color_space=bt709, but color_transfer/color_primaries stay unknown

# RIGHT — set it on the frames
-vf "scale=1920:1036,subtitles=sub.ass,setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv"
```

Repairing an already-encoded file is a copy, not a re-encode — both of these work on a finished MP4:

```powershell
& $ff -y -i in.mp4 -c copy -color_primaries bt709 -color_trc bt709 -colorspace bt709 -movflags +faststart out.mp4
& $ff -y -i in.mp4 -c copy -bsf:v "h264_metadata=colour_primaries=1:transfer_characteristics=1:matrix_coefficients=1" out.mp4
```

Confirm the repair touched nothing else — the video stream's packet MD5 must be unchanged:

```powershell
& $ff -v error -i in.mp4  -map 0:v:0 -c copy -f md5 -
& $ff -v error -i out.mp4 -map 0:v:0 -c copy -f md5 -
```

