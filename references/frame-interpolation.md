# Frame interpolation for VRChat (verified 24 -> 45 fps)

Every number below was measured, not estimated. Reference machine: i9-13900HX, RTX 5080
Laptop (16 GB, driver 617.42), Windows 11; source = 1080p24 H.264 ~6 Mbps, 2h12m,
190,274 frames, with burned-in subtitles and a stereo AAC track.

## Choose the target rate from the headset, not from habit

"Interpolate to 60" is the wrong instinct. Match the display refresh:

| headset | 24 fps | 30 fps | 45 fps | 60 fps |
|---|---|---|---|---|
| 72 Hz | 3 refreshes/frame | uneven | uneven | uneven |
| 90 Hz | 4,4,4,3 cycle (judder) | **3 - even** | **2 - even** | 3:2 cycle (judder) |

45 fps is the sweet spot at 90 Hz: perfectly even pacing and a smaller bitrate bump than
60 fps. 30 fps is the cheap conservative option; 60 fps is strictly worse than 45 on 90 Hz.
1080p45 = 8160 x 45 = 367,200 MB/s, i.e. H.264 **Level 4.2** (L4.1 caps at 245,760) — still
inside VRChat's High L5.1 ceiling. Use `-g 225` (5 s) at 45 fps, not the 120 used at 24 fps.

Caveat worth stating to the user: even pacing assumes the player presents frames on display
refreshes, which is normal but not documented for VRChat's AVPro path.

## Tooling

`rife-ncnn-vulkan` (nihui) release **20221029**, Windows zip, 411 MB — it contains every
model from v2 to v4.6. It runs fine on Blackwell: the GPU banner reports
`[0 NVIDIA GeForce RTX 5080 Laptop GPU] fp16-p/s/a=1/1/1`, contradicting third-party claims
that RTX 50-series cards need a rebuilt ncnn. On this machine **`rife-v2.3` produced 0 output
frames**; `rife-v4.6` (the default in the shipped script) works.

ffmpeg's own `minterpolate` is not a practical alternative: measured **2.9 fps of 1080p
output**, i.e. ~34 hours for this film, versus ~3.4 hours for the chunked RIFE pipeline.

Getting the zip: this machine's shell reaches github.com only through the local Clash proxy
(`-Proxy http://127.0.0.1:7897`); `objects.githubusercontent.com` and the `ghfast.top` /
`gh-proxy.com` mirrors also work. RIFE itself needs no installer, no registry writes.

## The chunk arithmetic (proved, not assumed)

Sequence mode (`-i indir -o outdir -n N`) is **uniform and endpoint-pinned**:

    out_j  =  in_(1 + (j-1) * (N_in - 1) / (N_out - 1))

Proof, on real frames: with `N_in = 241`, `N_out = 451`, output frame 1 is *pixel-identical*
to input frame 1 and output frame 451 is pixel-identical to input frame 241 (PSNR = `inf`
after decoding both to raw RGB24), while neighbouring pairs measure ~32 dB — so the middle
frames really are synthesised. Compare decoded pixels, never PNG file hashes.

So for 24 -> 45 fps choose `N_in = 8k+1`, `N_out = 15k+1`:

| k | source frames | input seconds | output frames |
|---|---|---|---|
| 15 | 121 | 5.000 | 226 |
| **30** | **241** | **10.000** | **451** |
| 60 | 481 | 20.000 | 901 |

Per chunk: feed `N_in` contiguous source frames, run `-n N_out`, then **encode only the first
`N_out - 1` frames** — the last one duplicates the next chunk's first frame. Chunk m thus
ends exactly where chunk m+1 begins: no gap, no repeated frame. The final chunk keeps all
`N_out` frames so the film's true last frame survives.

For a partial tail chunk use `N_out = round((N_in - 1) * 45 / 24) + 1`.

## Speed and disk, measured

| stage | measured rate | whole film (2h12m) |
|---|---|---|
| PNG frame extraction | 121 fps (1.05 MB/frame) | ~26 min |
| RIFE `-j 4:8:8`, v4.6 | 45 output fps | ~2.2 h |
| RIFE `-j 1:2:2` (default) | 20 output fps | ~4.9 h |
| NVENC `p5 -cq 23` + libass subtitles | ~180 fps | ~33 min |
| **end to end, per 10 s chunk** | **~15 s** | **~3.4 h for 793 chunks** |

`-j 4:8:8` was worth 2.2x over the default — try it before accepting the tool's own default.
`-x` (spatial TTA) and `-z` (**temporal** TTA in this build, not a compression switch) cost
time; `-u` is UHD mode. Leave all three off for 1080p.

Frame format, measured over a 240-frame window:

| format | bytes/frame | extraction | peak temp, 10 s chunk | cumulative write |
|---|---|---|---|---|
| PNG default | 1.05 MB | 121 fps | 0.7 GB | 562 GB |
| PNG `-compression_level 1` | 1.76 MB | 366 fps | 1.2 GB | 941 GB |
| JPEG `-q:v 1` | 0.14 MB | 519 fps | 0.1 GB | 74 GB |

