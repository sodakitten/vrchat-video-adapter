# Sourcing burned-in subtitles (and rescuing bad ones)

## Why the track already inside the file is often machine-translated

Streaming WEB-DL releases frequently ship a Chinese track that is the platform's
*auto-translated* one. Symptoms: line breaks inside a clause (`但我提供的 / 很贵。`),
words rendered one-by-one instead of as an idiom (`所有武器都很热` for "All weapons hot",
where 准备开火 is meant), and the same English phrase translated two different ways in
adjacent cues. A 字幕组 release reads like a person wrote it. Compare half a dozen cues
in the middle of the film before deciding a track is good enough — the opening titles
often look fine because they are simple.

## Where to look

| source | scriptable | notes |
|---|---|---|
| SubHD `subhd.com` / `.me` / `.tv` / `.one` / `.tw` | detail pages yes, **download gated** | where the human 精修/校订 versions live |
| ASSRT 伪射手 `assrt.net` | **no** | TLS reset from this machine, `curl` and the local proxy alike |
| **OpenSubtitles legacy REST** | **yes, no API key** | `rest.opensubtitles.org/search/imdbid-<id>/sublanguageid-chi` |
| 字幕库 `zimuku.la` / `.pw` | no | SPA, renders client-side |
| `yifysubtitles.ch` | yes, keyed by IMDb id | wide coverage but often no Chinese |

Search engines find the film page fast — the IMDb id, the Chinese title and the year are
enough. SubHD's page states the runtime a subtitle was cut for; treat that as a hint
only (one said 2:11:55 while the film was 2:12:08, and the timings did not match either).

## OpenSubtitles without a key (the one that works)

```powershell
$r = Invoke-WebRequest -Uri 'https://rest.opensubtitles.org/search/imdbid-30825738/sublanguageid-chi' `
     -UseBasicParsing -Headers @{'User-Agent'='TemporaryUserAgent';'X-User-Agent'='TemporaryUserAgent'}
($r.Content | ConvertFrom-Json) | Select MovieReleaseName, SubFileName, SubDownloadLink, SubDownloadsCnt
```

`SubDownloadLink` serves a **gzipped** .srt. PowerShell has no gunzip cmdlet — use
`System.IO.Compression.GZipStream` and `CopyTo` to a `.srt`. This endpoint needs no
account, and it is the only one of the four that reliably yields a file.

## SubHD: how the download works, and where it stops

Detail page → button `.subtitle-prepare-download[data-sid]` →
`POST /api/sub/prepare-download {"sid":"<sid>"}` → `{"success":true,"url":"/down/<sid>"}` →
that landing page's JS calls `POST /api/sub/down {"sid":"<sid>"}` → `{success,pass,url}`.

A scripted client gets `{"success":false,"msg":"时间过长本临时页面已经失效","pass":false}`
about **0.6 s** after prepare — so it is not the timeout it claims. Mirrors, a proxy exit
IP, a real Chrome UA, the full `Sec-Fetch-*`/`Origin` header set, both call orders and
curl all behave identically. Treat it as a bot gate: give the user the detail-page link
and let them click 下载字幕文件 in a real browser, then take the file from them.

## Triage and retime a candidate

Never trust a claimed runtime. Histogram `known - candidate` for the nearest cue within a
few seconds, using a subtitle already known to be in sync (the embedded track is ideal):

- peak at 0 ms with flat residuals → same timeline; burn as-is;
- residuals that drift (e.g. −1.8 s early, +0.2 s late) → the candidate was cut for
  23.976 fps while the film is 24.000; scale by `24/23.976` and re-centre;
- no peak at all → a different cut; discard or retime by hand.

Also check the cue *count*: 860 (embedded) vs 776 vs 703 said immediately that the three
files were segmented differently, which matters when deciding whether a naive 1:1 pairing
is safe (it is not).

## Housekeeping before burning

- **Strip uploader ads.** Both files carried `厌倦了搜索字幕? / Ray即刻生成字幕: getray.app`,
  one cue spanning a full 60 s of screen time. Match on the tool's name and drop those cues.
- **Bilingual files.** Keep lines containing CJK for a Chinese-only cut; for the bilingual
  look, render the English smaller with an inline override: `中文\N{\fs40}English`.
- An ASS burned onto a finished master must cover the **whole** timeline; the per-chunk
  time-shifting trick exists only inside the chunked pipeline.

## Keep the expensive step and the cheap step apart

Interpolating takes hours; burning subtitles is one NVENC pass (measured **225 fps**, so
26 min for 2h12m at 1080p45). So build the 45fps master **without** subtitles, keep it, and
burn one variant at a time. A subtitle swap then costs minutes instead of a re-run, which
matters when the user is still shopping for a translation.

Two traps in a chunked `-NoSubs` pipeline: the concat must be guarded on the switch (not
only on the output name), and the mux must be skipped when no output name is given. Pass
no `-FinalOut` at all rather than `-FinalOut ''` — an empty string argument is silently
dropped by `powershell.exe -File`, and the parameter then reports "missing an argument".

## Timing arithmetic: never use `[int]` to truncate

**PowerShell's `[int]` cast ROUNDS, it does not truncate**: `[int]13.688` is `14`. Splitting
a timestamp into fields with `[int]($cs / 6000)` therefore turns 13.688 minutes into
14 minutes, i.e. **+60 seconds**, and `[int]($cs / 100)` turns 6.77 s into 7.77 s (**+1 s**).
Both mistakes are silent: the file still parses, the cues still render, they are simply at
the wrong time. Symptoms found in practice: a cue written as `1:14:60.51` (a field pushed
past its own base), a subtitle file whose last cue lands 55 minutes past the end of the film,
and roughly half the cues of a finished 45 fps render arriving exactly one second late.

Use `TimeSpan` for the arithmetic and floor explicit fields:

```powershell
$t = [timespan]::FromMilliseconds($ms)
'{0:00}:{1:00}:{2:00},{3:000}' -f [int][math]::Floor($t.TotalHours), $t.Minutes, $t.Seconds, $t.Milliseconds
```

Validate every generated subtitle file before burning it: the first and last cue must lie
inside the film's runtime, no minute or second field may reach 60, and the cue count must
equal the number of `-->` lines in the source.

Note also *where* this bites. Re-emitting per-chunk cue times (a 10 s chunk has local times
under 10 s) can only ever produce the +1 s error; generating a **whole-timeline** ASS from
raw milliseconds produces the full +60 s error. A single-pass burn that hands the finished
ASS straight to libass never re-emits anything, so it is immune — one more reason to keep
the subtitle-free master and burn per variant.
