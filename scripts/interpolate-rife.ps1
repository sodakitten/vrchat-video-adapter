<#
  RIFE frame interpolation 24 -> 45 fps for a VRChat-bound MP4. Chunked and resumable.

  Chunk recipe, verified against rife-ncnn-vulkan 20221029 on this machine:
    - Feed 241 contiguous source frames  = exactly 10.000 s at 24 fps
    - Run with -n 451                   = exactly 10.000 s at 45 fps
    - Pixel test (PSNR = inf) proves output frame 1 == input frame 1 and
      output frame 451 == input frame 241, so the mapping is uniform and
      endpoint-pinned: out_j -> in_(1 + (j-1)*240/450), ratio exactly 45/24.
    - Keep the first 450 frames, drop the duplicate boundary frame, so chunk
      m ends where chunk m+1 begins with no gap and no repeated frame.

  Everything here is ASCII on purpose: PowerShell 5.1 reads BOM-less .ps1 as
  ANSI (gb2312 on this machine) and mangles non-ASCII literals. Paths that do
  contain non-ASCII characters are passed in as parameters.
#>
param(
  [Parameter(Mandatory=$true)][string]$Master,
  [Parameter(Mandatory=$true)][string]$RifeDir,
  [Parameter(Mandatory=$true)][string]$Work,
  [Parameter(Mandatory=$true)][string]$SubAss,
  [Parameter(Mandatory=$true)][string]$Stereo,
  [string]$FinalOut = '',
  [int]$FirstChunk = 0,
  [int]$ChunkCount = 0,
  [double]$ChunkSeconds = 10,
  [int]$TotalSrcFrames = 190274,
  [double]$AudioStart = 0,
  [double]$MaxDuration = 0,
  [string]$Ffmpeg = 'C:\Users\paulxstx\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-full_build\bin\ffmpeg.exe'
)

$ErrorActionPreference = 'Stop'

$exe   = Join-Path $RifeDir 'rife-ncnn-vulkan.exe'
$model = 'rife-v4.6'
$fpsIn = 24.0
$fpsOut = 45.0

$srcPerChunk = [int][math]::Round($ChunkSeconds * $fpsIn)          # 240
$inPerChunk  = $srcPerChunk + 1                                    # 241
$outPerChunk = [int][math]::Round($srcPerChunk * $fpsOut / $fpsIn) + 1   # 451
$chunkCs     = [int][math]::Round($ChunkSeconds * 100)             # 1000
$totalChunks = [int][math]::Ceiling($TotalSrcFrames / [double]$srcPerChunk)

$tempIn    = Join-Path $Work 'in'
$tempOut   = Join-Path $Work 'out'
$chunksDir = Join-Path $Work 'chunks'
$log       = Join-Path $Work 'run.log'
$assChunk  = Join-Path $Work 'sub_chunk.ass'
$rifeLog   = Join-Path $Work 'rife_last.txt'
New-Item -ItemType Directory -Force -Path $tempIn, $tempOut, $chunksDir | Out-Null

function Log([string]$m) {
  $line = '[' + (Get-Date).ToString('HH:mm:ss') + '] ' + $m
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
  Write-Host $line
}
function ToCs([string]$t) {
  $p = $t.Split(':.')
  return ([int]$p[0] * 360000 + [int]$p[1] * 6000 + [int]$p[2] * 100 + [int]$p[3])
}
function ToAss([int]$cs) {
  if ($cs -lt 0) { $cs = 0 }
  $h = [int]($cs / 360000); $r = $cs % 360000
  $m = [int]($r / 6000);    $r = $r % 6000
  $s = [int]($r / 100);     $c = $r % 100
  return ('{0}:{1:00}:{2:00}.{3:00}' -f $h, $m, $s, $c)
}

# ---- parse the master subtitle file once -------------------------------------
$assLines = Get-Content -LiteralPath $SubAss -Encoding UTF8
$header = @($assLines | Where-Object { ($_ -notlike 'Dialogue:*') -and ($_ -notlike 'Comment:*') })
$cues = New-Object System.Collections.ArrayList
foreach ($l in $assLines) {
  if ($l -like 'Dialogue:*') {
    $p = $l.Split(',')
    if ($p.Count -ge 10) {
      $null = $cues.Add([pscustomobject]@{
        S = (ToCs $p[1]); E = (ToCs $p[2]); Text = (($p[9..($p.Count - 1)]) -join ',')
      })
    }
  }
}

