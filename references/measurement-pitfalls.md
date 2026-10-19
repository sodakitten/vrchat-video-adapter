# Measurements that lie, and how to make them trustworthy

Every number quoted in this skill was produced by one of these procedures. They exist because
the naive version of each one produced a confident wrong answer first.

## 1. `ssim` / `psnr` pair frames by TIMESTAMP, not by index

Comparing an encode against a reference that lives in a **different container** silently
misaligns them. An MKV reference sits on a 1/1000 timebase and the MP4 encode on 1/24000;
framesync rounds the two timelines together, so frame *n* of one is compared with frame *n±1*
of the other partway through the clip.

Symptom seen in practice: a quality sweep reported **higher bitrate scoring lower SSIM** — ICQ 18
(4718 kbps) at 0.9643 against ICQ 15 (7428 kbps) at 0.9650, both below the delivered ICQ 21
(4122 kbps) at 0.9857. Raised bitrate cannot reduce SSIM; the ordering was an artifact.

**Always run a control first.** Encode the reference losslessly and compare it with itself through
the exact same command. It must report `SSIM All:1.000000 (inf)`. The run above reported
**0.9686**, which is what exposed the bug rather than confirming it.

Pin both inputs to a common timebase and pair by frame index:

```powershell
$fix = '[0:v]settb=1/24000,setpts=N[a];[1:v]settb=1/24000,setpts=N[b];[a][b]ssim'
& $ff -hide_banner -i <reference> -i <encode> -lavfi $fix -f null NUL 2> ssim.txt
Select-String -Path ssim.txt -Pattern 'SSIM'
```

With that fix the control returns 1.000000 and the sweep orders correctly (ICQ 21 0.9857 <
ICQ 18 0.9879 < ICQ 15 0.9895). Consequence to keep in mind: **any earlier SSIM figure that
crossed containers is suspect** — the relative "more bitrate buys little" conclusion usually
survives, the absolute values do not.

## 2. Container duration is not video duration

A `format=duration` that exceeds the source's by 30 s does not mean the picture differs — often
one audio track is simply longer (trailing silence, a different edit, an added dub). Measure each
stream by decoding it:

```powershell
foreach ($i in 0,1,2,3) {
  $out = & $ff -hide_banner -nostdin -i <file> -map "0:a:$i" -f null NUL 2>&1
  ($out | Select-String 'time=' | Select-Object -Last 1).Line
}
```

Two real cases, both of which looked like a 31 s content difference and were not:

| File | `format=duration` | Longest audio stream | Video stream |
|---|---|---|---|
| GitS 1995 remux | 4989.94 s | Cantonese AAC 4989.94 s | 118,920 frames = 4959.96 s |
| Innocence remux | 5982.26 s | — | 142,560 frames = 5945.96 s |

The video streams differed from the other release by 24 frames (1.0 s), not by 31 s.

## 3. Measuring a timeline offset between two releases

Three independent methods; use at least two, because each has a failure mode.

**(a) Frame count.** `ffprobe -select_streams v:0 -count_frames -show_entries stream=nb_read_frames`
(or the Matroska `NUMBER_OF_FRAMES` tag). A difference of N frames at 23.976 fps is N/23.976 s of
material — 24 frames ≈ 1.001 s. This bounds the difference but not its location.

**(b) Matching subtitle text.** When both releases carry the same translation, the same line's
cue start differs by exactly the offset. Here: old PGS 2408.03 s vs new ASS 2408.92 s = +0.89 s.
Cheap, frame-accurate enough, but only as good as the two authors' cue-placement habits.

**(c) Edge-map SSIM sweep (grade-invariant).** Different masters are graded differently, so a
luma comparison is noisy; **edges** survive a regrade. Convert both frames to edge maps, then
SSIM them for a range of offsets `d`:

```powershell
$vf = "scale=$W`:$H,edgedetect=low=0.08:high=0.25,format=gray"
& $ff -v error -y -ss <t>       -i <old> -frames:v 1 -vf $vf <wd>\old.png
& $ff -v error -y -ss (<t>+$d)  -i <new> -frames:v 1 -vf $vf <wd>\new.png
& $ff -hide_banner -i <wd>\old.png -i <wd>\new.png -lavfi ssim -f null NUL 2> s.txt
```

Pick timestamps where the three candidates differ (a busy scene, not a slow pan). State the sign
convention explicitly before measuring, because inverting it is the easiest way to ship a
one-second error: here `d` compares **`new@(t+d)` against `old@t`**, so a peak at `d=+1.00` means
the new release's timeline runs 1.0 s later, and the old audio must be **delayed** by 1.0 s
(`-itsoffset 1.0`). A real result looks like a peak, not a plateau:

| offset d | t=3300 s | t=3900 s |
|---|---|---|
| 0.80 | 0.6529 | 0.7365 |
| **1.00** | **0.6835** | **0.7428** |
| 1.10 | 0.6551 | 0.7410 |

Refine to the frame grid (42 ms at 23.976 fps): offsets within ±20 ms of the truth return the
same frame and therefore the same score, so the plateau edges bound the offset.

**What does not work:** comparing scene-cut lists across two releases. Detection thresholds fire
on different frames when the grade, grain or encoder differ, and the differences came out as
−43.8, −17.8, −4.1, +1.0, +6.9 s across one 400 s window while the true offset was a constant
1.0 s. Frame counts differ between encodes; cuts do not.

## 4. Proving a shift is right, content-wise

A structurally valid offset (`pts_time=0.978667`) only proves the number was written. To prove it
is the *correct* number, test whether audio events land where the subtitles say they do: parse
cue starts from the subtitle file, then compare the mean volume in the 250 ms before a cue with
the 550 ms after it.

```powershell
# per cue: pre = [start-0.30, start-0.05], post = [start+0.05, start+0.60]
& $ff -v info -ss (<start>-0.30) -t 0.25 -i <out.mp4> -map 0:a:0 -af volumedetect -f null NUL 2> pre.txt
& $ff -v info -ss (<start>+0.05) -t 0.55 -i <out.mp4> -map 0:a:0 -af volumedetect -f null NUL 2> post.txt
```

Run it twice: once as delivered, once with every window shifted by the disputed amount. The
correct alignment shows speech *starting* at the cues; the control does not.

| Measurement | Mean onset rise (8 cues) |
|---|---|
| delay applied as measured | **+11.19 dB** |
| same file, windows shifted +1 s | −3.41 dB |

Spread the cues across the whole film — openings and endings are unrepresentative — and skip the
first minute.

## 5. Packet MD5 to prove a copy changed nothing

Any `-c copy` step (a tag repair, an audio swap, a faststart rewrite) can be shown to have left
the picture alone by hashing the video packets, before and after:

```powershell
& $ff -v error -i <before.mp4> -map 0:v:0 -c copy -f md5 -
& $ff -v error -i <after.mp4>  -map 0:v:0 -c copy -f md5 -
```

Identical hashes mean the bitstream is untouched. This is *not* a pixel comparison between two
different encodes — two encoders writing identical pixels emit different bytes; for that, decode
to rawvideo and hash, or use `psnr`/`ssim` with the timebase fix from section 1.
