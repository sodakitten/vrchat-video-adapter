# burn-subs.ps1 -- burn one subtitle file into an already-interpolated master.
#
# Split out from run-interp.ps1 on purpose: interpolation is the expensive step
# (hours), burning subtitles is one NVENC pass (tens of minutes). Keeping a
# subtitle-free 45fps master means any later subtitle swap costs only a re-burn.
#
# ASCII only: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI (gb2312 here)
# and mangles non-ASCII literals, so every non-ASCII path arrives as a parameter.
param(
  [Parameter(Mandatory=$true)][string]$Master,     # subtitle-free 45fps master (video only)
  [Parameter(Mandatory=$true)][string]$SubAss,     # ASS covering the whole film timeline
  [Parameter(Mandatory=$true)][string]$Stereo,     # audio source (verified stereo AAC)
  [Parameter(Mandatory=$true)][string]$Out,
  [double]$AudioStart = 0,
  [double]$MaxDuration = 0,
  [string]$Ffmpeg = 'C:\Users\paulxstx\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0.1-full_build\bin\ffmpeg.exe'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Master)) { throw "master not found: $Master" }
if (-not (Test-Path -LiteralPath $SubAss)) { throw "subtitle not found: $SubAss" }

# Run ffmpeg from the subtitle's own directory so the filter can name it bare.
# (A relative filter path resolves against the process CWD, not the input's path.)
$work    = Split-Path -Parent $SubAss
$assName = Split-Path -Leaf   $SubAss

$a = @('-hide_banner','-v','error','-y','-i',$Master)
if ($AudioStart  -gt 0) { $a += @('-ss', ("{0:F3}" -f $AudioStart)) }   # input option: applies to the audio
if ($MaxDuration -gt 0) { $a += @('-t',  ("{0:F3}" -f $MaxDuration)) }
$a += @('-i',$Stereo,
        '-map','0:v:0','-map','1:a:0',
        '-vf',("subtitles=" + $assName),
        '-c:v','h264_nvenc','-preset','p5','-cq','23','-g','225','-pix_fmt','yuv420p',
        '-c:a','copy',
        '-movflags','+faststart','-map_metadata','-1','-map_chapters','-1',
        '-disposition:a:0','default',
        $Out)

Write-Host ('[' + (Get-Date).ToString('HH:mm:ss') + '] burn start: ' + (Split-Path -Leaf $SubAss) + ' -> ' + (Split-Path -Leaf $Out))
$sw = [Diagnostics.Stopwatch]::StartNew()
Push-Location $work
try {
  & $Ffmpeg @a
  $rc = $LASTEXITCODE
} finally { Pop-Location }
$sw.Stop()
if ($rc -ne 0) { throw "burn failed ($rc)" }
Write-Host ('[' + (Get-Date).ToString('HH:mm:ss') + '] burn done in {0:N1} min: {1}  {2} GB' -f `
  $sw.Elapsed.TotalMinutes, $Out, [math]::Round((Get-Item -LiteralPath $Out).Length / 1GB, 2))
