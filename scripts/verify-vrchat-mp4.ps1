<#
.SYNOPSIS
    Verify that an MP4 meets VRChat playback requirements, and optionally check integrity.

.DESCRIPTION
    Checks container, video codec/profile/pixel format/parity/frame rate, audio codec
    and channel count, moov placement (faststart), and chapter artifacts. With
    -Integrity it also parses the video bitstream and fully decodes the audio. With
    -FrameAt it extracts frames and stacks them into one montage for visual review
    (use it to confirm burned-in subtitles).

    Works under Windows PowerShell 5.1 and PowerShell 7; the file is ASCII-only.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File verify-vrchat-mp4.ps1 -Path 'D:\out.mp4'

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File verify-vrchat-mp4.ps1 -Path 'D:\out.mp4' -Integrity -FrameAt 970.5,5019.5,7401 -OutDir D:\work

.NOTES
    Exit code 0 = every hard check passed, 1 = a hard check failed, 2 = could not run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [string]$Ffmpeg,
    [string]$Ffprobe,

    [switch]$Integrity,

    # Seconds; a comma-separated list works from the command line: -FrameAt 10,20.5
    [string[]]$FrameAt = @(),
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

function Resolve-FfTool {
    param([string]$Given, [string]$Name)

    if ($Given) {
        if (Test-Path -LiteralPath $Given) { return (Resolve-Path -LiteralPath $Given).Path }
        throw "$Name not found at: $Given"
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'),
        'C:\Program Files',
        'C:\'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -LiteralPath $root -Recurse -Depth 5 -Filter "$Name.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }

    throw "Could not find $Name.exe on PATH or in the usual install roots. Pass -Ffmpeg/-Ffprobe."
}

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Write-Error "Input not found: $Path"
    exit 2
}

$full = (Resolve-Path -LiteralPath $Path).Path
$checks = New-Object System.Collections.Generic.List[object]

# "-File" passes command-line arguments as literal strings, so parse the timestamps
# here rather than relying on PowerShell's array binding.
$frameTimes = @()
foreach ($entry in $FrameAt) {
    foreach ($piece in ($entry -split '[,;\s]+')) {
        if (-not $piece) { continue }
        $value = 0.0
        if ([double]::TryParse($piece, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            $frameTimes += $value
        }
        else {
            Write-Warning "Ignoring unparsable -FrameAt value: '$piece'"
        }
    }
}

function Add-Check {
    param([string]$Name, [string]$Result, [string]$Detail)
    $checks.Add([pscustomobject]@{ Check = $Name; Result = $Result; Detail = $Detail })
}

try {
    $ffprobePath = Resolve-FfTool -Given $Ffprobe -Name 'ffprobe'
    $needFfmpeg = $Integrity -or ($frameTimes.Count -gt 0)
    $ffmpegPath = if ($needFfmpeg) { Resolve-FfTool -Given $Ffmpeg -Name 'ffmpeg' } else { $null }

    $rawJson = & $ffprobePath -v error -show_format -show_streams -show_chapters -of json $full | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $rawJson.Trim()) {
        Write-Error "ffprobe could not read: $full"
        exit 2
    }
    $probe = $rawJson | ConvertFrom-Json
}
catch {
    Write-Error $_.Exception.Message
    exit 2
}

$video = $probe.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
$audio = $probe.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1

# --- container -------------------------------------------------------------
$containerNames = @($probe.format.format_name -split ',')
$containerOk = @($containerNames | Where-Object { $_ -in @('mov', 'mp4', 'm4a', '3gp', '3g2', 'mj2') }).Count -gt 0
Add-Check -Name 'Container MP4/MOV' -Result $(if ($containerOk) { 'PASS' } else { 'FAIL' }) -Detail ($containerNames -join ',')

