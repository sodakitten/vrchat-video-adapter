<#
.SYNOPSIS
    Ask this machine's Media Foundation whether it can decode a media file's audio.

.DESCRIPTION
    VRChat on PC decodes through AVPro Video -> Windows Media Foundation, so it can
    only play audio the operating system itself can decode. A result of
    CanTranscode = False means VRChat will play that file silently (VLC/mpv may
    still play it, because they bundle their own decoders).

    Run with Windows PowerShell 5.1 (powershell.exe), NOT PowerShell 7: WinRT
    projection is unavailable in PowerShell 7.

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File probe-wmf-audio.ps1 -Path <file> [<file>...]

    Keep this file ASCII-only. Windows PowerShell 5.1 reads BOM-less script files
    as ANSI, so non-ASCII text here would be mangled; pass non-ASCII paths as
    arguments instead.

.OUTPUTS
    One row per input: File, CanTranscode, FailureReason, Verdict.

.NOTES
    Exit code 0 = every input decodable, 1 = at least one is not, 2 = could not run.
    A True verdict covers the Windows path only; Quest/iOS still follow the
    documented VRChat/AVPro codec table.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Path,

    [string]$WorkDir = $env:TEMP
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Error 'Run this with Windows PowerShell 5.1: powershell.exe -NoProfile -ExecutionPolicy Bypass -File probe-wmf-audio.ps1 -Path <file>. WinRT projection is unavailable in PowerShell 7.'
    exit 2
}

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime | Out-Null
    [void][Windows.Foundation.AsyncStatus, Windows.Foundation, ContentType = WindowsRuntime]
    [void][Windows.Media.Transcoding.MediaTranscoder, Windows.Media.Transcoding, ContentType = WindowsRuntime]
    [void][Windows.Media.Transcoding.PrepareTranscodeResult, Windows.Media.Transcoding, ContentType = WindowsRuntime]
    [void][Windows.Media.MediaProperties.MediaEncodingProfile, Windows.Media.MediaProperties, ContentType = WindowsRuntime]
    [void][Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
    [void][Windows.Storage.StorageFolder, Windows.Storage, ContentType = WindowsRuntime]
    [void][Windows.Storage.CreationCollisionOption, Windows.Storage, ContentType = WindowsRuntime]
}
catch {
    Write-Error "Could not load the WinRT projection: $($_.Exception.Message)"
    exit 2
}

# Awaiting a WinRT IAsyncOperation<T> from PowerShell needs the generic AsTask helper.
$asTaskOperation = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and
        $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

if (-not $asTaskOperation) {
    Write-Error 'System.WindowsRuntimeSystemExtensions.AsTask was not found; cannot await WinRT operations.'
    exit 2
}

function Wait-AsyncOperation($operation, $resultType) {
    $task = $asTaskOperation.MakeGenericMethod($resultType).Invoke($null, @($operation))
    $task.Wait(-1) | Out-Null
    , $task.Result
}

try {
    $transcoder = [Windows.Media.Transcoding.MediaTranscoder]::new()

    # Newer Windows SDKs expose PrepareFileTranscodeAsync; older ones PrepareTranscodeAsync.
    $prepareMethodName = @('PrepareFileTranscodeAsync', 'PrepareTranscodeAsync') |
        Where-Object { $transcoder.PSObject.Methods.Name -contains $_ } |
        Select-Object -First 1
    if (-not $prepareMethodName) {
        Write-Error 'MediaTranscoder exposes no PrepareFileTranscodeAsync/PrepareTranscodeAsync method on this system.'
        exit 2
    }

    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    }
    $workRoot = (Resolve-Path -LiteralPath $WorkDir).Path
    $folder = Wait-AsyncOperation ([Windows.Storage.StorageFolder]::GetFolderFromPathAsync($workRoot)) ([Windows.Storage.StorageFolder])
    $audioProfile = [Windows.Media.MediaProperties.MediaEncodingProfile]::CreateM4a([Windows.Media.MediaProperties.AudioEncodingQuality]::High)
}
catch {
    Write-Error "Could not initialise Media Foundation: $($_.Exception.Message)"
    exit 2
}

$undecodable = 0
$rows = @()
$probeIndex = 0

foreach ($item in $Path) {
    $probeIndex++
    $full = try { (Resolve-Path -LiteralPath $item -ErrorAction Stop).Path } catch { $null }

    $canTranscode = $null
    $reason = ''
    $verdict = 'ERROR'

    if (-not $full -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        $reason = "file not found: $item"
        $rows += [pscustomobject]@{ File = "$item"; CanTranscode = $null; FailureReason = $reason; Verdict = 'ERROR' }
        continue
    }

    # Scratch output: plain ASCII name, unique per input.
    $scratchName = "wmfprobe_$probeIndex.m4a"
    $scratchPath = Join-Path $workRoot $scratchName

    try {
        $file = Wait-AsyncOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
        $scratch = Wait-AsyncOperation ($folder.CreateFileAsync($scratchName, [Windows.Storage.CreationCollisionOption]::ReplaceExisting)) ([Windows.Storage.StorageFile])
        $result = Wait-AsyncOperation ($transcoder.$prepareMethodName($file, $scratch, $audioProfile)) ([Windows.Media.Transcoding.PrepareTranscodeResult])

        $canTranscode = [bool]$result.CanTranscode
        $reason = [string]$result.FailureReason
        if ($canTranscode) {
            $verdict = 'DECODABLE'
        }
        else {
            $verdict = 'NOT DECODABLE'
            $undecodable++
        }
    }
    catch {
        $reason = $_.Exception.Message
        $verdict = 'ERROR'
    }
    finally {
        Remove-Item -LiteralPath $scratchPath -Force -ErrorAction SilentlyContinue
    }

    $rows += [pscustomobject]@{
        File          = $full
        CanTranscode  = $canTranscode
        FailureReason = $reason
        Verdict       = $verdict
    }
}

$rows | Format-Table -AutoSize -Wrap

if ($undecodable -gt 0) {
    Write-Host ''
    Write-Host "$undecodable file(s) cannot be decoded by Media Foundation: VRChat on PC plays them silently."
    Write-Host 'Transcode the audio to AAC-LC (ffmpeg -c:a aac -b:a 512k -ac 6 -ar 48000).'
    exit 1
}

$errors = @($rows | Where-Object { $_.Verdict -eq 'ERROR' }).Count
if ($errors -gt 0) {
    Write-Host ''
    Write-Host "$errors file(s) could not be probed."
    exit 2
}

Write-Host 'All inputs are decodable by Media Foundation (VRChat on PC will have audio).'
exit 0