PNG is fast enough to keep lossless. Note what these numbers mean for the user's disk: the
peak is **under 1 GB per chunk** because each chunk is deleted before the next; the hundreds
of GB are throughput spread over hours, not standing usage. Allocate the output and any
intermediate video to a drive with room for the result, not for the throughput figure.

## Size cost

At the same `-cq`/CRF, 45 fps costs **1.47x** the 24 fps video bitrate — measured on both a
low-complexity window (1321 kbps) and a high-complexity one (4484 -> 6593 kbps). Frame count
does not drive size; bitrate x duration does, and interpolated frames predict well.

A 2h12m 1080p24 film at ~4.0 Mbps therefore lands near **5.9 GiB at 45 fps** versus 3.99 GiB
at 24 fps (+47%), with the audio reused via `-c:a copy`. Beware projecting from the first few
chunks of a film: a dark opening (2.3 Mbps) or a mid-film action beat (12.4 Mbps) will
mislead you by 2x in either direction.

## End-to-end result (the run this reference is based on)

2h12m 1080p24 -> 45 fps, subtitles burned in, stereo AAC reused via `-c:a copy`:

| | |
|---|---|
| chunks | 793 (241 -> 451 frames each; the tail 194 -> 363) |
| wall clock | **196.5 min** — extract 34 min + RIFE 135 min + encode 25 min |
| output | 356,763 frames / 7928.067 s = exactly `792 x 450 + 363`, one frame from the source's own length |
| size | 5.77 GiB; video 5950 kbps = **1.48x** the 24 fps encode |
| audio | packet MD5 **identical** to the pre-interpolation file |
| seams | 0 duplicate frames at every boundary checked (`inf` PSNR would betray one) |
| first / last frame | pixel-identical / 92 dB PSNR against the 24 fps encode |
| full decode | 356,763 frames + audio decoded with zero errors |

Two checks to repeat on any run, because they catch whole classes of silent failure:
the total frame count must equal `nFull * (N_out - 1) + tailKeep` **exactly** (any dropped
or duplicated frame changes it), and the finished file's audio packet MD5 must match the
pre-mux file (that is what proves `-c:a copy` actually copied rather than re-encoded).

## Pipeline shape

1. Extract `N_in` frames from the source with `-ss <chunkStart> -frames:v N_in -fps_mode
   passthrough -c:v png`. Verify the count matches exactly; abort otherwise.
2. Run RIFE from its own directory (the `-m` model path is relative to the CWD), redirecting
   its output through `cmd /c`.
3. Write a per-chunk `.ass`: every `Dialogue:` time shifted by `-chunkStart`, cues ending
   before 0 dropped, starts clamped at 0, header copied verbatim. Cues spanning a boundary
   are re-emitted in the next chunk and stay continuous. Encode **from the frames**, with the
   chunk's own zero-based timeline, and write it UTF-8 **without** BOM.
4. Encode the chunk video-only (subtitles burned, `-an`) to `<chunk>.part.mp4`, then rename —
   so a crash mid-chunk leaves no half-chunk that resume would trust.
5. Concatenate with `-f concat -c copy`, then mux the untouched stereo AAC with `-c:a copy`
   and `-movflags +faststart`.

Use [scripts/interpolate-rife.ps1](../scripts/interpolate-rife.ps1): parameterised, chunked,
resumable (existing chunks are skipped, so re-running continues an interrupted job), with
stall-tolerant progress logging. For a sample, run 3 chunks and mux with `-AudioStart` set to
the sampled region and `-MaxDuration` set to the sample length.

Verify the sample before committing to hours: exact frame count (`chunks x (N_out-1)`),
duration, `High L4.2`, `moov` at the front, and no `inf` PSNR between adjacent frames across
a chunk boundary (an `inf` pair would mean a duplicated frame; a short frame count means a
dropped one).

## Pitfalls, all hit in practice

- `Start-Process -ArgumentList` accepts an array but joins it **unquoted**, so a path with a
  space splits and its tail binds to the next parameter
  (`无法将值"AMZN"转换为类型"System.Int32"`). Pass one quoted string, or write a zero-argument
  launcher `.ps1` (UTF-8 **with BOM**) that holds the paths and start that.
- `$ErrorActionPreference = 'Stop'` plus a native command that writes to stderr raises a
  terminating `NativeCommandError` — so a tool that merely prints its GPU banner "fails".
  Let `cmd /c '"exe" ... > log 2>&1'` own the redirection.
- ffmpeg 9 removed `-vsync`; use `-fps_mode passthrough`.
- Never compare PNG files by MD5 to test pixel equality: two encoders writing identical
  pixels produce different bytes. Decode to rawvideo and hash that, or use `psnr`.
- A watcher that greps several trailing log lines can match a **stale** completion marker
  from an earlier run of the same log. Match the last line only.
- Keep helper scripts ASCII-only, or write them with a UTF-8 BOM: Windows PowerShell 5.1
  reads BOM-less `.ps1` as ANSI and mangles non-ASCII paths into "file not found".
