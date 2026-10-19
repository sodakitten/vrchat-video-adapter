# Diagnosing "the audio sounds wrong" in VRChat

## First question: is it your encode, or the player?

VRChat on PC is AVPro Video → Windows Media Foundation → Unity. Any of those can touch multichannel audio. Before changing your encode, prove what it actually contains.

Compare the source and your output **per channel** over the same short window. If every channel matches within ~0.2 dB and the phase relationship is intact, the encode is faithful — the player's multichannel handling is then the only suspect.

```powershell
# one measurement: mono-sum a single channel (or a band) and read volumedetect
& $ff -hide_banner -v info -ss 5000 -t 30 -i <file> -map 0:a:0 `
     -af "pan=mono|c0=c0,volumedetect" -f null - 2> out.txt
Select-String -Path out.txt -Pattern 'mean_volume|max_volume'
```

For 5.1(side) the input channels are `c0..c5 = FL, FR, FC, LFE, SL, SR`.

| Test (`pan=...`) | What it rules out |
|---|---|
| `mono\|c0=c0` … `c0=c5`, one per channel | level changes, a dead or mis-mapped channel |
| `mono\|c0=c2,highpass=f=400` vs `lowpass=f=120` | a real center channel (full-range) vs swapped LFE (bass only) |
| `mono\|c0=c3,highpass=f=400` | LFE containing speech = center/LFE written in the wrong order |
| `mono\|c0=c2,highpass=f=10000` | encoder band-limiting the dialogue band |
| `mono\|c0=c2+0.5*c0+0.5*c1` vs `c2-0.5*c0-0.5*c1` | phase inversion: if the difference is louder than the sum, a downmix cancels the vocals |
| `stereo\|c0=...c1=...` | what a downmix will actually sound like |

Measured example — 30 s at 5000 s, dB mean / max, E-AC-3 5.1 master vs the AAC 5.1 deliverable made from it:

| Test | Master E-AC-3 | AAC 5.1 | Verdict |
|---|---|---|---|
| FL / FR / FC | -22.4 / -22.7 / -22.1 | -22.4 / -22.8 / -22.2 | identical |
| LFE | -39.4 | -39.4 | identical |
| SL / SR | -21.2 / -21.6 | -21.3 / -21.6 | identical |
| FC >10 kHz | -43.4 | -43.6 | no band-limiting |
| LFE >400 Hz | -77.5 | -77.5 | true LFE, no swap |
| sum vs difference | -18.7 vs -21.2 | -18.7 vs -21.3 | in phase, no cancellation |

That encodes as: **the transcode changed nothing measurable**, so the complaint had to come from playback, not from the encode. Say this before touching the file again — it redirects the fix from "encode better" (pointless) to "stop making the player downmix".

Also sanity-check the mix itself across several scenes before blaming anything: the surrounds in one window measured only 1 dB below the fronts, but across four scenes they ranged from -8.3 dB to +1.1 dB relative to FL, i.e. an ambient action scene rather than a broken mix.

## The usual fix: deliver stereo 2.0

Windows Media Foundation renders 5.1 → 2.0 on its own, and Unity's own downmix sits behind that. A 2.0 track removes every one of those variables, and it is what a VR headset or headphones uses anyway.

Measured, not assumed: transcoding a window of a 5.1 AAC file through `MediaTranscoder` with `MediaEncodingProfile::CreateWav(...)` produced `pcm_s16le`, 48000 Hz, **2 channels** — the OS collapses the 5.1 track before VRChat's own mixer ever sees it, so nothing downstream can restore what that downmix does. (Reproduce with the `mf_decode.ps1` helper; note it only captures the first ~2 s, because Windows PowerShell 5.1 cannot await the `IAsyncAction` that `TranscodeAsync` returns. The same call on an E-AC-3 input reports `CanTranscode = False`, independently reconfirming why the audio had to be re-encoded at all.)

ITU-R BS.775 matrix with 1 dB of headroom (`0.891 = -1 dB`), LFE excluded:

```powershell
-af "pan=stereo|c0=0.891*c0+0.630*c2+0.630*c4|c1=0.891*c1+0.630*c2+0.630*c5"
```

`0.630 = 0.707 * 0.891` folds the center and surrounds in at -3 dB, as the standard requires.

Check headroom on the finished file; the number that matters is the **true peak after decoding**, because that already includes codec overshoot:

```powershell
& $ff -hide_banner -v info -i out.mp4 -af ebur128=peak=true -f null - 2> ebur.txt
Select-String -Path ebur.txt -Pattern 'I:|LRA:|Peak:'
```

A 2h12m downmix measured I: -20.1 LUFS, LRA: 21.1 LU, true peak: -0.4 dBFS — no clipping.

## Fix only the audio; reuse the video you already verified

Re-encoding video that is already correct wastes an hour and loses a generation. When the picture (including burned-in subtitles) is good, copy it and take the new audio from the master:

```powershell
& $ff -y -i burned.mp4 -i master.mkv -map 0:v:0 -map 1:a:0 -c:v copy `
      -af "<downmix matrix>" -c:a aac -b:a 320k -ar 48000 `
      -movflags +faststart -map_metadata -1 -map_chapters -1 out.mp4
```

Prove the picture is untouched — the packet MD5 of the video stream must be identical:

```powershell
& $ff -v error -i old.mp4 -map 0:v:0 -c copy -f md5 -
& $ff -v error -i new.mp4 -map 0:v:0 -c copy -f md5 -
```

Also confirm both inputs share `start_time` (`ffprobe -show_entries stream=start_time`) so the copied video and the new audio stay in sync.

## PowerShell traps that silently corrupt an ffmpeg call

These produce wrong results without an error at the PowerShell level, so the ffmpeg error message is the only clue:

| Trap | Symptom |
|---|---|
| a function parameter named `$input` (an automatic variable) | `-i $input` expands to nothing; ffmpeg reports `Error opening input file -map` |
| a function parameter named `$args` (also automatic) | `@args` expands to nothing, so ffmpeg runs with **zero** arguments and every call looks like an unexplained failure |
| **variable names are case-insensitive** | a local `$vid` clobbers a `$Vid` parameter: `-i $Vid … $vid` becomes output-as-input, and ffmpeg reports `Error opening input file <the output path>` |
| a function named `Measure`, `Select`, `Where`, `Sort`, `Group`, `ForEach` | resolves to the built-in alias, so your function never runs |
| non-ASCII written into a script — **including a parameter default** | 5.1 reads the BOM-less file as ANSI, so `D:\电影\` becomes `D:\鐢靛奖\` and every path "does not exist". Keep scripts ASCII and pass such paths as arguments; the command line itself is Unicode-safe |
| a helper that logs with `Write-Output` and also returns a value | the log lines join the return value, so `if ($result)` is true even on failure and a broken run reports success. Log with `Write-Host`, return only the boolean |
| `Get-ChildItem -Filter` given an array | `Cannot convert 'System.Object[]' to the type 'System.String'`; use one pattern, or `-Include` with `-Recurse`, or filter with `Where-Object` |
| `$o = & ffmpeg ... 2>&1` in Windows PowerShell 5.1 | native stderr arrives as ErrorRecords asynchronously and can be attributed to the *next* command; redirect to a file (`2> out.txt`) and parse the file instead |
| reading a `.ps1` without a BOM as a script | non-ASCII becomes mojibake under 5.1; keep helper scripts ASCII-only |
