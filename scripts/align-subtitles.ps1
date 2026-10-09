<#
align-subtitles.ps1 -- put a subtitle on the same timeline as the film.

A subtitle downloaded for "the same movie" is routinely cut for a different
release. The runtime difference is usually in the studio logos and the credits,
so the dialogue timings are often identical and only a constant shift (or a
frame-rate rescale) is needed. This script measures that correction and can
apply it.

  # measure only: report the offset/scale this candidate needs
  .\align-subtitles.ps1 -Candidate new.srt -Reference in-sync.srt

  # apply: write a corrected SRT
  .\align-subtitles.ps1 -Candidate new.srt -Reference in-sync.srt -Apply

  # apply and also emit a burnable 1080p ASS
  .\align-subtitles.ps1 -Candidate new.srt -Reference in-sync.srt -Apply -MakeAss

  # only convert to ASS with a 1080p CJK style (no re-timing)
  .\align-subtitles.ps1 -Candidate new.srt -Reference in-sync.srt -MakeAss

Reference: any subtitle already known to be in sync with the film. The track
embedded in the release is ideal -- extract it with
`ffmpeg -i film.mkv -map 0:s:0 ref.srt`.

ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI
(gb2312 on a Chinese system) and mangles non-ASCII literals, so every path
arrives as a parameter.
#>
param(
  [Parameter(Mandatory=$true)][string]$Candidate,
  [Parameter(Mandatory=$true)][string]$Reference,
  [string]$OutSrt = '',
  [string]$OutAss = '',
  [int]$WindowMs = 3000,
  [int]$OutlierMs = 400,
  [double]$ManualShiftMs = 0,
  [switch]$Apply,
  [switch]$MakeAss,
  [string]$Style = 'Default,Microsoft YaHei,56,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,2,10,10,45,1',
  [string]$Ffmpeg = 'ffmpeg'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Candidate)) { throw "candidate not found: $Candidate" }
if (-not (Test-Path -LiteralPath $Reference)) { throw "reference not found: $Reference" }

# ---------------------------------------------------------------------------
# parsing
# ---------------------------------------------------------------------------
function Read-Text([string]$path) {
  $bytes = [System.IO.File]::ReadAllBytes($path)
  $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
  if ($txt.Length -gt 0 -and $txt[0] -eq [char]0xFEFF) { $txt = $txt.Substring(1) }
  # A file that is not UTF-8 usually shows up as almost no CJK after decoding.
  $cjk = ([regex]::Matches($txt, '[\u4e00-\u9fff]')).Count
  if ($cjk -lt 20) {
    $gb = [System.Text.Encoding]::GetEncoding(936).GetString($bytes)
    if (([regex]::Matches($gb, '[\u4e00-\u9fff]')).Count -gt $cjk) { $txt = $gb }
  }
  return $txt
}

function Get-Cues([string]$path) {
  $txt = Read-Text $path
  $cues = New-Object System.Collections.ArrayList
  foreach ($block in ($txt -split "(\r?\n){2,}")) {
    if ($block -match '(?m)^\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})') {
      $s = ((([int]$Matches[1] * 3600) + ([int]$Matches[2] * 60) + [int]$Matches[3]) * 1000) + [int]$Matches[4]
      $e = ((([int]$Matches[5] * 3600) + ([int]$Matches[6] * 60) + [int]$Matches[7]) * 1000) + [int]$Matches[8]
      $lines = @(($block -split "`r?`n") | Select-Object -Skip 1 | Where-Object { $_ -notmatch '-->' -and $_.Trim() -ne '' })
      if ($lines.Count -gt 0) {
        [void]$cues.Add([pscustomobject]@{ S = $s; E = $e; Lines = $lines })
      }
    }
  }
  return ,$cues
}

