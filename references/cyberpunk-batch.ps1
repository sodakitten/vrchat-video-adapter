param(
  [Parameter(Mandatory=$true)][string]$Ff,
  [Parameter(Mandatory=$true)][string]$Fp,
  [Parameter(Mandatory=$true)][string]$Wd,
  [Parameter(Mandatory=$true)][string]$OutDir,
  [Parameter(Mandatory=$true)][string]$OutPrefix,
  [string]$FontName = 'SimHei',
  [int]$FontSize = 54,
  [int]$Icq = 21,
  [int]$SubStream = -1,
  [string]$SubLang = 'chi',
  [int]$AudioStream = 1,
  [string]$AudioLang = 'jpn',
  [int]$OutW = 1920,
  [int]$OutH = 1080,
  [string[]]$Sources
)

function Log([string]$m) { Write-Host ("[" + (Get-Date -Format 'HH:mm:ss') + "] " + $m) }

function Run([string]$exe, [string]$argStr, [string]$logPath) {
  $cmd = '"' + $exe + '" ' + $argStr + ' > "' + $logPath + '" 2>&1'
  cmd /c $cmd | Out-Null
  return $LASTEXITCODE
}

function ProbeFrames([string]$exe, [string]$file) {
  $v = (& $exe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=noprint_wrappers=1:nokey=1 $file 2>$null | Select-Object -First 1)
  if ($v) { $v = $v.Trim() }
  if ($v -and $v -ne 'N/A') { return $v }
  $t = (& $exe -v error -select_streams v:0 -show_entries stream_tags=NUMBER_OF_FRAMES -of default=noprint_wrappers=1:nokey=1 $file 2>$null | Select-Object -First 1)
  if ($t) { return $t.Trim() }
  return ''
}

function StyleLine([string]$font, [int]$size) {
  return "Style: Default," + $font + "," + $size + ",&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,60,60,50,1"
}

function ResolveSubOrdinal([string]$exe, [string]$file, [string]$wantLang) {
  $j = (& $exe -v error -select_streams s -show_entries stream=index:stream_tags=language,title -of json $file 2>$null | ConvertFrom-Json)
  $tradMark = [string][char]0x7E41
  $i = 0
  $fallback = -1
  foreach ($s in $j.streams) {
    if ("$($s.tags.language)" -eq $wantLang) {
      if ($fallback -lt 0) { $fallback = $i }
      if ("$($s.tags.title)" -notlike ("*" + $tradMark + "*")) { return $i }
    }
    $i++
  }
  return $fallback
}

