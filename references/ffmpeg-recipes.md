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

```powershell
# extract, then style
& $ff -v error -y -i <src> -map 0:s:0 <work>\sub.srt
& $ff -v error -y -i <work>\sub.srt <work>\sub.ass
```

Edit `sub.ass`: `PlayResX: 1920`, `PlayResY: 1080`, and replace the style line with

```
Style: Default,Microsoft YaHei,56,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,2,10,10,45,1
```

(`Fontname` must cover the subtitle language — `Microsoft YaHei` for Simplified Chinese, `Microsoft JhengHei` for Traditional, `Meiryo`/`Yu Gothic` for Japanese, `Malgun Gothic` for Korean. Without a CJK-capable font, libass renders tofu boxes.)

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

**Sample gotcha:** `-ss` before `-i` resets output timestamps, so the subtitle filter then shows cues from the start of the file. To check rendering, encode a short span **from 0** (`-t 40`) and extract the frame afterwards:

```powershell
& $ff -v error -y -t 40 -i <src> -vf "subtitles=sub.ass" -c:v libx264 -preset ultrafast -crf 20 -an <work>\sample.mp4
& $ff -v error -y -ss 36.4 -i <work>\sample.mp4 -frames:v 1 <work>\frame.png
```

## 4. Choose the encoder by measurement

```powershell
foreach ($t in 600, 4200, 6900) {
  & $ff -v error -y -ss $t -t 30 -i <src> -an -c:v libx264   -preset medium -crf 20 -pix_fmt yuv420p <work>\a.mp4
  & $ff -v error -y -ss $t -t 30 -i <src> -an -c:v h264_nvenc -preset p5    -cq 23  -pix_fmt yuv420p <work>\b.mp4
  & $ff -hide_banner -v info -ss $t -t 30 -i <src> -i <work>\a.mp4 -lavfi "[0:v][1:v]ssim" -f null -
  & $ff -hide_banner -v info -ss $t -t 30 -i <src> -i <work>\b.mp4 -lavfi "[0:v][1:v]psnr" -f null -
}
```

Measured on an i9-13900HX + RTX 5080 Laptop, 1080p24 film source (3 segments, `SSIM All`):

| Encoder | Speed | Average bitrate | SSIM (600 / 4200 / 6900 s) |
|---|---|---|---|
| `libx264 -preset medium -crf 20` | 118 fps (≈27 min for 2h12m) | 3249 kbps | 0.9852 / 0.9924 / 0.9795 |
| `h264_nvenc -preset p5 -cq 23` | 283 fps (≈12 min for 2h12m) | 3149 kbps | 0.9861 / 0.9927 / 0.9804 |

NVENC won on both size and SSIM here, so it was used. On other hardware or with heavy grain, `libx264 -preset slow` can win — measure, do not assume. Add `-g 120` (5-second GOP) for friendlier seeking over HTTP; it costs a little size.

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
