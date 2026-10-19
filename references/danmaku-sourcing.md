# Danmaku (弹幕) sources and alignment

VRChat cannot render a subtitle sidecar — AVPro shows only what is burned into the picture. So
danmaku are either **burned in** (a full re-encode; get consent) or handed over as a sidecar that
only local players can use (`mpv --sub-file=`, PotPlayer, DanmakuFactory → ASS). Decide which
before converting anything.

## The source that works: dandanplay (弹弹play)

dandanplay keeps an **archive** of danmaku keyed to a bangumi episode, and it still holds the
2014–2015 Bilibili comments for shows Bilibili itself has since **delisted** — measured on
寄生獣 セイの格率 episodes 21–24 (removed from Bilibili in the 2015 blacklist): **2,200 / 2,794 /
2,417 / 2,069** danmaku, against **135 / 51 / 84 / 105** from Tucao and **nothing** anywhere else.

Its own API needs an AppId + signature (a plain call to `api.dandanplay.net` answers 403), so do
not fight it — run the open-source **danmu_api** server, which relays dandanplay (and many other
sites) and speaks the same protocol:

```powershell
$dir='D:\DSH\danmaku\src\danmu_api-main'      # any ASCII path
curl.exe -L -o danmu.zip https://codeload.github.com/huangxd-/danmu_api/zip/refs/heads/main
Expand-Archive danmu.zip -DestinationPath .   # -> danmu_api-main\
Set-Location "$dir"
npm install --no-audit --no-fund              # 43 packages; Node >= 18
# config/.env — the server watches this file and hot-reloads it
#   TOKEN=87654321
#   DANMU_API_PORT=9321
#   PROXY_URL=http://127.0.0.1:7897          # required when the sites are unreachable directly
#   SOURCE_ORDER=bilibili,dandan,animeko,tencent,iqiyi,youku,migu,douban,360,renren,hanjutv
#   USE_BANGUMI_DATA=true
#   DANMU_OUTPUT_FORMAT=xml                  # Bilibili 8-field XML
#   LOCAL_CACHE_ENABLED=true
#   STRICT_TITLE_MATCH=false
#   RATE_LIMIT_MAX_REQUESTS=0                # default is 3 per minute -> 429
#   LOG_LEVEL=warn
node danmu_api/server.js                      # -> 127.0.0.1:9321
```

`SOURCE_ORDER` must **name** every site you want: the shipped default is only
`douban,360,renren,hanjutv`, so 爱优腾芒哔咪 are never queried until you add them. `PROXY_URL` also
accepts per-site forms (`bilibili@http://…`, `bahamut@http://…`) to route one site through another
exit.

## The flow that works: search, then fetch — per episode

1. `GET http://127.0.0.1:9321/api/v2/search/episodes?anime=<urlencoded keyword>&episode=<N>`
   → `animes[]`, one entry per site; keep the one whose `animeTitle` ends in `from dandan`.
2. Take that episode's **`episodeId`** and immediately `GET /api/v2/comment/<episodeId>`.
3. Save, repeat for the next episode.

```powershell
$base='http://127.0.0.1:9321'
$kw=[uri]::EscapeDataString('寄生兽')
foreach($ep in 21..24){
  & curl.exe -s --max-time 300 -o "$wd\search$ep.json" "$base/api/v2/search/episodes?anime=$kw&episode=$ep" | Out-Null
  $o = Get-Content "$wd\search$ep.json" -Raw -Encoding UTF8 | ConvertFrom-Json
  $a = $o.animes | Where-Object { $_.animeTitle -like '*from dandan*' } | Select-Object -First 1
  $want = "第{0}话" -f $ep
  $e = $a.episodes | Where-Object { $_.episodeTitle -like "*$want*" } | Select-Object -First 1
  & curl.exe -s --max-time 300 -o "$wd\danmaku\ep$ep.xml" "$base/api/v2/comment/$($e.episodeId)" | Out-Null
}
```

### Traps, each of which cost a run

- **`episodeId` is session-scoped.** The id→`url` table is built by the search and lives in the
  server's cache; after a `.env` reload the old ids stop resolving and you get
  `[cache] No URL found for ID: NaN` / `Comment with ID NaN not found`, answered as
  `{"count":0,"comments":[]}`. Always search immediately before each fetch.
- **A wrong id looks exactly like "this show has no danmaku".** `{"count":0,"comments":[]}` is
  returned both for an unknown id and for an empty source — read the server log, do not conclude
  from the count.
- **The dandan `url` field is not a URL** (it is an opaque number such as `102720021`):
  `/api/v2/comment/102720021` → count 0, and `?url=102720021` →
  `{"errorCode":400,…,"errorMessage":"Invalid url format, must start with http or https"}`.
