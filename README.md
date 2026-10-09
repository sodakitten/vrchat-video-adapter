# vrchat-video-adapter · VRChat 视频适配工具包

把任意视频（MKV / WEB-DL / 蓝光原盘 / 录屏）做成 **VRChat 里真的能正常播放** 的 MP4：容器、编码、音轨一次处理到位；可选 **烧录字幕**、可选 **补帧到与头显刷新率匹配**。

> **为什么需要它**：VRChat 在 PC 端走 **AVPro Video → Windows Media Foundation**，用的是**操作系统的解码器**，自身不带任何编解码器。于是不支持的格式**不会报错，只会静默失败**——最常见的就是**有画面没声音**，以及在 Quest 上直接打不开。这个工具包解决的正是这类"玄学"。

---

## 一、VRChat 到底能播什么

|  | 安全 | 避免 |
|---|---|---|
| 容器 | MP4（`avc1` / `mp4a` 标签） | MKV、AVI、MOV（Quest 尤其） |
| 视频 | H.264 8bit 4:2:0（`yuv420p`）、宽高为偶数、≥24 fps、最高 High L5.1 | H.265/HEVC、10bit、4:4:4、奇数分辨率、低于 24 fps |
| 音频 | **AAC-LC**（最多 5.1）、PC 端可用 MP3 | **E-AC-3/DDP、AC-3、DTS、TrueHD——解不了**；FLAC/Vorbis/Opus 不可靠 |
| 结构 | `moov` 前置（`+faststart`），经 HTTP(S) 提供 | 本地 `file://` 路径 |
| 附带 | 无章节轨 | 章节轨（会写成悬空的 `tref/chap` 引用） |

播放环境：PC = AVPro Video → Windows Media Foundation；Quest = ExoPlayer。世界需开启 **Allow Untrusted URLs** 才能播 HTTP 链接，文件名建议用 ASCII。

---

## 二、四条主线

### 1. 无损转封装（首选，最快）

源视频已经是 VRChat 安全的 H.264 时，**只复制视频流**，秒级完成：

```bash
ffmpeg -i in.mkv -map 0:v:0 -map 0:a:0 -c:v copy -c:a aac -b:a 512k -ac 2 -ar 48000 \
  -movflags +faststart -map_metadata -1 -map_chapters -1 -disposition:a:0 default out.mp4
```

### 2. 音频是重灾区

E-AC-3（"DDP"）是绝大多数流媒体 WEB-DL 的默认音轨，**不在 AVPro 支持列表里**。Windows 11 24H2 起微软不再随系统提供 AC-3/E-AC-3 解码器（注册表里的 CLSID 只是指向商店包的存根，且有 field-of-use 限制）。

自证脚本（**必须用 Windows PowerShell 5.1**，pwsh 没有 WinRT 投影）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\probe-wmf-audio.ps1 -Path in.mp4
```

`CanTranscode = False` ⇒ VRChat 在 PC 上会**静音播放这个文件**。

**"在 VRChat 里人声很怪"** 不要凭感觉重编码。先逐声道对比源与产物（`-af "pan=mono|c0=cN,volumedetect"`）：若每个声道差都在 ~0.2 dB 内、中置同相、LFE 未错位，说明编码是忠实的，问题在**播放端的多声道处理**——Windows 会把 5.1 渲染成 2.0，Unity 后面还会再混一次。解法是给一条 **2.0 轨**（ITU-R BS.775 矩阵、丢弃 LFE），视频流 `-c:v copy` 复用，并用**视频流包 MD5** 证明画面没被重编码。

### 3. 字幕：找、对齐、烧

**先判断手上这条是不是机翻。** 平台自带的中字经常是自动翻译，症状很好认：

| 机翻 | 人译 |
|---|---|
| 所有武器都很热（All weapons hot） | **准备开火** |
| 我把它拿出来进行测试旋转（test spin） | 我试飞过 这次的翻修做得不错 |
| 我需要你绕过 / 排气限流器 | 上来 我要你关掉排气限制 |
| 但我提供的 / 很贵。 | 但我的保护费可不便宜 |

断句断在从句中间、成语逐字直译、同一句英文前后译法不一致——都是机翻特征。

**去哪里找**（按可脚本化程度）：

| 来源 | 可自动下载 | 说明 |
|---|---|---|
| SubHD（`subhd.com` / `.me` / `.tv` / `.one` / `.tw`） | 详情页可以，**下载被人机验证拦住** | 人工"精修/校订"版本大多在这里 |
| 射手网（伪）`assrt.net` | **不行** | 从本机 TLS 直接被重置，curl 和代理都一样 |
| **OpenSubtitles 旧版 REST** | **可以，且不需要 API key** | `rest.opensubtitles.org/search/imdbid-<id>/sublanguageid-chi` |
| 字幕库 `zimuku.la` / `.pw` | 不行 | SPA，客户端渲染 |
| `yifysubtitles.ch` | 可以，用 IMDb 号 | 覆盖面广但常常没有中文 |

```powershell
# OpenSubtitles：无需注册，SubDownloadLink 是 gzip 过的 srt
$r = Invoke-WebRequest -Uri 'https://rest.opensubtitles.org/search/imdbid-30825738/sublanguageid-chi' `
     -UseBasicParsing -Headers @{'User-Agent'='TemporaryUserAgent';'X-User-Agent'='TemporaryUserAgent'}
($r.Content | ConvertFrom-Json) | Select MovieReleaseName, SubFileName, SubDownloadLink, SubDownloadsCnt
```