# --- video -----------------------------------------------------------------
if (-not $video) {
    Add-Check -Name 'Video stream present' -Result 'FAIL' -Detail 'no video stream found'
}
else {
    $isH264 = $video.codec_name -eq 'h264'
    Add-Check -Name 'Video codec H.264' -Result $(if ($isH264) { 'PASS' } else { 'FAIL' }) `
        -Detail "$($video.codec_name) $(if ($video.profile) { $video.profile }) $(if ($video.level) { "L$($video.level)" })"

    $is420 = $video.pix_fmt -eq 'yuv420p'
    Add-Check -Name 'Pixel format yuv420p (8-bit 4:2:0)' -Result $(if ($is420) { 'PASS' } else { 'FAIL' }) -Detail "$($video.pix_fmt)"

    $evenDims = (($video.width % 2) -eq 0) -and (($video.height % 2) -eq 0)
    Add-Check -Name 'Even dimensions' -Result $(if ($evenDims) { 'PASS' } else { 'FAIL' }) -Detail "$($video.width)x$($video.height)"

    $fps = 0.0
    if ($video.r_frame_rate -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) {
        $fps = [double]$Matches[1] / [double]$Matches[2]
    }
    elseif ($video.avg_frame_rate -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) {
        $fps = [double]$Matches[1] / [double]$Matches[2]
    }
    Add-Check -Name 'Frame rate >= 24 fps' -Result $(if ($fps -ge 24) { 'PASS' } else { 'WARN' }) -Detail ("{0:N3} fps" -f $fps)
}

# --- audio -----------------------------------------------------------------
if (-not $audio) {
    Add-Check -Name 'Audio codec AAC-LC' -Result 'WARN' -Detail 'no audio stream'
}
else {
    $audioCodec = $audio.codec_name
    if ($audioCodec -eq 'aac') {
        Add-Check -Name 'Audio codec AAC-LC' -Result 'PASS' -Detail "aac $(if ($audio.profile) { $audio.profile })"
    }
    elseif ($audioCodec -eq 'mp3') {
        Add-Check -Name 'Audio codec AAC-LC' -Result 'WARN' -Detail 'mp3: works on PC, not in iOS video files'
    }
    else {
        Add-Check -Name 'Audio codec AAC-LC' -Result 'FAIL' -Detail "$audioCodec cannot be decoded by VRChat; transcode to AAC-LC"
    }

    $channels = 0
    if ($audio.channels) { $channels = [int]$audio.channels }
    Add-Check -Name 'Channels <= 6 (no 7.1 AAC)' -Result $(if ($channels -le 6) { 'PASS' } else { 'FAIL' }) `
        -Detail "$channels channels $(if ($audio.channel_layout) { "($($audio.channel_layout))" })"
}

# --- layout ----------------------------------------------------------------
try {
    $stream = [System.IO.File]::OpenRead($full)
    try {
        $buffer = New-Object byte[] (8388608)
        $read = $stream.Read($buffer, 0, $buffer.Length)
    }
    finally { $stream.Close() }

    $text = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
    $moovAt = $text.IndexOf('moov')
    $mdatAt = $text.IndexOf('mdat')
    $faststartOk = ($moovAt -ge 0) -and (($mdatAt -lt 0) -or ($moovAt -lt $mdatAt))

    Add-Check -Name 'moov at front (faststart)' -Result $(if ($faststartOk) { 'PASS' } else { 'FAIL' }) -Detail "moov=$moovAt mdat=$mdatAt (first 8 MB)"

    if ($text.Contains('chap')) {
        Add-Check -Name 'No dangling chapter reference' -Result 'WARN' -Detail "'chap' box present in the first 8 MB"
    }
}
catch {
    Add-Check -Name 'moov at front (faststart)' -Result 'WARN' -Detail $_.Exception.Message
}

$chapterCount = @($probe.chapters | Where-Object { $_ }).Count
Add-Check -Name 'Chapter track' -Result $(if ($chapterCount -eq 0) { 'PASS' } else { 'WARN' }) -Detail "$chapterCount chapter(s)"