# NOTE: [int] in PowerShell ROUNDS (13.688 -> 14), it does not truncate.
# Splitting a timestamp with [int]($ms / 60000) therefore turns 13 minutes into
# 14 minutes, i.e. +60 s, silently. Always floor explicitly.
function Format-Srt([int]$ms) {
  if ($ms -lt 0) { $ms = 0 }
  $t = [timespan]::FromMilliseconds($ms)
  return ('{0:00}:{1:00}:{2:00},{3:000}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds, $t.Milliseconds)
}

function Format-AssTime([int]$ms) {
  if ($ms -lt 0) { $ms = 0 }
  $t = [timespan]::FromMilliseconds($ms)
  return ('{0}:{1:00}:{2:00}.{3:00}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds, [int][math]::Floor($t.Milliseconds / 10))
}

# ---------------------------------------------------------------------------
# measure
# ---------------------------------------------------------------------------
$cand = Get-Cues $Candidate
$ref  = Get-Cues $Reference
Write-Host ('candidate: {0} cues, first {1}, last end {2}' -f $cand.Count, (Format-Srt $cand[0].S), (Format-Srt $cand[$cand.Count-1].E))
Write-Host ('reference: {0} cues, first {1}, last end {2}' -f $ref.Count, (Format-Srt $ref[0].S), (Format-Srt $ref[$ref.Count-1].E))

$refStarts = @($ref | ForEach-Object { $_.S })

# For every candidate cue, the nearest reference start within the window.
# Cue segmentation differs between translations, so the differences form a
# narrow peak rather than an exact match; the peak's centre is the offset.
$pairs = New-Object System.Collections.ArrayList
$near = 0
foreach ($c in $cand) {
  $best = $null; $bd = [int]::MaxValue
  foreach ($r in $refStarts) { $d = [math]::Abs($r - $c.S); if ($d -lt $bd) { $bd = $d; $best = $r } }
  if ($bd -le $WindowMs) { $near++; [void]$pairs.Add([pscustomobject]@{ X = [double]$c.S; Y = [double]$best }) }
}
if ($pairs.Count -lt 20) {
  Write-Host 'too few cues line up within the window -- probably a different cut, not a shifted one.'
  exit 2
}

$hist = @{}
foreach ($p in $pairs) { $k = [int]([math]::Round(($p.Y - $p.X) / 100) * 100); $hist[$k] = 1 + $(if ($hist[$k]) { $hist[$k] } else { 0 }) }
$top = $hist.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
Write-Host ''
Write-Host ('paired within {0} ms: {1} / {2}' -f $WindowMs, $near, $cand.Count)
Write-Host 'offset histogram (reference - candidate):'
$top | ForEach-Object { Write-Host ('    {0,7} ms : {1}' -f $_.Key, $_.Value) }
$peak = [double]$top[0].Key

function Fit-Line($pts) {
  $n = $pts.Count; $sx = 0.0; $sy = 0.0; $sxy = 0.0; $sxx = 0.0
  foreach ($p in $pts) { $sx += $p.X; $sy += $p.Y; $sxy += $p.X * $p.Y; $sxx += $p.X * $p.X }
  $den = ($n * $sxx) - ($sx * $sx)
  if ($den -eq 0) { return @(1.0, 0.0) }
  $a = (($n * $sxy) - ($sx * $sy)) / $den
  $b = ($sy - ($a * $sx)) / $n
  return @($a, $b)
}

$fit = Fit-Line $pairs
$keep = @($pairs | Where-Object { [math]::Abs($_.Y - (($fit[0] * $_.X) + $fit[1])) -le $OutlierMs })
if ($keep.Count -ge 20) { $fit = Fit-Line $keep } else { $keep = $pairs }
$res = @($keep | ForEach-Object { $_.Y - (($fit[0] * $_.X) + $fit[1]) })
$rms = [math]::Sqrt((($res | ForEach-Object { $_ * $_ } | Measure-Object -Sum).Sum) / $res.Count)
$maxr = ($res | ForEach-Object { [math]::Abs($_) } | Measure-Object -Maximum).Maximum
$effFps = if ($fit[0] -ne 0) { (1 / $fit[0]) * 24.0 } else { 24.0 }

Write-Host ''
Write-Host ('fitted correction: reference = {0:F8} * candidate + {1:F1} ms' -f $fit[0], $fit[1])
Write-Host ('    implied source rate: {0:F4} fps  (24.000 means no rescale needed)' -f $effFps)
Write-Host ('    residuals after fit: RMS {0:F0} ms, max {1:F0} ms, on {2} cues' -f $rms, $maxr, $res.Count)
Write-Host ''
if ([math]::Abs($fit[0] - 1) -lt 0.0002) {
  Write-Host '=> constant shift only: same dialogue timeline, different intro/credits.'
} else {
  Write-Host '=> scale + shift: the candidate was cut for a different frame rate.'
}
if ($rms -gt 400) { Write-Host '=> WARNING: large residuals; verify on a burned sample before trusting this.' }

if (-not $Apply -and -not $MakeAss) { exit 0 }

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
$shift = if ($ManualShiftMs -ne 0) { $ManualShiftMs } else { $fit[1] }
$scale = if ($ManualShiftMs -ne 0) { 1.0 } else { $fit[0] }

$outRows = New-Object System.Collections.ArrayList
foreach ($c in $cand) {
  $s = [int][math]::Round(($c.S * $scale) + $shift)
  $e = [int][math]::Round(($c.E * $scale) + $shift)
  if ($s -lt 0) { $s = 0 }
  if ($e -le $s) { $e = $s + 500 }
  [void]$outRows.Add([pscustomobject]@{ S = $s; E = $e; Lines = $c.Lines })
}

if ($OutSrt -eq '') {
  $dir = Split-Path -Parent $Candidate
  $base = [System.IO.Path]::GetFileNameWithoutExtension($Candidate)
  $OutSrt = Join-Path $dir ($base + '-aligned.srt')
}
$sb = New-Object System.Text.StringBuilder
$i = 0
foreach ($r in $outRows) {
  $i++
  [void]$sb.AppendLine([string]$i)
  [void]$sb.AppendLine((Format-Srt $r.S) + ' --> ' + (Format-Srt $r.E))
  foreach ($l in $r.Lines) { [void]$sb.AppendLine($l) }
  [void]$sb.AppendLine('')
}
[System.IO.File]::WriteAllText($OutSrt, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('wrote {0} cues -> {1}' -f $outRows.Count, $OutSrt)

if (-not $MakeAss) { exit 0 }

# ---------------------------------------------------------------------------
# ASS for burning: let ffmpeg do the conversion, then patch resolution + style
# ---------------------------------------------------------------------------
if ($OutAss -eq '') {
  $OutAss = [System.IO.Path]::ChangeExtension($OutSrt, '.ass')
}
if ($OutAss -eq $OutSrt) { throw 'OutAss must differ from OutSrt' }
$raw = [System.IO.Path]::ChangeExtension($OutAss, '.raw.ass')

& $Ffmpeg -hide_banner -v error -y -i $OutSrt $raw
if ($LASTEXITCODE -ne 0) { throw "ffmpeg could not convert the SRT ($LASTEXITCODE)" }

$al = [System.IO.File]::ReadAllText($raw, [System.Text.Encoding]::UTF8) -split "`r?`n"
$patched = 0
for ($k = 0; $k -lt $al.Count; $k++) {
  if ($al[$k] -match '^PlayResX:')  { $al[$k] = 'PlayResX: 1920'; $patched++ }
  elseif ($al[$k] -match '^PlayResY:') { $al[$k] = 'PlayResY: 1080'; $patched++ }
  elseif ($al[$k] -match '^Style:') { $al[$k] = 'Style: ' + $Style; $patched++ }
}
[System.IO.File]::WriteAllText($OutAss, ($al -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue

# Validate before anyone burns hours of video with it.
$dlg = @($al | Where-Object { $_ -like 'Dialogue:*' })
$bad = 0
foreach ($l in $dlg) {
  if ($l -match '^Dialogue: 0,\d+:(\d{2}):(\d{2})\.(\d{2})') {
    if ([int]$Matches[1] -ge 60 -or [int]$Matches[2] -ge 60) { $bad++ }
  }
}
Write-Host ('wrote {0} dialogue lines -> {1}  (patched {2} header lines, {3} out-of-range fields)' -f $dlg.Count, $OutAss, $patched, $bad)
if ($bad -gt 0) { Write-Host 'ABORT: a time field passed 60 -- the timestamps are wrong, do not burn this.'; exit 3 }
if ($dlg.Count -ne $outRows.Count) { Write-Host ('ABORT: {0} dialogue lines for {1} cues.' -f $dlg.Count, $outRows.Count); exit 3 }