还能按**文件哈希**查（`moviehash-<16位十六进制>`），能直接找到"专门为这个发行版做的"字幕：

```powershell
# OpenSubtitles 哈希 = 文件长度 + 首 64KB + 末 64KB 的 64 位小端累加，模 2^64
# 注意：PowerShell 的 [int] 会四舍五入，累加必须用 BigInteger 或显式取模
```

**别信"适配时长"标注。** 一份标注适配 2:11:55 的字幕，配上 2:12:08 的片源，实测只差一个 **+709 ms 的固定偏移**——那 13 秒差在片头台标和片尾字幕上，正片对白时刻是同一套。用 `scripts/align-subtitles.ps1` 量：

```powershell
# 拿片源内嵌的那条（绝对同步）当参考，量出候选字幕需要怎么修
ffmpeg -i film.mkv -map 0:s:0 ref.srt
.\scripts\align-subtitles.ps1 -Candidate 精修.srt -Reference ref.srt

#   paired within 3000 ms: 704 / 713
#   offset histogram:   700 ms : 145  800 ms : 138  900 ms : 82 ...
#   fitted: reference = 0.99999711 * candidate + 708.9 ms
#   implied source rate: 24.0001 fps   →  只是平移，不需要重采样
#   residuals: RMS 154 ms（来自两套字幕断句不同，不是错位）
```

三种结果对应三种处理：**峰值 0 ms 残差平坦** → 直接烧；**固定偏移** → 加常数；**残差随时间漂移** → 它按 23.976 做的而片源是 24.000，`×24/23.976` 再对齐。

**烧录**（一次 NVENC 单遍，1080p 45fps 全片约 19 分钟）：

```powershell
.\scripts\burn-subs.ps1 -Master master45-nosub.mp4 -SubAss 字幕.ass `
  -Stereo 谷谷-stereo-2.0.mp4 -Out final.mp4