# --- integrity -------------------------------------------------------------
if ($Integrity) {
    $videoLog = & $ffmpegPath -v error -i $full -map 0:v:0 -c copy -f null - 2>&1
    $videoOk = $LASTEXITCODE -eq 0
    Add-Check -Name 'Video bitstream parse' -Result $(if ($videoOk) { 'PASS' } else { 'FAIL' }) `
        -Detail $(if ($videoOk) { 'ffmpeg exit 0' } else { "ffmpeg exit $LASTEXITCODE : $(@($videoLog)[0])" })

    if ($audio) {
        $audioLog = & $ffmpegPath -v error -i $full -map 0:a:0 -f null - 2>&1
        $audioOk = $LASTEXITCODE -eq 0
        Add-Check -Name 'Audio full decode' -Result $(if ($audioOk) { 'PASS' } else { 'FAIL' }) `
            -Detail $(if ($audioOk) { 'ffmpeg exit 0' } else { "ffmpeg exit $LASTEXITCODE : $(@($audioLog)[0])" })
    }
}

# --- frames ----------------------------------------------------------------
$montagePath = $null
if ($frameTimes.Count -gt 0) {
    if (-not $OutDir) { $OutDir = $env:TEMP }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

    $pngs = @()
    for ($i = 0; $i -lt $frameTimes.Count; $i++) {
        $png = Join-Path $OutDir ("vrchatcheck_frame{0}.png" -f $i)
        & $ffmpegPath -v error -y -ss $frameTimes[$i] -i $full -frames:v 1 $png
        if (Test-Path -LiteralPath $png) { $pngs += $png }
    }

    if ($pngs.Count -gt 0) {
        $inputArgs = @()
        foreach ($png in $pngs) { $inputArgs += @('-i', $png) }

        $parts = @()
        $labels = @()
        for ($k = 0; $k -lt $pngs.Count; $k++) {
            $parts += "[$k`:v]scale=960:-1[s$k]"
            $labels += "[s$k]"
        }
        $filter = ($parts -join ';') + ';' + ($labels -join '') + "vstack=inputs=$($pngs.Count)"

        $montagePath = Join-Path $OutDir 'vrchatcheck_montage.png'
        & $ffmpegPath -v error -y @inputArgs -filter_complex $filter $montagePath
        if (-not (Test-Path -LiteralPath $montagePath)) { $montagePath = $null }
    }
}

# --- report ----------------------------------------------------------------
$duration = 0.0
if ($probe.format.duration) { $duration = [double]$probe.format.duration }
$sizeGiB = 0.0
if ($probe.format.size) { $sizeGiB = [double]$probe.format.size / 1GB }

Write-Host ''
Write-Host ("File      : {0}" -f $full)
Write-Host ("Duration  : {0:N3} s ({1:hh\:mm\:ss})" -f $duration, [TimeSpan]::FromSeconds($duration))
Write-Host ("Size      : {0:N2} GiB" -f $sizeGiB)
if ($video) { Write-Host ("Video     : {0} {1} {2}x{3} {4}" -f $video.codec_name, $video.pix_fmt, $video.width, $video.height, $video.r_frame_rate) }
if ($audio) { Write-Host ("Audio     : {0} {1} ch {2} Hz" -f $audio.codec_name, $audio.channels, $audio.sample_rate) }
Write-Host ''

$checks | Format-Table -AutoSize -Wrap

if ($montagePath) { Write-Host "Montage   : $montagePath" }

$failures = @($checks | Where-Object { $_.Result -eq 'FAIL' }).Count
$warnings = @($checks | Where-Object { $_.Result -eq 'WARN' }).Count

if ($failures -gt 0) {
    Write-Host "FAIL: $failures hard check(s) failed, $warnings warning(s)."
    exit 1
}

Write-Host "PASS: meets VRChat playback requirements ($warnings warning(s))."
exit 0