Log ('START first={0} count={1} chunkSeconds={2} in={3} out={4} chunks_total={5} cues={6}' -f `
     $FirstChunk, $(if ($ChunkCount -gt 0) { $ChunkCount } else { $totalChunks - $FirstChunk }),
     $ChunkSeconds, $inPerChunk, $outPerChunk, $totalChunks, $cues.Count)

$last = if ($ChunkCount -gt 0) { [math]::Min($FirstChunk + $ChunkCount - 1, $totalChunks - 1) } else { $totalChunks - 1 }
$swAll = [Diagnostics.Stopwatch]::StartNew()
$done = 0; $skipped = 0; $tExtract = 0.0; $tRife = 0.0; $tEncode = 0.0

for ($chunk = $FirstChunk; $chunk -le $last; $chunk++) {
  $srcStart = $chunk * $srcPerChunk
  $nIn = [math]::Min($inPerChunk, $TotalSrcFrames - $srcStart)
  if ($nIn -lt 2) { Log ("chunk $chunk : nothing left, stop"); break }
  $nOut = [int][math]::Round(($nIn - 1) * $fpsOut / $fpsIn) + 1
  $isLast = (($srcStart + $nIn - 1) -eq ($TotalSrcFrames - 1))
  $keep = if ($isLast) { $nOut } else { $nOut - 1 }
  $startSec = $srcStart / $fpsIn

  $chunkFile = Join-Path $chunksDir ('chunk_{0:D4}.mp4' -f $chunk)
  if ((Test-Path -LiteralPath $chunkFile) -and ((Get-Item -LiteralPath $chunkFile).Length -gt 100000)) {
    $skipped++
    if (($skipped % 50) -eq 0) { Log ("resume: skipped $skipped chunks so far (at $chunk)") }
    continue
  }
  $partFile = $chunkFile + '.part.mp4'
  Remove-Item -LiteralPath $partFile -Force -ErrorAction SilentlyContinue
  Remove-Item "$tempIn\*", "$tempOut\*" -Force -ErrorAction SilentlyContinue

  # ---- 1. extract exactly nIn source frames (PNG, lossless) ------------------
  $t0 = [Diagnostics.Stopwatch]::StartNew()
  $ffArgs = @('-hide_banner','-v','error','-y','-ss',("{0:F6}" -f $startSec),'-i',$Master,
              '-an','-frames:v',$nIn,'-fps_mode','passthrough','-c:v','png', (Join-Path $tempIn 's_%06d.png'))
  & $Ffmpeg @ffArgs
  if ($LASTEXITCODE -ne 0) { throw "chunk $chunk : ffmpeg extract failed ($LASTEXITCODE)" }
  $got = @(Get-ChildItem "$tempIn\*.png").Count
  if ($got -ne $nIn) { throw "chunk $chunk : extracted $got frames, expected $nIn" }
  $tExtract += $t0.Elapsed.TotalSeconds

  # ---- 2. RIFE ---------------------------------------------------------------
  $t0 = [Diagnostics.Stopwatch]::StartNew()
  Push-Location $RifeDir
  try {
    # rife-ncnn-vulkan prints its GPU banner to stderr; with
    # $ErrorActionPreference = 'Stop' PowerShell turns any native stderr line
    # into a terminating NativeCommandError. Let cmd.exe own the redirection.
    $rcLine = '"{0}" -i "{1}" -o "{2}" -n {3} -m {4} -j 4:8:8 > "{5}" 2>&1' -f `
              $exe, $tempIn, $tempOut, $nOut, $model, $rifeLog
    & cmd.exe /c $rcLine | Out-Null
    $rc = $LASTEXITCODE
  } finally { Pop-Location }
  if ($rc -ne 0) {
    Log ("RIFE FAILED chunk $chunk exit=$rc ; tail of rife_last.txt:")
    Get-Content -LiteralPath $rifeLog -Tail 15 | ForEach-Object { Log ('  | ' + $_) }
    throw "chunk $chunk : rife failed"
  }
  $gotOut = @(Get-ChildItem "$tempOut\*.png").Count
  if ($gotOut -ne $nOut) { throw "chunk $chunk : rife produced $gotOut frames, expected $nOut" }
  $tRife += $t0.Elapsed.TotalSeconds

  # ---- 3. per-chunk subtitles, time-shifted to 0 -----------------------------
  $chunkStartCs = $chunk * $chunkCs
  $sb = New-Object System.Text.StringBuilder
  foreach ($h in $header) { [void]$sb.AppendLine($h) }
  foreach ($c in $cues) {
    $ns = $c.S - $chunkStartCs
    $ne = $c.E - $chunkStartCs
    if ($ne -le 0) { continue }
    if ($ns -gt $chunkCs) { continue }
    [void]$sb.AppendLine(('Dialogue: 0,{0},{1},Default,,0,0,0,,{2}' -f (ToAss $ns), (ToAss $ne), $c.Text))
  }
  [System.IO.File]::WriteAllText($assChunk, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

  # ---- 4. encode the chunk (subtitles burned in, silent) ---------------------
  $t0 = [Diagnostics.Stopwatch]::StartNew()
  Push-Location $Work   # so the subtitles filter can use a bare relative name
  try {
    & $Ffmpeg -hide_banner -v error -y -framerate 45 -start_number 1 `
      -i (Join-Path $tempOut '%08d.png') -frames:v $keep `
      -vf 'subtitles=sub_chunk.ass' `
      -c:v h264_nvenc -preset p5 -cq 23 -g 225 -pix_fmt yuv420p -an $partFile
    $rc = $LASTEXITCODE
  } finally { Pop-Location }
  if ($rc -ne 0) { throw "chunk $chunk : encode failed ($rc)" }
  $tEncode += $t0.Elapsed.TotalSeconds
  Move-Item -LiteralPath $partFile -Destination $chunkFile -Force

  $done++
  if (($done % 10) -eq 0 -or $done -le 3) {
    $el = $swAll.Elapsed.TotalSeconds
    $left = $last - $chunk
    $eta = if ($done -gt 0) { ($el / $done) * $left / 60.0 } else { 0 }
    $freeD = [math]::Round((Get-PSDrive D).Free / 1GB, 1)
    Log ('chunk {0}/{1} done  in={2} out={3} keep={4}  avg {5:N1}s/chunk  ETA {6:N0} min  D free {7} GB' -f `
         $chunk, $last, $nIn, $nOut, $keep, ($el / $done), $eta, $freeD)
  }
}