foreach ($src in $Sources) {
  if (-not (Test-Path -LiteralPath $src)) { Log ("MISSING: " + $src); continue }
  $base = [IO.Path]::GetFileNameWithoutExtension($src)
  $m = [regex]::Match($base, 'S(\d+)E(\d+)')
  if (-not $m.Success) { Log ("no episode id in " + $base); continue }
  $tag = "S" + $m.Groups[1].Value + "E" + $m.Groups[2].Value
  $nn = $m.Groups[2].Value
  Log ("=== " + $tag + " ===")

  $srt = Join-Path $Wd ("ep" + $nn + ".srt")
  $assRaw = Join-Path $Wd ("ep" + $nn + ".raw.ass")
  $ass = Join-Path $Wd ("ep" + $nn + ".ass")
  $m4a = Join-Path $Wd ("ep" + $nn + ".m4a")
  $vid = Join-Path $Wd ("ep" + $nn + ".video.mp4")
  $outFile = Join-Path $OutDir ($OutPrefix + " " + $tag + " VRChat.mp4")

  # ---- 1. subtitle: pick the stream, extract SRT, convert to ASS, restyle ----
  $subIdx = $SubStream
  if ($subIdx -lt 0) {
    $subIdx = ResolveSubOrdinal $Fp $src $SubLang
    if ($subIdx -lt 0) { Log ("  no subtitle with language=" + $SubLang); continue }
    Log ("  subtitle stream: ordinal " + $subIdx + " (language=" + $SubLang + ", first non-traditional)")
  }
  $code = Run $Ff ('-hide_banner -y -i "' + $src + '" -map 0:s:' + $subIdx + ' -c:s srt "' + $srt + '"') (Join-Path $Wd ("ep" + $nn + ".sub.log"))
  if ($code -ne 0 -or -not (Test-Path -LiteralPath $srt)) { Log "  subtitle extract FAILED"; continue }

  $code = Run $Ff ('-hide_banner -y -i "' + $srt + '" -c:s ass "' + $assRaw + '"') (Join-Path $Wd ("ep" + $nn + ".ass.log"))
  if ($code -ne 0 -or -not (Test-Path -LiteralPath $assRaw)) { Log "  srt->ass FAILED"; continue }

  $wantStyle = StyleLine $FontName $FontSize
  $lines = Get-Content -LiteralPath $assRaw -Encoding UTF8
  $patched = foreach ($l in $lines) {
    if ($l -match '^PlayResX:') { "PlayResX: " + $OutW }
    elseif ($l -match '^PlayResY:') { "PlayResY: " + $OutH }
    elseif ($l -match '^Style: ') { $wantStyle }
    else { $l }
  }
  [IO.File]::WriteAllLines($ass, $patched, (New-Object Text.UTF8Encoding($false)))
  $cueCount = ($patched | Where-Object { $_ -match '^Dialogue: ' }).Count
  Log ("  subtitle ok: " + $cueCount + " lines -> " + $FontName + " " + $FontSize)
  if ($cueCount -lt 1) { Log "  EMPTY subtitle, aborting episode"; continue }

  # ---- 2. audio: E-AC-3 5.1 -> AAC-LC 5.1 ----
  $code = Run $Ff ('-hide_banner -y -i "' + $src + '" -map 0:a:' + $AudioStream + ' -vn -sn -dn -c:a aac -b:a 640k -ac 6 -ar 48000 -map_metadata -1 -f mp4 "' + $m4a + '"') (Join-Path $Wd ("ep" + $nn + ".audio.log"))
  if ($code -ne 0 -or -not (Test-Path -LiteralPath $m4a)) { Log "  audio FAILED"; continue }
  Log ("  audio ok: " + [math]::Round((Get-Item -LiteralPath $m4a).Length / 1MB, 1) + " MB")

  # ---- 3. video: HDR10 -> SDR 1080p, burn the ASS ----
  $assName = [IO.Path]::GetFileName($ass)
  $vf = 'hwdownload,format=p010le,libplacebo=w=' + $OutW + ':h=' + $OutH + ':tonemapping=bt.2390:colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv:format=yuv420p,ass=' + $assName + ',setparams=colorspace=bt709:color_primaries=bt709:color_trc=bt709:range=tv'
  $arg = '-hide_banner -y -init_hw_device vulkan=vk -filter_hw_device vk -hwaccel qsv -i "' + $src + '" -map 0:v:0 -vf "' + $vf + '"'
  $arg += ' -c:v h264_qsv -preset veryslow -global_quality ' + $Icq + ' -look_ahead 1 -profile:v high -level 4.0 -g 240 -fps_mode cfr'
  $arg += ' -an -sn -map_metadata -1 -map_chapters -1 -f mp4 "' + $vid + '"'
  Push-Location -LiteralPath $Wd
  try {
    $code = Run $Ff $arg (Join-Path $Wd ("ep" + $nn + ".video.log"))
  } finally {
    Pop-Location
  }
  if ($code -ne 0 -or -not (Test-Path -LiteralPath $vid)) { Log ("  video FAILED (exit " + $code + ")"); continue }
  Log ("  video ok: " + [math]::Round((Get-Item -LiteralPath $vid).Length / 1MB, 1) + " MB")

  # ---- 4. mux ----
  $arg = '-hide_banner -y -i "' + $vid + '" -i "' + $m4a + '" -map 0:v:0 -map 1:a:0 -c copy -movflags +faststart'
  $arg += ' -metadata:s:a:0 language=' + $AudioLang + ' -disposition:a:0 default -map_metadata -1 -map_chapters -1 -f mp4 "' + $outFile + '"'
  $code = Run $Ff $arg (Join-Path $Wd ("ep" + $nn + ".mux.log"))
  if ($code -ne 0 -or -not (Test-Path -LiteralPath $outFile)) { Log "  mux FAILED"; continue }

  # ---- 5. verify ----
  $srcFrames = ProbeFrames $Fp $src
  $outFrames = ProbeFrames $Fp $outFile
  $tracks = (& $Fp -v error -select_streams a -show_entries stream=index -of csv=p=0 $outFile 2>$null)
  $trackCount = @($tracks | Where-Object { $_ }).Count
  $sizeMB = [math]::Round((Get-Item -LiteralPath $outFile).Length / 1MB, 1)
  Log ("  DONE " + $tag + ": " + $sizeMB + " MB  srcFrames=" + $srcFrames + " outFrames=" + $outFrames + " audioTracks=" + $trackCount + " -> " + $outFile)
}
Log "ALL DONE"
