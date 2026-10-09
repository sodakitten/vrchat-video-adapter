# Proving that VRChat cannot decode a file's audio

The compatibility table is normative, but users reasonably answer "but it plays in VLC". VLC, mpv and ffplay ship their own decoders; VRChat does not — on PC it decodes through AVPro Video → Windows Media Foundation, so the OS's codecs are the ceiling. Two facts settle it, and the second one is machine-local:

1. **Documentation.** E-AC-3 does not appear in AVPro's supported-media list, and Microsoft removed the AC-3 codec from Windows 11 24H2 onward. See [vrchat-formats.md](vrchat-formats.md).
2. **A decode probe on the user's own machine**, using the same Media Foundation pipeline VRChat uses.

## The probe

`scripts/probe-wmf-audio.ps1` asks Media Foundation whether it can build a transcode that must decode the file's audio (`MediaTranscoder.PrepareFileTranscodeAsync` with an M4A/AAC profile) and reports `CanTranscode` and `FailureReason`.

- Run it with **Windows PowerShell 5.1** (`powershell.exe`), not `pwsh`: WinRT projection is unavailable in PowerShell 7.
- Keep the script file ASCII-only. Windows PowerShell 5.1 reads BOM-less files as ANSI, so a Chinese path written into the script becomes mojibake and the file "does not exist". Pass paths as arguments instead.
- `MediaTranscoder` method names drift: newer SDKs expose `PrepareFileTranscodeAsync`, older ones `PrepareTranscodeAsync`. The script picks whichever exists.
- Awaiting WinRT from PowerShell needs the `System.WindowsRuntimeSystemExtensions.AsTask` reflection helper; the helper's generic overload is selected by matching a single parameter of type `IAsyncOperation\`1`.

Interpretation:

| Result | Meaning |
|---|---|
| `CanTranscode = True` | The OS stack can decode this audio; VRChat on PC can play it. |
| `CanTranscode = False` | VRChat on PC will play the file silently, or may fail to load the track entirely. |

Caveats to state honestly: a `True` verdict is about the Windows path only — Quest/iOS still follow the table above. And VRChat's own player build could differ from the OS default stack, though it cannot exceed it.

## Worked example (RTX 5080 laptop, Windows 11 26H2, build 26300.9457)

Source: `1080p AMZN WEB-DL DDP5.1 H264-KyoGo.mkv` — H.264 High@L4.0, 1920x1080, `yuv420p`, 24 fps; audio **E-AC-3 5.1, 640 kbps**.

Machine findings:

- `C:\Windows\System32\DolbyDecMFT_redirect.dll` present (67 KB stub); the registered `Microsoft Dolby Digital Plus Decoder MFT` CLSID points at it.
- No Dolby Store package installed (`Get-AppxPackage | Where-Object Name -match 'Dolby'` returned nothing).
- The only E-AC-3-related MFT present is `Dolby AC-3 and E-AC-3 IEC-61937 converter MFT` — a bitstream passthrough, of no use for decoding to PCM.
- `msac3dec.dll` absent (consistent with AC-3 removal after 24H2).

Probe output on two 15-second MP4 samples cut from the same source, one with the audio copied and one transcoded:

| Sample | Audio | `CanTranscode` | `FailureReason` |
|---|---|---|---|
| `_test_vrc.mp4` (control) | AAC-LC 5.1 | **True** | None |
| `_test_eac3.mp4` | E-AC-3 5.1 (copied) | **False** | Unknown |

The control proves the probe itself works; the target proves the copied E-AC-3 track is silent in VRChat on this machine. The correct deliverable was therefore video stream-copied with audio re-encoded to AAC-LC 5.1.

Keep a short sample of the unplayable variant when a user wants to check for themselves — a 15-second clip is about 14 MB.