```

中文样式（不设会渲染成豆腐块）：

```
PlayResX: 1920 / PlayResY: 1080
Style: Default,Microsoft YaHei,56,&H00FFFFFF,&H00FFFFFF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,0,2,10,10,45,1
```

中英双语时把英文行缩小一号：`中文\N{\fs40}English`。

### 4. 补帧：先看头显，别默认 60

**匹配刷新率，不是匹配"60 帧"这个数字**：

| 头显 | 24 fps | 30 fps | 45 fps | 60 fps |
|---|---|---|---|---|
| 72 Hz | 3 次刷新/帧 | 不均 | 不均 | 不均 |
| **90 Hz** | 4,4,4,3 循环（抖动） | **3 - 整除** | **2 - 整除** | 3:2 循环（抖动） |

90 Hz 下 45 fps 是最优点；60 fps 反而比 45 更差。1080p45 = 8160×45 = 367,200 MB/s，属 **Level 4.2**（L4.1 上限 245,760），仍在 VRChat 的 High L5.1 之内。

用 [rife-ncnn-vulkan](https://github.com/nihui/rife-ncnn-vulkan)（20221029 版，Windows zip 411 MB）。**实测在 RTX 5080 Laptop 上直接可用**，`fp16/int8/subgroup` 全部支持——网上"Blackwell 需要重编"的说法不成立。

**分块算术（已验证，不是猜的）**：序列模式是**均匀且端点锚定**的

```
out_j = in_(1 + (j-1) * (N_in - 1) / (N_out - 1))
```

证据：`N_in=241 → N_out=451` 时，输出第 1 帧与输入第 1 帧**像素完全相同**、输出第 451 帧与输入第 241 帧完全相同（解码成 raw RGB24 后 PSNR = `inf`），中间帧与相邻帧约 32 dB（确实在插值）。所以 24→45 取 `N_in = 8k+1`、`N_out = 15k+1`：**241 帧（正好 10.000 秒）→ 451 帧**，每块**只编码前 450 帧**（第 451 帧与下一块首帧重复），最后一块全保留。

实测速度（1080p，2h12m）：

| 阶段 | 速率 | 全片 |
|---|---|---|
| PNG 抽帧 | 121 fps | ~26 min |
| RIFE `-j 4:8:8` | 45 输出 fps | ~2.2 h |
| RIFE 默认 `-j 1:2:2` | 20 输出 fps | ~4.9 h |
| NVENC `p5 -cq 23` + libass | ~290 fps | ~19 min |
| **端到端** | **~15 s / 10 秒素材** | **193.5 min（793 块）** |

`-j 4:8:8` 比默认快 2.2 倍，先用它。`-x` 是空间 TTA，`-z` 是**时间 TTA**（不是"关掉 PNG 压缩"），都是变慢的选项，1080p 不用。

**体积法则：体积 = 码率 × 时长，跟帧数没有直接关系。** 同 `-cq` 下 24→45 fps 实测 **1.47 倍**（低复杂度窗口 1321 kbps 与高复杂度窗口 4484→6593 kbps 上一致）。2h12m 的 1080p24 → 45fps 落在 **5.77 GiB**，不是帧数比暗示的 1.9 倍。

**把贵的和便宜的拆开**：补帧是小时级，烧字幕是一次 NVENC 单遍（19 分钟）。所以先产出**无字幕的 45fps 母版并留着**，之后每换一版字幕只要重烧一遍。这次就是靠它把"换字幕"的成本从 3 小时降到 19 分钟。

---

## 三、实测数据（可复现的基准）

2h12m 1080p24（190,274 帧）→ 45 fps，烧字幕，复用立体声：

| | |
|---|---|
| 分块 | 793 块（每块 241→451 帧，尾块 194→363） |
| 耗时 | **193.5 分钟**（抽帧 36 min + RIFE 131 min + 编码 23 min） |
| 输出 | **356,763 帧** = 恰好 `792 × 450 + 363`，与源片长只差 1 帧 |
| 体积 | **5.77 GiB**；视频 5950 kbps = 24fps 版的 **1.48 倍** |
| 音频 | 包 MD5 与替换前**完全一致**（证明 `-c:a copy` 真的只是复制） |
| 接缝 | 每个边界检查 **0 重复帧**（有重复的话 PSNR 会是 `inf`） |
| 首/尾帧 | 与 24fps 版 PSNR `inf` / 92 dB |
| 整片解码 | 356,763 帧 + 音频，**0 错误** |

---

## 四、踩过的坑（这些是真正的成本）

**PowerShell 相关**

- **`[int]` 是四舍五入，不是截断**：`[int]13.688 = 14`。用 `[int]($ms/60000)` 拆时间戳会把 13 分钟变成 14 分钟 = **+60 秒**，而且**不报错**——文件照常解析、字幕照常显示，只是时间不对。症状：时间戳出现 `1:14:60.51` 这种越界字段、字幕文件末条跑到片尾之外 55 分钟、成片里约一半字幕晚 1.00 秒。**必须用 `[math]::Floor` 或 `TimeSpan`**，并在烧之前校验：首末条在片长内、分/秒字段无 60、条目数等于源文件 `-->` 行数。
- **`Get-CimInstance ... -like '*关键字*'` 会匹配到自己**：清理脚本里写了 `*burn-subs*` 去杀残留进程，结果把自己的命令行也匹配上并杀掉（exit code -1）。我这次连踩三次。过滤时务必排除 `$PID`，或只匹配 `ffmpeg.exe` 这类不可能是自己的进程名。
- **`Start-Process -ArgumentList` 接数组时不加引号**：带空格的路径会被劈开，尾巴绑到下一个参数上（`无法将值"AMZN"转换为类型"System.Int32"`）。要么传一个已加引号的字符串，要么写一个**零参数启动器 .ps1**（UTF-8 **带 BOM**）把路径写在里面。
- **`$ErrorActionPreference='Stop'` 下，原生命令往 stderr 写的任何一行都是终止性错误**：rife-ncnn-vulkan 只打印个 GPU banner 就被判"失败"。让 `cmd /c "... > log 2>&1"` 接管重定向。
- **空字符串参数会被 `powershell.exe -File` 丢掉**：`-FinalOut ''` 变成"缺少参数"。可选参数**不传**就好。
- **无 BOM 的 .ps1 被按 ANSI 读**（中文系统 gb2312）：非 ASCII 字面量变乱码 → "文件不存在"。辅助脚本保持纯 ASCII，非 ASCII 路径一律走参数传入。
- `$input` 是自动变量（`-i $input` 展开成空）；函数名撞上别名（`Measure`/`Select`/`Where`/`Sort`/`Group`）时函数根本不会执行；`2>&1` 在 5.1 里会把输出归属到**下一条**命令，请改用 `2> file` 再解析文件。

**ffmpeg 相关**

- ffmpeg 9 移除了 `-vsync`，要用 `-fps_mode passthrough|cfr|vfr`。
- `-map_metadata -1` 单独用会留下悬空的 `tref/chap` 章节引用，得加 `-map_chapters -1`（它同时会清掉章节标题）。
- **比较 PNG 之类的压缩文件用 MD5 不是像素比较**：不同编码器写相同像素会产出不同字节。要解码成 rawvideo 再哈希，或用 `psnr`/`ssim`。（这一条曾让我的端点锚定验证得出错误结论。）
- `-ss` 放在 `-i` 前面会重置输出时间戳，后面接 `subtitles` 滤镜就会显示错的字幕。做样本要么从头编码再截帧，要么加 `-copyts`。

**运维相关**

- **日志守望匹配"尾部若干行"会撞上上一轮的陈旧完成标记**：要只看**最后一行**。
- 长时间任务要 `Start-Process` 脱离会话，并且**重定向 stderr 到文件**，否则静默死掉时什么都看不到。

**给技能作者的**

- YAML frontmatter 的 `description` 里写 `冒号+空格`（`using ffmpeg: probe ...`）会让整个技能**从目录里消失**——无引号标量里的 `: ` 是语法错误。改回句号即可。
- SKILL.md 有约 8192 字符的截断阈值，超了尾部会被砍掉；细节放 `references/`，只在 SKILL.md 里留指针。

---

## 五、作为智能体技能使用

本仓库同时是一个 **Agent Skill**（见 `SKILL.md`）：把目录放到智能体的技能目录下，它就会在遇到"给 VRChat 转视频 / 烧字幕 / 补帧 / 音频没声音"时自动加载，并按 `references/` 里的证据去做。

```
SKILL.md                          ← 技能入口与判断表
references/vrchat-formats.md      ← 格式支持与出处
references/audio-decode-evidence.md      ← E-AC-3 解不了的实证
references/audio-fidelity-diagnostics.md ← "人声很怪"的诊断与 PowerShell 陷阱表
references/ffmpeg-recipes.md      ← 可直接复制的命令
references/frame-interpolation.md ← 分块算术、实测、坑
references/subtitle-sourcing.md   ← 找字幕、验轴、重定时、双语合成
scripts/probe-wmf-audio.ps1       ← 探测 WMF 能不能解这条音轨
scripts/verify-vrchat-mp4.ps1     ← 交付前的 9 项兼容性自检
scripts/interpolate-rife.ps1      ← 可续跑的分块补帧
scripts/burn-subs.ps1             ← 单遍烧字幕
scripts/align-subtitles.ps1       ← 量/修字幕时间轴并生成可烧录 ASS
```

---

## English quick start

Turn any video into an MP4 that **actually plays in VRChat** (PC: AVPro Video → Windows
Media Foundation, which uses *OS* codecs and fails silently; Quest: ExoPlayer).

```bash
# 1. safe container: H.264 yuv420p, even dims, >=24 fps, AAC-LC, moov first
ffmpeg -i in.mkv -c:v copy -c:a aac -b:a 512k -ac 2 -ar 48000 \
  -movflags +faststart -map_metadata -1 -map_chapters -1 out.mp4

# 2. is the audio even decodable? (Windows PowerShell 5.1, not pwsh)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\probe-wmf-audio.ps1 -Path in.mp4
#    CanTranscode = False  ->  VRChat plays it silently. Re-encode to AAC.

# 3. burned-in subtitles (one NVENC pass, ~19 min for 2h12m at 1080p45)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\burn-subs.ps1 `
  -Master master45-nosub.mp4 -SubAss subs.ass -Stereo audio.mp4 -Out final.mp4

# 4. frame interpolation: match the headset, not "60"
#    90 Hz -> 45 fps (even) ; 60 fps gives 3:2 judder
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\interpolate-rife.ps1 -Master in.mkv ...

# 5. verify before shipping
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-vrchat-mp4.ps1 -Path out.mp4
```

Everything here was measured on real files, not taken from documentation — including the
failures. See `references/` for the evidence, and section 四 for the traps that cost the
most time (the PowerShell `[int]` rounding bug that silently shifts subtitles by 60 seconds
is the one to read first).

## 授权

MIT（见 `LICENSE`）。脚本与文档可自由使用；字幕、影片本身的权利归各自权利人，请遵守当地法律，不要用本工具分发受版权保护的内容。
