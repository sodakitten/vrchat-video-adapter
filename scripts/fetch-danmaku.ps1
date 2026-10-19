<#
  fetch-danmaku.ps1 - pull danmaku XML for a list of episodes from a running danmu_api server.

  Prerequisite: the danmu_api server (https://github.com/huangxd-/danmu_api) is running, e.g.
    node danmu_api/server.js            # serves http://127.0.0.1:9321
  Its config/.env matters: PROXY_URL when the sites are unreachable directly, SOURCE_ORDER must
  name the sites you want (the shipped default queries only douban,360,renren,hanjutv), and
  RATE_LIMIT_MAX_REQUESTS defaults to 3 per minute -> 429. See
  references/danmaku-sourcing.md for the whole setup plus the measured source status.
  The server answers only after its start-up preload finishes (minutes on a slow proxy): poll it
  before blaming the script.

  Why search and fetch in ONE loop: the episodeId danmu_api returns is session-scoped (built by
  the search and held in the server's cache), so an id reused after a .env reload resolves to
  nothing and is reported exactly like a title with no danmaku: {"count":0,"comments":[]}.

  THIS FILE MUST STAY PURE ASCII. Windows PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI,
  and a stray CJK character in a comment can silently swallow the declaration on the next line
  (observed: the $Episodes parameter simply vanished, with no parse error) - the same trap as a
  non-ASCII path in this session's history. Pass the CJK keyword as an ARGUMENT instead.

  Example:
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File fetch-danmaku.ps1 `
        -Anime <keyword> -Episodes 21,22,23,24 -OutDir D:\DSH\danmaku\dandan
#>
param(
  [Parameter(Mandatory=$true)][string]$Anime,          # search keyword: the show's CN/JP title
  [Parameter(Mandatory=$true)][int[]]$Episodes,
  [string]$OutDir = 'D:\DSH\danmaku\dandan',
  [string]$Base   = 'http://127.0.0.1:9321',
  [string]$Source = 'dandan',                          # which site's entry to prefer
  [string]$Prefix = 'ep',
  [int]$SearchTimeout  = 90,
  [int]$CommentTimeout = 300
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

# Build "episode <N>" (U+7B2C U+8BDD) from code points: no CJK literal in this file.
$epPre  = [string][char]0x7B2C
$epWord = [string][char]0x8BDD
$kw = [uri]::EscapeDataString($Anime)

foreach ($ep in $Episodes) {
  $tag = Join-Path $env:TEMP ("dm-search-$ep.json")
  if (Test-Path -LiteralPath $tag) { Remove-Item -LiteralPath $tag -Force }
  & curl.exe -s --max-time $SearchTimeout -o $tag "$Base/api/v2/search/episodes?anime=$kw&episode=$ep" | Out-Null

  $o = $null
  if (Test-Path -LiteralPath $tag) {
    try { $o = Get-Content -LiteralPath $tag -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
  }
  if (-not $o) { Write-Host "[ep$ep] search failed (server down or still preloading)"; continue }

  $a = @($o.animes) | Where-Object { "$($_.animeTitle)" -like "*from $Source*" } | Select-Object -First 1
  if (-not $a) { Write-Host "[ep$ep] no '$Source' entry among $(@($o.animes).Count) search results"; continue }

  $want = $epPre + ([string]$ep) + $epWord
  $e = @($a.episodes) | Where-Object { "$($_.episodeTitle)" -like "*$want*" } | Select-Object -First 1
  if (-not $e) { $e = @($a.episodes) | Select-Object -First $ep }   # fall back to position
  if (-not $e) { Write-Host "[ep$ep] entry has no episodes"; continue }

  $id   = $e.episodeId
  $dest = Join-Path $OutDir ("{0}{1}.xml" -f $Prefix, $ep)
  & curl.exe -s --max-time $CommentTimeout -o $dest "$Base/api/v2/comment/$id" | Out-Null

  $size = 0; $n = 0
  if (Test-Path -LiteralPath $dest) {
    $size = (Get-Item -LiteralPath $dest).Length
    $n = ([regex]::Matches((Get-Content -LiteralPath $dest -Raw -Encoding UTF8), '<d p=')).Count
  }
  $title = "$($e.episodeTitle)"
  Write-Host ("[ep{0}] id={1} {2} bytes  {3} danmaku  '{4}'  -> {5}" -f $ep, $id, $size, $n, $title, $dest)
  if ($n -eq 0) {
    Write-Host "        count 0 means either a stale episodeId or an empty source - check the server log"
  }
}

Write-Host ''
Write-Host 'Next: convert for playback, or burn it in.'
Write-Host '  DanmakuFactory -i ep21.xml -o ep21.ass ; mpv --sub-file=ep21.ass video.mp4'
Write-Host '  burn: add ass=ep21.ass to the filter chain (same canvas/CWD rules as any ASS)'