Log ('LOOP DONE  chunks={0} skipped={1}  extract={2:N0}s rife={3:N0}s encode={4:N0}s total={5:N1}min' -f `
     $done, $skipped, $tExtract, $tRife, $tEncode, $swAll.Elapsed.TotalMinutes)

# ---- 5. concat + mux ---------------------------------------------------------
if ($FinalOut -ne '') {
  $files = @(Get-ChildItem -LiteralPath $chunksDir -Filter 'chunk_*.mp4' | Sort-Object Name)
  Log ('concat: {0} chunks (expected {1} for the full run)' -f $files.Count, $totalChunks)
  $list = Join-Path $chunksDir 'concat.txt'   # must sit next to the chunks: we run ffmpeg from there
  ($files | ForEach-Object { "file '" + $_.Name + "'" }) | Set-Content -LiteralPath $list -Encoding ASCII
  Push-Location $chunksDir
  try {
    & $Ffmpeg -hide_banner -v error -y -f concat -safe 0 -i 'concat.txt' -c copy (Join-Path $Work 'video45.mp4')
    if ($LASTEXITCODE -ne 0) { throw "concat failed ($LASTEXITCODE)" }
  } finally { Pop-Location }

  $muxArgs = @('-hide_banner','-v','error','-y','-i',(Join-Path $Work 'video45.mp4'))
  if ($AudioStart -gt 0) { $muxArgs += @('-ss', ("{0:F3}" -f $AudioStart)) }
  if ($MaxDuration -gt 0) { $muxArgs += @('-t', ("{0:F3}" -f $MaxDuration)) }
  $muxArgs += @('-i', $Stereo, '-map','0:v:0','-map','1:a:0','-c','copy','-movflags','+faststart',
                '-map_metadata','-1','-map_chapters','-1','-disposition:a:0','default', $FinalOut)
  & $Ffmpeg @muxArgs
  if ($LASTEXITCODE -ne 0) { throw "mux failed ($LASTEXITCODE)" }
  Log ('FINAL: ' + $FinalOut + '  ' + [math]::Round((Get-Item -LiteralPath $FinalOut).Length / 1GB, 2) + ' GB')
}
Log 'ALL DONE'