- **Rate limit**: `RATE_LIMIT_MAX_REQUESTS` defaults to 3 per minute per IP and otherwise answers
  429 `Too many requests, please try again later` (`danmu_api/worker.js:440-468,496-524`).
- **The dandan relay is slow**: it fetches through `api.danmaku.weeblify.app/ddp/v1?path=…` with a
  **10 s timeout and 2 attempts**; single episodes took 2 s, 12 s, 16 s and **245 s**. Pass a
  generous `--max-time` and retry — a timeout is not a failure.

## What does not work (measured, with the evidence)

- **Bilibili** — the licensed entry is gone: `search_type=media_bangumi` returns
  `numResults=0` and bangumi-data carries no `bilibili` site id for the show. Nothing to recover.
- **Bahamut (動畫瘋)** — not licensed for this title. The API is real and worth knowing:
  `api.gamer.com.tw/mobile_app/anime/v1/search.php?kw=<traditionalised keyword>` (UA must look like
  the app: `Anime/2.29.2 … Alamofire/5.6.4`) → `data.anime[].video_sn`;
  `anime/v1/video.php?videoSn=` → episodes; `anime/v1/danmu.php?geo=TW%2CHK&videoSn=` → comments as
  `sn`, `time` (1/10 s), `position` (0=scroll, 1=top, 2=bottom), `color`, `text`. But it returns 0
  items for every spelling of a show it does not carry — **run a positive control** (`kw=naruto`
  returns 14 items there, `/anime/v1/video.php?sn=` with bad params answers
  `目前無此動畫或動畫授權已到期！`).
- **Tencent** — `pbaccess.video.qq.com` search answers `{"ret":10401}` → no `vid` → the
  `dm.video.qq.com/barrage/base/<vid>` endpoint is unreachable. **iQiyi** — only the live-action
  film exists, so no `tvId` for `cmts.iqiyi.com/bullet/…`. **Youku / AcFun** — 二创 only.
- **Tucao** — `https://api.tucao.moe/index.php?m=mukio&c=index&a=get&playerID=<seriesId>-<part>-0`
  (part = episode − 1, 0-based) still answers, requires the proxy (direct TLS fails), and must use
  `api.` (`www.tucao.moe/play/…` returns a 548 B redirect). Sparse, but often the only thing there.
- **animeko** (also exposed by danmu_api) returned 7 comments for a delisted episode — not a
  substitute for dandan.

## Prove the danmaku match your picture

A danmaku file is nothing but timestamps, so a wrong assumption offsets every comment.

- **OP/ED anchors (the reliable one).** The ASS you are already burning names its own OP/ED cues
  (`OPCN`, `OPJP`, `EDCN`, `EDJP` styles). Take the first `Start` of each and look at the danmaku
  just after it. Here the ASS had OP at **21.19 s** and ED at **1285.29 s**, and the danmaku showed
  OP reactions and 空耳 lyrics (`不跳OP` 22.8 s, `阿姨的酱说不易` 23.9 s) and `ed` / `ed后正片`
  at 1288.0 s → **offset ≈ 0**. A 1–3 s lag is viewers typing, not drift.
- **Tail distribution.** Count danmaku past the video's duration: here 0.36 / 0.43 / 0.74 / 3.48 %
  (max 1378–1381 s against a 1371.04 s BD) — that is the tail of a merged TV-length version and it
  never renders. A *large* fraction past the end means the source is a different cut and needs an
  offset.
- **Text matching does not work.** Matching danmaku text against the fansub's own dialogue lines
  gave 1/2/1/0 hits over four episodes, because the danmaku quote a different translation. (The
  throwaway helper used was `D:\DSH\danmaku\match-align.py`.)

## Using the danmaku

```powershell
# sidecar for local players
DanmakuFactory -i ep21.xml -o ep21.ass      # or danmaku2ass
mpv --sub-file=ep21.ass video.mp4
# into a VRChat-bound file: convert to ASS and burn it with the subtitle chain
#   -vf "…,ass=ep21.ass …"   (same canvas rules and CWD rule as any other ASS)
```

Keep the raw XML: burning is one more encode, re-fetching is another network round trip.

**Re-fetching is not byte-stable** — compare content, not file MD5. Fetching episode 21 twice
returned files identical in size, count, times, colours and text, but every `dmid` (the 8th field)
differed (`96492521083` vs `98673609306`) because danmu_api synthesises ids for the merged comments.
A verifier that diffs the files by hash will call that a mismatch; compare the time/text/colour
tuples instead.
