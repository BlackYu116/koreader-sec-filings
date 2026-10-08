# secfilings.koplugin 修复结论

修复时间：2026-10-07（PDT）｜设备：Kindle Paperwhite 5（越狱）+ KOReader v2026.07.2

## 交付物

设备上 `/mnt/us/koreader/plugins/secfilings.koplugin/`（5 个文件，本地副本是
`sec_epub/secfilings.koplugin/main.lua` + `sec_epub/sec_{source,epub,job}.lua`）：

| 文件 | 大小 | 作用 |
| --- | --- | --- |
| `_meta.lua` | 435 B | 插件元数据（未改） |
| `main.lua` | 7476 B | 菜单外壳（薄） |
| `sec_source.lua` | 17260 B | 抓取 + 挑选 + 清理 HTML |
| `sec_epub.lua` | 7843 B | EPUB 打包 |
| `sec_job.lua` | 9396 B | **新增**：无 UI 的抓取→清理→打包编排 |

产物：`/mnt/us/documents/SEC 财报/<公司名> SEC 财报.epub` ×7，合计约 1.2 MB。

## 上一轮「失败 7 家、一个文件都没有」的原因（共 3 个原始 bug）

### Bug 1 — 循环变量 `_` 遮蔽 gettext（主因）

`main.lua` 顶部有 `local _ = require("gettext")`，而 `collectChapters` 里写了
`for _, f in ipairs(filings)`，于是循环体内的 `_()` 变成「调用一个数字」，
报 `attempt to call local '_' (a number value)`（crash.log 7 家公司各一条，全在 184 行）。

**修法**：所有循环变量改为显式名字，全项目再不允许出现 `for _, x` 这种写法。
涉及 9 处：`main.lua` 84/106/181、`sec_epub.lua` 78/120、`sec_source.lua` 106/121/132/210。
（其余 8 处当时循环体内没有调 `_()`，但一并改掉，避免同类坑复发。）

### Bug 2 — `pcall` 包住了会 yield 的代码

`Trapper:info()`（`frontend/ui/trapper.lua:125`）内部 `coroutine.yield()`。
LuaJIT 不允许跨 `pcall` 边界 yield。`doDownload` 里
`pcall(function() ... collectChapters ... end)` 一旦 Bug 1 修好，就会立刻变成
`attempt to yield across a C-call boundary`。

**修法**：`sec_job.lua` 里彻底不用 `pcall` 控制流程、不用 `error()` 跨层传播，
全部改成 `(结果, 错误说明)` 返回值；某一环失败只记一条说明并跳过那个单元。
`main.lua` 也绝不把 `SecJob.run` 包进 pcall。
例外只有 `json.decode` / `cre.getBalancedHTML` 这类不 yield 的纯 C 调用。

### Bug 3 — 长 `InfoMessage` 栈溢出（根因在 appearance.koplugin）

见 [`appearance-disabled-README.md`](appearance-disabled-README.md)。
一句话：`font_face.lua` 给 `InfoMessage:init` 打的包装每次进入都把字号重置回满值，
使原生 init 的「逐级缩小字号」收敛条件永远不成立 → 无限递归。
触发条件只是「消息高于屏幕 95%」，任何插件弹长消息都会中招，**不是调用方式问题**。

**处置**：
1. `appearance.koplugin` 整个移到 `/mnt/us/.context-backup/plugins-disabled/`（可逆）。
   已确认没有任何其他插件依赖它的模块。
2. 我的插件不再依赖 `InfoMessage` 作为唯一反馈：完整结果写 `logger.info`
   （即 `crash.log`），界面消息硬性限制最多显示 3 条失败原因。

## 重构：`sec_job.lua`

`SecJob.run(companies, opts, progress_cb) -> results, errors`，不 require 任何 `ui/*`。
`main.lua` 只剩菜单注册、设置读写、`NetworkMgr:runWhenOnline`、`Trapper:wrap`、
把 `progress_cb` 接到 `Trapper:info`、汇报结果。

这样纯逻辑可以脱开界面用设备自带 luajit 无头跑通 —— 这正是上一轮翻车的根因：
逻辑和界面糊在一起，只能靠手点菜单验证，点一次挂一次。

## 修复过程中新发现的 2 个缺陷（上一轮被 Bug 1 挡在后面，没暴露出来）

### 新缺陷 A — 嵌套 `<html>/<body>` + EDGAR 信封元数据混进正文

一部分 8-K exhibit 的 `.htm` 不是「单个文档」，而是「整份提交文件」的形态：

```
<document><type>EX-99.1 <sequence>2 <filename>exhibit991111111.htm <description>EX-99.1
<text><html><head><title>Document</title></head><body>…真正的正文…
```

原 `cleanHtml` 只剥了一层外壳，于是：
- 正文开头多出 `EX-99.1 2 exhibit991111111.htm EX-99.1 Document` 这类元数据垃圾；
- 里面那套 `<html><body>` 嵌进我们自己的 `<html><body>`，XHTML 不合法。

**修法**：整段 `<document>…<text>` 连值一起删、尾部闭合标签同样处理；
`<head>`/`<title>` 整块删；`<html>`/`<head>`/`<body>` 外壳标签本身也去掉
（标签名后必须紧跟 `>` 或空白，所以 `<header>` 不会被误删）。

### 新缺陷 B — 空元素没自闭合 / 无值属性（XHTML 硬要求）

1. `<br>` 是裸的（特斯拉 exhibit 里 12 个全没斜杠）→ `<br>` 会和后面的 `</font>` 配对，
   报 `mismatched tag`。
2. `<hr noshade/>`、`<td nowrap>` 这种 **HTML 无值属性** → XML 要求属性必须带值，
   严格解析器直接判 `not well-formed (invalid token)`。

**修法**：空元素统一自闭合；写一个真的属性小扫描器给无值属性补值
（`<hr noshade/>` → `<hr noshade="noshade"/>`）。
刻意没有用「属性名列表 + gsub」的做法，因为那会把
`style="a nowrap b"` 这种属性值里的词也误改 —— 已用单元测试确认不会。

### 这两处为什么必须放在 crengine 之后

实测发现一个重要陷阱：`cre.getBalancedHTML(s, 0x0)` 在**输入不含 `<html>/<body>`
时会「成功返回 nil」**（pcall 返回 true、结果是 nil）。原代码
`if ok2 and res then balanced = res end` 在这种情况下会静默退回未修补的原文。
一开始我把剥壳放在 cre 之前，正好把这个静默失败引出来了。
所以剥壳必须放在 cre 之后，判断条件也必须同时看 `res`。

## 已验证的取舍（都是有测量依据的，不是拍的）

| 项 | 决定 | 依据 |
| --- | --- | --- |
| `>%s+<` 折叠块间空白 | 保留 | 实测特斯拉 10-Q（1.57MB）里「行内闭合标签+空白+行内开标签」0 次、「行内闭合标签+空白+普通文本」0 次，不会粘连单词 |
| `max_doc_bytes` | 4MB → **12MB** | 微软 10-K 8.6MB：取回 4s、清理 57s、打包 1s、峰值内存 115MB，实测跑通。4MB 会把用户的年报直接跳过 |
| `<img>` 标签 | 整个删掉 | 插件不下载图片，留着就是指向不存在文件的死引用。删除数量会写进章节说明告知读者 |
| 「只下 8-K」 | 先过滤再截断 | 原来先截断再过滤，名额会被中间的 10-Q 占掉，实际拿不到 N 份 8-K |
| 边车目录路径 | `xxx.epub.sdr`（带扩展名） | 设备上实测 KOReader v2026.07.2 用的是带扩展名的写法；而且边车是目录，`os.remove` 删不掉，必须用 `ffiutil.purgeDir`。旧代码那行其实一直无效 |

## 设备当前产物（全部通过严格校验）

| 公司 | epub | content.html | 章节 | 正文合计 | 含 |
| --- | --- | --- | --- | --- | --- |
| Meta | 302.0 KB | 3056 KB | 5 | 813,970 字符 | 2×10-Q |
| 微软 | 277.4 KB | 8385 KB | 5 | 373,130 字符 | 1×10-K |
| 谷歌 | 141.4 KB | 2318 KB | 5 | 254,352 字符 | 1×10-Q |
| 亚马逊 | 133.2 KB | 1907 KB | 5 | 246,616 字符 | 1×10-Q |
| 苹果 | 112.4 KB | 1880 KB | 5 | 189,662 字符 | 2×10-Q |
| 特斯拉 | 92.2 KB | 1268 KB | 5 | 177,500 字符 | 1×10-Q |
| 英伟达 | 86.5 KB | 1233 KB | 5 | 172,051 字符 | 1×10-Q |

校验项：zip 合法 + CRC 通过；`mimetype` 是第一个条目且 STORED 未压缩；
`container.xml`/`content.opf`/`toc.ncx`/`content.html` 四个 XML 全部
`ElementTree.fromstring` 良构；`content.html` 里 `<html>`/`<body>` 各只出现 1 次；
`toc.ncx` 锚点与 `<h1 id>` 一一对应且顺序一致；每段正文 ≥ 400 字符；
全篇无 XBRL 垃圾串（`xbrli:` / `iso4217` / `FALSE+CIK` / `contextRef` / 裸 accession）；
无未转义裸 `&`。

## 测试脚本

| 文件 | 作用 |
| --- | --- |
| `sec_job_headless.lua` | 无头跑 `sec_job.lua`：`smoke`（含 10-K/10-Q、只有 8-K、中途取消）／`full`（7 家生产级） |
| `plugin_shell_test.lua` | 用 `package.preload` 把 UI 模块换成桩，无头加载**真实 `main.lua`**：require、init、菜单树、设置、整轮下载、结果汇报 |
| `attr_probe.lua` | 无值属性补值的针对性单元测试 |
| `sdr_purge_test.lua` | 边车目录清理测试（两种命名、非空目录、缺失时不报错） |
| `evidence/verify_epub.py` | 上面那套 epub 严格校验 |
| `evidence/*.log` | 全部原始输出 |

## 真机重启后的验证结果

重启：`/sbin/reboot`（2026-10-07 08:54:19，重启前 uptime 10:18）。设备于 08:58 重新进入 KOReader，SSH 自行恢复。

| 判据 | 结果 |
| --- | --- |
| KOReader 重启后重新加载插件 | ✓ 新启动日志里 `Error when loading` 出现 **0 次** |
| `appearance.koplugin` 已不在加载列表 | ✓ `plugins/` 从 41 个降到 40 个 |
| 本次启动唯一 WARN | 与本插件无关（`PluginLoader: kindleui name in _meta.lua, is deprecated`） |
| 用户直接打开产出的 epub | ✓ `08:58:27 INFO opening file /mnt/us/documents/SEC 财报/微软 SEC 财报.epub`，无任何报错 |
| 7 个 epub 均被 KOReader 识别 | ✓ KOReader 为 7 个 epub 都建了 `.sdr` 边车目录（08:56） |

关于「插件加载成功」这条判据的依据（`frontend/pluginloader.lua:_load()`）：

```lua
local ok, plugin_module = pcall(dofile, mainfile)
if not ok or not plugin_module then
    logger.warn("Error when loading", mainfile, plugin_module)   -- WARN，一定可见
...
logger.dbg("Plugin loaded", plugin_module.name)                  -- DEBUG，默认看不见
```

失败会打 WARN，成功只打 dbg。所以新启动期间「0 次 `Error when loading`」
就能证明每个插件的 `dofile`（包含 `require("sec_job")`）都成功了。

### 唯一没验到的

**没有在真机上点过插件菜单。** 无法从 shell 注入触摸事件，所以
「工具 → SEC 财报下载 → 点下去跑完弹结果」这一整套依赖于手动点击的流程
没有实测过。已用 `plugin_shell_test.lua` 把能脱开点击验证的部分全盖了
（菜单树构建、设置读写、整轮下载、结果汇报），剩下的只是 widget 真正画出来那一步。

## 已知限制（如实记录，没有含糊过去）

1. **图片不下载**。财报幻灯片类的 exhibit（如微软 FY27 Segments deck、特斯拉 Q2 2026 Update）
   正文靠图片承载，epub 里只有文字层。章节说明里会写明「本份原文含 N 张图片…图片没有下载」。
   如果用户要看幻灯片，需要单独加一步下载图片并嵌入（会显著增大体积和耗时）。
2. **超大文档耗时**。12MB 上限内最坏情况（8.6MB）单份要 60 秒左右，期间进度框停在
   「正在取 …」不动，看着像卡住，实际在跑。峰值内存约 115MB。
3. **只有文字层的 slide deck 章节看起来会偏空**，这是第 1 条的必然结果。
4. **UI 的实际渲染没有在真机上点过**。`plugin_shell_test.lua` 覆盖了菜单树构建、
   设置读写、整轮下载、结果汇报，但没有覆盖「widget 真的画出来」。
   剩下没验的就是这一步。
5. `sec_build_test.lua` / `sec_probe.lua` 是上一轮留下的旧测试，仍然可用但没再维护。
6. **设备上正在跑的 KOReader 加载的是 `sec_epub.lua` 的倒数第二版**。
   重启（08:58）之后我才发现边车目录名写错并改了 `sec_epub.lua`（08:59）。
   所以内存里那份与我们交付的那份，差别**只在于「重写 epub 时清不清阅读缓存」**，
   对已经生成的 7 个 epub 没有任何影响；下一次 KOReader 启动就会用上正确版本。
   没有再重启一次，是因为用户当时正在读那个 epub，不想打断。
7. 每次重写某家公司的 epub 都会清掉它的 `.sdr`（阅读位置 + 排版缓存），
   这是原设计有意为之（内容变了，旧缓存会指错地方）。副作用是重下后该书阅读进度归零。

---

## 追加（2026-10-07，父会话验收时发现并修复）

### 用户反馈「微软最新 8-K 不可读」的真正原因：原文把文字藏起来了

**不是**内容缺失，也不是缺图片。根因在 SEC 原文里：

```html
<p style="…font-size:1pt;line-height:0pt;color:#FFFFFF;">
  <font style="font-family:Times New Roman;font-size:1pt;"> FY27 Segments and Investor Metrics …</font>
</p>
```

微软这类**幻灯片 exhibit 的 HTML 是用「1pt、纯白、行高 0」写的无障碍替代文本层** —— 视觉内容在
图片里，文字层被刻意设成不可见。本插件不下载图片，于是那 25048 字符在白色纸面上**完全看不见**，
整章看起来就是空白。实测该文件：`color:#FFFFFF` 22 处、`font-size:1pt` 44 处、`line-height:0pt` 22 处。

**关键认识**：这个文字层本身是**完整**的。去掉致盲样式后能读出 24945 字符，含完整分部营收表：

```
Restated Historical Financials ($ in millions)
Agents and Infra   Q1 Q2 Q3 Q4 Fiscal Year
Revenue        $61,672 $64,441 $67,438 $74,576 $268,127 …
Cost of revenue $17,701 $19,307 $20,949 $23,460 $81,417 …
```

所以**不需要**去下 22 张幻灯片图 —— 对电子书来说，把文字显出来反而更好（可重排、可搜索、
可划词查字典），而下图片会让 epub 体积翻好几倍、且不可检索。

**修法**：`sec_source.lua` 新增 `unhideTextStyles()`，在 cleanHtml 的第 2.5 步执行，摘掉：
- `color:#FFFFFF / #fff / white / rgb(255,255,255)`（白纸上看不见）
- `font-size` < 6pt（1pt 这类隐藏层）
- `line-height:0`（把整段压成一条线）
- `display:none` / `visibility:hidden`
- `<font color="#FFFFFF">` 属性形态
- 摘完留下的空 `style=""`

只摘「致盲」声明，其余排版（对齐、字重、表格边框）原样保留。Lua 模式没有大小写修饰符，
所以属性名用字符类展开（`[Cc][Oo][Ll][Oo][Rr]`），属性值取出来 `:lower()` 再比。

**验收结果**（7 个 epub 全部）：致盲样式残留 **0**，结构合规，目录锚点与正文一一对应。
正文合计 17.5 万 – 82 万字符。微软那份从"看不见"变成 25048 字符可读正文。

### 同时修掉的一处误导性提示

原来的章节说明写「本份原文含 N 张图片；插件只抓文字，图片没有下载」，会让读者以为内容缺失。
改为「幻灯片类文件（原文含 N 张图片）：此处为原文的文字层，数字与表格均在」。
（`sec_job.lua` 的 note 生成处。）

### 如果以后还想看幻灯片原图

需要新增「下载并嵌入图片」这一步（KOReader 自带 newsdownloader 的 `EpubDownloadBackend`
支持 `include_images`，可参考其做法）。属于新增需求，未做。

---

## 追加二（2026-10-07）：排版优化 —— 让 SEC 内容听阅读器的设置

### 根因：7 万个内联 style 把阅读器的设置全部压住了

实测微软那份生成的 content.html：

| 内联属性 | 次数 | 后果 |
| --- | --- | --- |
| `style=` | **72,106** | — |
| `font-family` | **46,838** | **读者在 KOReader 里选的字体对 SEC 内容完全失效** |
| `font-size` | **17,125** | **读者选的字号同样失效** |
| `text-align` | 38,925 | 大量居中，正文段落被居中很难看 |
| `min-width` / `padding-left` / `white-space` | 各 2 万+ | 6 寸屏上溢出、挤压 |

内联样式优先级高于阅读器设置，所以问题不是"某处样式写错了"，而是**原文的表现层
样式在跟阅读器抢控制权**，且它赢了。

### 修法：`sec_source.lua:stripPresentation()`（cleanHtml 第 9.5 步）

只保留「结构与语义」属性，其余全摘：

- **保留**：`colspan`/`rowspan`（表格语义）、`href`（链接）、`id`（锚点）、`src`/`alt`、
  自闭合斜杠
- **摘掉**：`style`、`class`、`width`、`height`、`align`、`valign`、`color`、`face`、
  `size`、`border`、`bgcolor`、`cellpadding`、`cellspacing`、`nowrap` …
- **特例**：表格元素额外保留横向对齐（`text-align`）。财报靠列对齐才有可读性，
  而原文的 `text-align` 绝大多数是给段落做居中用的，那种一律摘掉。
- `<font>` / `<span>` / `<center>` 是纯表现层容器，去标签留文字。

**效果**：特斯拉 10-Q 的 content.html 从 1,573,441 → **316,751 字节（-80%）**，
`colspan` 4062 / `rowspan` 66 / `href` 86 全部保留，文字 127,655 字符一字未丢。
体积缩小 80% 同时意味着 KOReader 解析和翻页明显变快。

### 样式表相应加强（`sec_epub.lua`）

摘掉内联样式后，这些必须由 epub 自己的 CSS 补上，否则会散掉：

- `td, th { padding: 0.1em 0.5em }` —— 摘掉 `padding-left/right` 后列会贴在一起
- `td, th { font-size: 0.85em }` —— **唯一一处刻意指定字号的地方**。SEC 财报表格常有
  20 多列，略小一号能让每列多容纳约 15%。正文一律不指定字号，交给读者。
- `hr { border: 0; border-top: 1px solid #bbb; height: 0 }` —— 原文用 `<hr>` 标分页，
  浏览器默认的立体横线在电子书上很老气
- `h1.secfiling / h2.secfiling-company { page-break-before: always }` —— 每份 filing 新起一页

### 顺带修掉一个真实故障：大文件下载缺重试

生成微软时出现 `跳过 10-K 2026-07-29（取文档失败: HTTP closed）` —— 8.6MB 的 10-K
在慢网络上连接中途断开，**那一章整份被跳过**（微软从 276KB 掉到 23KB）。
`SecSource:fetch` 已改为：**最多重试 3 次**、显式设 120 秒超时（LuaSocket 默认 60 秒不够下
8MB）；4xx 不重试（请求本身有问题，重试无意义），5xx 与网络错误才重试。

### ⚠ 一个修不掉、只能绕过的限制

**SEC 财务报表天生就是 20 多列，6 寸竖屏物理上放不下。** 实测过"去掉全空列"这条路：
特斯拉 1413 物理列里只有 318 列是全空的，典型大表 15 列 → 12 列，**只能省 7–20%**，
不解决问题。所以不要试图用"减少列数"来修表格排版，那条路已经验证过走不通。

可行的做法：
1. **手动横屏**（设备无重力感应，需手动）—— 文字栏宽度翻倍，表格立刻可读
2. KOReader 里**长按表格**可缩放/查看
3. 表格字号已设为正文的 0.85 倍，每列多容纳约 15%

### 设备无重力感应（2026-10-07 实测确认）

`/proc/bus/input/devices` 只有 `bd71828-pwrkey`（电源键）与 `pt_mt`（触摸屏），
`/sys/bus/iio/devices/` 下的 `iio:device0` 不是加速度计。KOReader 的 PW5 设备定义里
也没有 `hasGSensor` 字段（有感应器的机型才标 `hasGSensor = yes`）。

**所以这台设备物理上无法自动转屏。** 手动横屏路径：**齿轮 ⚙ → 屏幕 → 旋转**
（标签就是「旋转」，当前方向带 ★，长按设为默认）。「忽略重力感应」那一项在这种
设备上不会出现。kindleui 的首页书架本身支持横屏（`BookshelfWidget:onSetRotationMode`，
作者注释里就是为修这个 bug 加的）。

### 验收方法上的教训

两次"看起来像 bug"的现象其实是我的**预览脚本**造成的：
第一次 `html[best-400:...]` 把标签切断，渲染出孤立的 `>`；此后改为在标签边界切。
**排查渲染问题前，先确认分析工具本身没制造假象。**

另外：`BrowserScreenshot` 在本环境不可用（`UnknownVizError`），
改用 macOS 的 **`qlmanage -t -s 900 -o outdir file.html`** 把 HTML 渲染成 PNG，
可以真正看到排版。这个办法值得记住。

---

## 追加三（2026-10-07）：宽表格按列拆分 —— 让 20 多列的 SEC 报表在 6 寸屏上能读

### 问题到底出在哪里（这次是量出来的，不是猜的）

crengine 的表格**不会横向滚动**。表格所需宽度超过页面时，它把可用宽度
**平均分给每一个物理列**。用用户自己那本书的真实参数算一遍：

| 参数 | 值 | 来源 |
| --- | --- | --- |
| 屏宽 | 1236 px | `/mnt/us/documents/SEC 财报/微软 SEC 财报.sdr/metadata.epub.lua` 那份设置对应的机型 |
| 左右页边距 | `scaleBySize(10)` = 19 px | `copt_h_page_margins = {10,10}` |
| 正文栏 | 1236 − 2×19 = **1198 px** | |
| 用户字号 | `copt_font_size = 22` | 同上 |
| **实际生效字号** | **≈ 47 px** | 用该书记录的 `doc_pages = 471` 反推（见下） |
| 表格字号 | 0.85 × 47 = 40 px | 我的样式表 `td,th{font-size:0.85em}` |

于是 24 列的报表：

```
24 列 → 每列 1198/24 = 50 px，减掉单元格 padding 后内容宽只剩 19 px
而一个「20,006」需要约 87 px    ⇒  数字被逐字符折行
```

**「每列只剩十几像素」这句用户原话，和 19 px 这个计算值对上了。**

字号那一条很关键：`copt_font_size = 22` 只是设置里的数，不是 crengine 排版时用的数。
验证方法——拿这本书记录的 `doc_pages = 471` 去拟合：

| 我渲染时的字号 | 得到的页数 |
| --- | --- |
| 22（= 设置值） | 121 |
| 40 | 339 |
| 44 | 403 |
| **47 左右** | **≈ 471** |
| 48 | 485 |

所以真正参与排版的是 22 的约 2.15 倍（≈ 47）。这也顺带解释了一个长期困扰我的现象：
headless 下 `drawCurrentPage` 画出来的页面只有视图的约 1/4 —— 引擎内部在这个缩放上
与 KOReader 的真实渲染不同，**但排版坐标（正文栏宽度、字号）是一致的**，
所以只要用 `getTextFromPositions` 这类排版坐标接口判断，结论就是可靠的；
从渲染图反推比例会得出错误结论。

### 采用的做法：按列**投影**成若干张窄表，纵向堆叠

「投影」是这次改动的全部设计要点。对每个列块，把原表的**每一行**投影到
（行标签列 ∪ 本列块）上，colspan / rowspan 按投影结果重算：

* **无损是结构性的**：列块的并集覆盖了「所有出现过文字的列」，每张子表都带全部标签列，
  所以没有任何单元格文字会丢，也没有任何文字被搬到错的列上。
* **不需要判断「哪些行是表头」**：表头行就是普通行，投影之后它自然在每张子表里
  重复出现，跨列的表头 colspan 也会被正确收窄（原跨 9 列的表头，投到 4 列上就变
  colspan=4，文字不变）。这一条把最容易出错的环节整个绕开了。
* **语义单元不被切开**：列块边界落在「表头覆盖签名」相同的列之间，即同一个期间
  （`Three Months Ended June 30, / 2026`）的列总在一起；而且「被同一行的同一个单元格
  同时跨住」的相邻列不许分开，否则会出现「一张子表里只剩 `$`、另一张只剩数字」的碎片。

**顺带修掉的另一半问题：投掉「全空列」。** 即使一张表不需要拆，只要它存在
「整列没有任何文字」的物理列，也走一遍投影把它们投掉。那些空列各自吃掉 1em 的
单元格 padding，更要命的是表头单元格的 colspan 会跨在空列上 —— 空列几乎没有可用
宽度，表头就被挤成 `Thr / ee / Mon / ths / End / ed / June / 30,` 这种逐段折行。
特斯拉 10-Q 的 INDEX TO EXHIBITS 表在修复前就是这样（39 个物理列里只有 7 列有内容）。

没有选的两条路：

* **把每行改写成「标签: 值」的线性格式**：能读，但财报的核心价值是横向比期间
  （本季度 / 去年同期 / 半年），线性化后这个对比关系就没了。
* **把原表缩到整页宽**：那正是用户现在看到的结果，缩不动。
* （也已经验证过走不通：只删空列不拆表 —— 特斯拉 1413 个物理列里只有 318 列全空，
  典型大表 15 列 → 12 列，只能省 7–20%。）

### 参数怎么定的

| 参数 | 值 | 依据 |
| --- | --- | --- |
| `table_avail_em` | 30 表格 em | 1198 / (0.85 × 47) = 30.0，正好等于真机可用宽度；取整不放大 |
| `table_max_cols` | 6 列（含标签列） | 安全网：真机 6 列时每列 200px，减 padding 后 163px，`1,234,567` 这类最长数字（约 130px）放得下 |
| `table_projection` | `true` | 总开关，设 false 则整段不作用（用于对比或线上兜底） |

### 效果（同一张表，特斯拉 10-Q 合并利润表）

用 Chrome 在**真机等价宽度 408px**（= 1198px ÷ 字号47 × 字号16）下量：

| | 表数 | 最小内容宽 | 最大内容宽 | 结果 |
| --- | --- | --- | --- | --- |
| 修复前 | 1 张 24 列 | **597 px** | 1152 px | 超过 408px 189px ⇒ 挤压 |
| 修复后 | 2 张 5 列 | **263 / 261 px** | 854 / 837 px | 放得下，余 36% |

**逐张表的放得下/放不下统计**（`evidence/fitcheck.txt`，判据 = 最小内容宽 ≤ 408px）：

| 数据集 | 修复前排不下 | 修复后排不下 |
| --- | --- | --- |
| 特斯拉 10-Q（原文档全流程） | 27 / 51 | **0 / 107** |
| 特斯拉（设备产 content.html） | 27 / 64 | **0 / 120** |
| 微软（设备产 content.html） | 52 / 108 | **0 / 177** |
| 苹果（设备产 content.html） | 38 / 93 | **0 / 158** |

也就是**修复前共 144 张表排不下（最多超出 878px），修复后 0 张**。
每张表的物理列数：特斯拉 57 → 6，微软 33 → 10，苹果 42 → 9
（微软/苹果剩下的 9–10 列表是窄内容的勾选框表，最小内容宽本来就在 408px 以内，不需要拆）。

渲染图（`evidence/`）：
* `render_before_408px.png` / `render_after_408px.png` —— Chrome 在真机等价宽度下的对比。
  修复前：标签列被压成 3–8 行、`Six Months` 那两列整个溢出画面之外；
  修复后：所有标签一行放完、数字全部右对齐成列、两张子表分别读作
  「Three Months Ended June 30, 2026 | 2025 | $ 20,006 | $ 15,787 …」和
  「Six Months Ended June 30, 2026 | 2025 | $ 35,479 | $ 28,712 …」。
* `cre_crengine_before_f47_top.png` / `cre_crengine_after_f47_top.png` —— **真机 crengine**
  自己的渲染（1/4 分辨率等比放大）。修复前表头被折成 `Thr / ee / Mon / ths`。

### 改了哪些文件

| 文件 | 改动 |
| --- | --- |
| `sec_source.lua` | 新增约 500 行的「宽表格列拆分」段 + 4 个参数；`cleanHtml` 里在 cre 之后、`stripPresentation` 之前插入第 9.2 步；另修 `dropTag` 漏掉自闭合写法 `<font/>` 的老问题 |
| `sec_epub.lua` / `sec_job.lua` / `main.lua` | **未改** |
| `work/`（本地测试与证据工具） | 见下 |

`dropTag` 那个老问题：原文里有一个 `<font/>`（标签名后直接跟斜杠），既不匹配
`<font>` 也不匹配 `<font …>`，于是长期留在 content.html 里 —— 「表现层残留为 0」
这条验收其实一直没真正达标。改完之后微软 10-K 的 `font-family` / `font-size:` /
`<font` / `<span` 计数全为 0。

### 怎么证明没丢数、没串列（三层独立证据）

1. **逐格精确自检**（`evidence/selfcheck.lua` + `evidence/selfcheck.txt`）：
   把 `renderChunk` 真正产出的 HTML 反解析回来，逐行逐格与「投影规范」比对
   **位置、colspan、文字**三项，并断言「列块并集覆盖全部有文字的列」。
   4 份数据、21 943 个输出单元格，全部一致。
2. **全篇多重集守恒**（`evidence/verify_split.py` + `verify_split.txt`）：
   `after ⊇ before`（一个单元格文字、一个数字令牌都不能少）；
   `after − before` 必须全部落在「可重复单元格」白名单内（标签列上的单元格、或源文档里
   `colspan ≥ 2` 的单元格）—— 也就是没有凭空造数。4 份数据全部 16 项 [OK]、0 项 [!!]。
3. **网格解析器独立复核**（`evidence/gridcmp.py` + `gridcmp.txt`）：
   Lua 侧的物理列网格与一份独立实现的 Python 解析逐表比对（物理列数、每个单元格的
   起始列 / colspan / rowspan / 文字），4 份数据 48 540 个单元格完全一致 ——
   防止「解析器自己错了还自证清白」。

**这套检查抓到的问题，以及随后修掉的另外两处**

1. **两个我自己引入的、会静默丢数据的 bug**（都是「只输出第一块、
其余块整块丢掉」的同类错误，最严重的一次让特斯拉 10-Q 的 INDEX TO EXHIBITS 表
和微软 10-K 目录页的页码整块消失）。这正是「必须做自动化证据、不能靠眼睛看几张图」
的理由。
2. **「表头行」判定把年份当成数据。** 原来用「这一行有 ≥2 个数字单元格」来找第一个数据行，
   而表头里的年份（`2026` / `2025`）本身就是数字，于是表头行被当成数据行、表头签名只用到
   更上面那一行 —— 那一行常常是跨全表的横幅标题（`colspan=12`），结果每一列的签名都一样，
   整张表被当成一个不可分割的组，永远拆不开。改成「≥2 个**金额**（数字位数 > 4）」之后，
   微软那 4 张分部业绩表才拆得开（它们是最后 4 张排不下的表）。
3. **跨全表的横幅标题被当成「不可分割的绑定」。** 我原来规定「被同一行的同一个单元格
   同时跨住的相邻列不许分开」（为了防止 `$` 和它的数字被拆散），但跨 12 列的横幅标题
   也满足这个条件，于是整张表变成一块。改为「只统计该单元格跨住了几个**有内容的**列，
   超过 4 个就不算绑定」——横幅本来就该在每张子表里各出现一次，不该拦住拆分。

### 验收预演（本机）

`evidence/preview_accept.py` 拿设备现产 epub 的 content.html、跑真实的列拆分、按同样
结构重新打包，再跑严格校验：3 本书全部「zip 合法 + mimetype STORED + 四个 XML 良构 +
toc 锚点与 h1 一一对应 + 章节正文长度 + 本次改动新增的表现层残留 0 项」。

### 本地测试与证据工具

| 文件 | 作用 |
| --- | --- |
| `work/stub_env.lua` | 把 `socket.http`/`ltn12`/`json`/`logger`/`cre` 换成桩，于是在 Mac 的 LuaJIT 上能直接 require **真的** `sec_source.lua` |
| `work/local_clean.lua` | 跑完整清理流水线，或只跑拆表（`plainsplit`） |
| `work/selfcheck.lua` | 逐格精确自检（也可 `griddump` 出网格供 Python 复核） |
| `work/dbg_split.lua` | 打印某张表的网格 / 标签列 / 列块规划 / 每个子表用了哪些源列 |
| `work/verify_split.py` | 全篇文字与数字守恒 + 白名单检查 |
| `work/gridcmp.py` | 与独立 Python 网格解析交叉复核 |
| `work/ent_test.lua` | 实体解码单元测试 |
| `work/mkepub.py` / `render_tbl.py` / `render.py` | 造最小 epub、用 Chrome 在真机等价宽度下渲染 |
| `work/mk_frag.lua` | 从 content.html 抽某张表的「修复前 / 修复后」片段 |
| `work/preview_accept.py` | 本机预演设备端验收 |
| `work/run_pairs.sh` | 一键跑全部守恒检查 |

### 设备端：7 本全部用新代码重新生成并通过完整验收

设备醒来后（13:02）执行：

1. **部署** 5 个文件到 `/mnt/us/koreader/plugins/secfilings.koplugin/`，
   设备自己的 luajit 做 `loadfile` 全部返回函数；`md5sum` 与本地一致
   （`9b2682c76127b858736aa69ef1004f78`）。
2. **重新生成 7 本**：`sec_job_headless.lua full` → 「成功 7 家，失败 0 家」，
   耗时约 4.5 分钟（13:03–13:07）。
3. **完整验收 7 本**（`work/accept7.py`）：结构失败 0、表现层残留 0、
   **排不下的表 0 张**（合计 1174 张表）。

| 公司 | epub | 表数 | 排不下 | 结构失败 | 表现层残留 |
| --- | --- | --- | --- | --- | --- |
| Meta | 237 KB | 199 | 0 | 0 | 0 |
| 亚马逊 | 91 KB | 152 | 0 | 0 | 0 |
| 微软 | 130 KB | 175 | 0 | 0 | 0 |
| 特斯拉 | 64 KB | 120 | 0 | 0 | 0 |
| 英伟达 | 60 KB | 130 | 0 | 0 | 0 |
| 苹果 | 72 KB | 158 | 0 | 0 | 0 |
| 谷歌 | 87 KB | 240 | 0 | 0 | 0 |

结构验收沿用 `evidence/verify_epub.py`（zip 合法 + CRC + `mimetype` 首个且 STORED +
`container.xml`/`content.opf`/`toc.ncx`/`content.html` 四个 XML 良构 +
`content.html` 里 `<html>`/`<body>` 各 1 次 + toc 锚点与 `<h1 id>` 一一对应且顺序一致 +
每段正文 ≥ 400 字符 + 全篇无 XBRL 垃圾），逐本输出存
`evidence/accept7_*.txt`。

4. **真机产物的逐字比对**：另外跑了一次「把列拆分整段关掉」的对照生成
   （`sec_noproj.lua` → `/mnt/us/tmp_noproj/`），同一批 SEC 文件、同一天、
   同一份代码，唯一差别是那个开关。于是两份产物的差异必然全部来自拆表这一步：

   | 公司 | 单元格文字 | 数字令牌 | 章节一致 | 结论 |
   | --- | --- | --- | --- | --- |
   | Meta | 4447 个一个不少 | 2635 个一个不少 | ✓ | 通过 |
   | 亚马逊 | 4310 | 2988 | ✓ | 通过 |
   | 微软 | 4854 | 3266 | ✓ | 通过 |
   | 特斯拉 | 2639 | 1484 | ✓ | 通过 |
   | 英伟达 | 2542 | 1564 | ✓ | 通过 |
   | 苹果 | 4296 | 2512 | ✓ | 通过 |
   | 谷歌 | 5347 | 3692 | ✓ | 通过 |

   7 本合计：`content.html` 4,617,054 → 3,859,872 字节（**−16%**，
   因为投掉了大量空列）。逐字比对全部通过（`evidence/compare7_*.txt`）。
   逐格精确自检也在真机产物上跑了一遍（`evidence/selfcheck_real7.txt`）：
   7 本共 43,131 个输出单元格，位置/colspan/文字三项全对，列块并集覆盖全部有文字的列。

### 真机 crengine 自己的渲染（`evidence/cre_native_*.png`）

Chrome 是等价近似，所以我另外想办法拿到了**真机 crengine 在真机版面几何下**的渲染图。
绕的弯子：headless 下引擎把排版页按 `buffer/4` 的比例画进 buffer 并平铺（这点是用几组
不同 buffer 尺寸量出来的，与视图尺寸无关）。于是换一条等价的路 —— 把**视图缩小 4 倍、
字号与页边距同步缩小 4 倍**（版面在几何上与真机相似：正文栏宽度与字号的比值不变，
每行放得下的字符数不变），再给一个 `4 × 缩小后视图` 的 buffer，画出来的那一份正好
等于缩小后的视图尺寸，裁出来就是这份版面的 1:1 渲染，放大 4 倍即为真机版面的等比还原
（`cre_native.lua`）。

图里能看到的就是用户描述的现象：

* `cre_native_before_top.png`：标签列被切成一行行短碎片；右侧四列数字**逐字符折行**，
  每列都是一摞十几个单字符/双字符的小块，完全看不出是数字；表格右半边是空白。
* `cre_native_after_top.png`：只有两列数字（`$` 列很窄），每行一个 5–6 字符的数字整体
  在一行里，标签列的行明显完整得多。

**一个重要的方法教训**：我一开始想用 `getTextFromPositions` 取排版文字来判断「数字有没有
被折行」，结果它对 before/after 都报「数字完整」—— 因为它返回的是**逻辑文字**，
把同一个词内部被折开的片段又拼回去了，检测不到逐字符折行。
**判断折行只能靠像素渲染，不能靠文字提取。** 这一条已经写进工具注释里。

### 仍然没做到 / 不确定的（如实记录）

1. **没有真机 KOReader 截图。** `BrowserScreenshot` 在本环境不可用；
   KOReader 的 `httpinspector.koplugin` 是现成的 HTTP 远程控制入口，但默认没开，
   开启需要先改设置再重启。真机 crengine 的渲染是走 headless 拿到的
   （`evidence/cre_crengine_*.png`），不是屏幕截图。
2. **`table_avail_em = 30` 是按用户当前这本书的设置算的**（字号 22 → 实际约 47、
   页边距 10 → 1198px 正文栏）。如果用户把字号调到最大档（44），可用宽度会降到约
   15 表格 em，届时 5 列的子表也会重新被挤压。要覆盖这种情况需要按「读这本书时的
   实际设置」动态取值，本轮没做 —— 但把 `SecSource.table_avail_em` 调小即可，
   代价是子表更多、文档更长。
3. **表格的字号是 0.85em**（上一轮为「让每列多容纳 15%」定的）。这次没有动它。
4. **财务惯例的「小计线」（原 `border-top`）在上一轮 `stripPresentation` 里就被摘掉了**，
   本轮没有恢复：表现层验收明确要求 `style=` 里只允许 `text-align`。所以子表能读，
   但小计与明细之间没有横线区分。
5. **headless 下拿不到全分辨率的真机渲染图。** 引擎把页面按 `buffer/4` 画进 buffer
   并平铺，所以 `evidence/cre_native_*.png` 的底图只有真机的 1/4 分辨率（放大后字迹发虚），
   `evidence/cre_crengine_*.png` 更粗（1/16）。**真正字迹清晰、可逐字读的对比图是
   Chrome 在 408px 下渲的那两张** `render_before_408px.png` / `render_after_408px.png`
   （408px 与真机正文栏的「每行字符数」严格等价，见上文换算）。想要一张真机原生
   分辨率的 KOReader 截图，只能走屏幕截图那条路，本轮没打通。
6. **`SecSource._plainTextForTest`** 是我为了让实体解码能被单独单元测试而暴露的只读入口
   （2 行，不影响行为）。如果不喜欢生产代码里有测试钩子，删掉它和 `work/ent_test.lua`
   即可。

### 剩下唯一没做的一步：重启

代码已经部署、7 本已经用新代码生成并验收通过。剩下只有让 KOReader 重新加载插件：

```bash
ssh kindle '/sbin/reboot'
# 重启后 KOReader 不会自动启动，需要在书库里点开那本叫「KOReader」的书
```

想复核「数字不再被折行」的话，可以把某张表抽成测试 epub 用 `/mnt/us/cre_wrap.lua`
在设备上验（它直接问引擎：给定的那些数字在排版结果里是否**完整**出现）：

```bash
mkdir -p /mnt/us/cre_out
ssh kindle 'cd /mnt/us/koreader && LD_LIBRARY_PATH=/mnt/us/koreader/libs:/mnt/us/koreader \
  ./luajit /mnt/us/cre_wrap.lua /mnt/us/tbl_23_after.epub 47 \
  "20,006,15,787,35,479,28,712,146,439,526,1,034,20,516,36,750,50,623,41,831"'
```

第 2 步之后建议再补一条「真机渲染确认」：把最好奇的那张表抽出来做成测试 epub，
用 `/mnt/us/cre_render.lua`（已在设备上）渲染成 PNG，确认数字不再被折行 ——
命令见 `cre_wrap.lua`（它直接在排版坐标里检查给定的数字是否完整出现）。

---

## 追加四（2026-10-07）：关注列表 + 增量更新 + 阅读进度保留（`sec_watchlist.lua`）

这一节记的是「让用户自己选关注哪些公司、只抓新文件，同时不把阅读进度清掉」这轮的结果。

### 交付物

| 文件 | 状态 | 说明 |
| --- | --- | --- |
| `sec_watchlist.lua` | 新增，纯逻辑 | 关注列表存储 + 增量判定 + `.sdr` 保留。不 require 任何 `ui/*` 或设备模块；`lfs` 是懒加载的，拿不到就退化成 shell |
| `WATCHLIST.md` | 新增 | API 签名、用法、接线说明（含设置界面怎么挂）、列表文件格式与迁移策略、`.sdr` 策略与代价 |
| `work/watchlist_test.lua` | 新增 | 关注列表与增量判定，205 项检查 |
| `work/sdr_test.lua` | 新增 | `.sdr` 保留方案，92 项检查 |
| `work/watchlist_lfs_test.lua` | 新增 | 用假 lfs 强制走**设备上真正会走的那条分支**，29 项检查 |
| `work/watchlist_realsearch_test.lua` | 新增 | 用**真实的** `sec_search.lua` + 真实的 SEC 数据验证对接，31 项检查（需联网，`SKIP_NETWORK=1` 可跳过） |
| `work/sdr_fixture.lua` | 新增 | 用 KOReader 自己的 `dump.lua` 生成 `.sdr` 夹具 |
| `work/ko_dump/dump.lua` | 新增 | v2026.07.2 的 `dump.lua` **原文**（md5 `a57d9f24c29ee178794b32e773ca99b1`） |

复跑（四项全过：205 + 92 + 29 + 31 = 357 项检查，本机 LuaJIT 2.1，不访问设备）：

```bash
cd .context/kindle/tools/sec_epub
sh work/run_sec_watchlist_checks.sh
# 日志：evidence/watchlist_test.txt  evidence/sdr_test.txt
#       evidence/lfs_test.txt  evidence/realsearch_test.txt
SKIP_NETWORK=1 sh work/run_sec_watchlist_checks.sh   # 只跑离线三项
```

### 一、三条关于 `.sdr` 的硬事实（顺带纠正本文件前面的一处错记录）

**1. 侧车目录名是 `<书名>.sdr`，不是 `<书名>.epub.sdr`。**

本文件第 113 行那张表写的是「设备上实测 KOReader v2026.07.2 用的是带扩展名的写法」——
**这条是错的**，同一个文件第 348 行的真实路径已经证明了正确的写法：

```
/mnt/us/documents/SEC 财报/微软 SEC 财报.sdr/metadata.epub.lua
```

源码证据也对得上：

- 设备的 `settings.reader.lua:148` 是 `["document_metadata_folder"] = "doc"`
  （备份：`backups/2026-10-07-final/settings.reader.lua`）；
- v2026.07.2 的 `frontend/docsettings.lua:getSidecarDir()` 在 `doc` 模式下会**先去掉最后一个扩展名**：
  `path = doc_path:match("(.*)%.")` → `…/微软 SEC 财报`，然后 `return path .. ".sdr"`；
- `getSidecarFilename()` 给的是 `"metadata." .. 扩展名 .. ".lua"` → `metadata.epub.lua`。

`sec_epub.lua` 目前**两种名字都 purge**，所以功能上没错，只是注释误导。本轮新模块以
`<书>.sdr` 为主、`<书>.epub.sdr` 兼容，两个都认（`sidecarDirs`）。

**2. KOReader 打开书时不会校验 `partial_md5_checksum`。**

v2026.07.2 的 `frontend/apps/reader/readerui.lua:497` 只在它为空时**写入**，从不比较。
所以内容换了而 `.sdr` 还在，里面的 `last_xpointer` 会被**照原样套用**，打开就跳到莫名其妙
的位置。这正是 `SecEpub:write` 里那句 `purgeDir` 的正当性来源 —— 它不是保守，是必需。

顺带排掉一条看起来很美、实际无效的方案：**「让 zip 前 10KB 保持不变，哈希就不会变」**。
`frontend/util.lua:1094` 的 `partialMD5` 是在 **256B / 1KB / 4KB / 16KB / 64KB / 256KB /
1MB / 4MB / 16MB / 64MB / 1GB** 各取 1024 字节做哈希，采样点铺满整个文件；
只要正文变了哈希必变。而且上面刚说过，哈希变不变**根本不影响**位置会不会被套用。
所以「改包不换文件」这条路既做不到、也没必要（详见 `WATCHLIST.md` §7.6）。

**3. 清位置时必须连带清 `cre_dom_version`。**

`readerrolling.lua:170` 的逻辑是：**没有** `cre_dom_version` 但**有** `last_xpointer`
→ 判定为「很久以前打开过的老书」，主动请求**最老的 DOM 版本**。我们重建的是全新内容，
这个组合会让 crengine 用错 DOM 版本；而只清 `last_xpointer` 又会正好触发这条分支。
两个一起清才干净。这条不查源码是想不到的。

### 二、增量语义：为什么必须有「基线」

只靠「下过的 accession 清单」（`seen`）回答不了「SEC 上那几千份历史要不要」。所以每家多一个
**基线 `seen_upto_date`（日期）**：`filing_date` 早于它的一律不补。

这个设计不是凭空来的 —— 第一版**只**用 `seen`，测试立刻复现了这个后果：

```
=== 3. 落账后第二次运行同一批数据：0 份新文件 ===
  [FAIL] 特斯拉：第二次 0 份新增
  特斯拉：新增 8 份 （还有 44 份未取，下次继续） SEC 上最新：2026-09-30
```

也就是：首轮只下最近 8 份，**剩下 52 份会在之后每一轮都被当成「新文件」继续下**，
用户会看到「我什么都没做，书却在无限变长」。加上基线之后：

| 场景 | 实测结果（`evidence/watchlist_test.txt`，另见真实数据版的 `evidence/realsearch_test.txt`） |
| --- | --- |
| 首次运行（7 家 × 60 份） | 每家恰好 8 份（= `min(first_run_new=10, max_new=8)`），`history_skipped` 报出剩下的；`truncated = 0` |
| 同一批数据再跑一次 | **0 份** |
| 注入 1 份新文件 | **恰好 1 份**，就是注入的那份 accession |
| 只关注 `10-Q` 时注入 8-K | **0 份**（表单过滤生效）；改注入 10-Q → 1 份；`10-Q/A` 默认算同类，`exact_forms = true` 才算 |
| 长期没更新后一次涌入 8 份 | 每轮取 3 份、`truncated` 报出剩余，三轮取完互不重复；**截断时基线不动**，所以最后 2 份不会被跳过 |
| 放宽 `forms` | 基线之前被过滤掉的类型**不会**自动补下（否则又变成「书无限变长」）；要补用 `resetBaseline` |

#### 基线为什么必须按**日期**比 —— 真实数据一跑就炸的那个坑

第一版是按 accession 比（「accn 比基线大就是新的」），理由是 accession 看起来单调递增。
**这个假设在真实数据上当场就碎了。**

EDGAR 的 accession 形如 `NNNNNNNNNN-YY-NNNNNN`，前 10 位是**上报代理机构**的编号，**不是公司的
CIK**。苹果那 368 份 filing 里出现了 **42 个不同的前缀**（`create` 出来的合成数据永远只有一个），
里面甚至有 EDGAR 自己的 `9999999997-*`（`NO ACT` / `CERTNYS` 这类行政记录）：

```
按 accession 字符串降序：          按日期降序（真实时序）：
9999999997-17-006550  2017-05-25  0001140361-26-038674  2026-10-05  4
9999999997-17-000809  2016-10-27  0001969223-26-001055  2026-10-02  144
9999999997-16-026607  2016-10-26  0001140361-26-038307  2026-10-01  4
```

后果是实测出来的：第一次运行结束后，第二次运行又冒出 **16 份「新文件」**，全是几年前的老文件。

所以基线改成按 `filing_date` 比（字典序就是时间序）。两个配套细节：

- **「收盘清单」**：基线是日期，光靠日期分不出「与基线同日、这次没下」的文件，所以
  `planUpdates` 会把最新那一天的**全部** accession 放进 `closing_accns`，落账时一并标记。
- **被 `forms` 挡掉的文件也会被基线越过** —— 用户只跟 10-Q 时来的那份 8-K 不会在之后补下
  （要补得 `resetBaseline`）。这是「基线之前不补」的直接推论，界面上要写清楚。

两条用返回值传出去的纪律：

- **只有真下成功的才 `markSeen`**。提前标记等于「网络断一次，那份文件永远拿不到」——
  属于本项目反复踩过的那类静默丢数据；测试里专门验了「没标记时下一轮还会再出现」。
- **任何被跳过的东西都要能被看见**：`history_skipped`（基线之前）、`truncated`（下次继续）、
  `since_skipped`（被 since_date 过滤）、`warnings`（重复 accession、日期格式异常）。
  日期格式异常的 filing **不丢**，只是不参与 `since_date` 比较（宁可多取，也不静默丢）。

### 三、阅读进度保留：实测结果与代价

做法是把 `.sdr` 拆成两类：**位置/缓存类**丢弃（`last_xpointer` / `last_percent` /
`percent_finished` / `doc_pages` / `pagemap_doc_pages` / `cache_file_path` /
`cre_dom_version` / `stats`），**外观类**原样保留（`copt_*`、`style_tweaks`、`view_mode`、
`visible_pages`、`text_lang`、`doc_props`、`summary`、`partial_md5_checksum` …），
`annotations` 默认丢弃但把条数报出来。

`evidence/sdr_test.txt` 第 3 节有逐键的「前 → 后」对照表（夹具的每个键去了哪、值还一不一样），
第 4 节证明**重建出来的文件与 KOReader 自己 `dump.lua` 的输出逐字节一致**
（只差首行注释；`LuaSettings:open` 内部就是 `pcall(dofile)`，所以格式这关是过硬的）。

两种位置策略，用**真实书本尺寸**算的数值（正文 694413 字节 / 5 章，最新一章 25866 字节）：

| 策略 | 行为 | 实测 |
| --- | --- | --- |
| `reset`（默认） | 不写位置信息 → 下次打开落在书的**开头**，也就是最新那份 filing（目录顺序就是最新在前） | 41.28% 的位置被清掉；外观设置 15 个键逐格不变 |
| `shift` | 新文件是**前插**的，用 `old/new` 比例把旧百分比平移：`(1-ratio) + f*ratio`，写进 `last_percent`（v2026.07.2 的 `readerrolling.lua:204` 仍在读它） | `ratio = 668547/694413 = 0.962751` → **41.28% → 43.47%**，与手算一致（误差 < 1e-9） |

`shift` 的**代价**（必须如实说）：误差来自 (a) 用字节数代理「页数」，而 crengine 分页还受
表格/图片密度影响；(b) 只有一份旧基线，多轮会累积。**误差量级是「一份 filing」**——
可能停在上一份或下一份文件里，但不会指到书外。反复更新三轮的实测：41.28% → 43.39% →
45.35% → 47.18%，字号和页边距始终是 22 / 10。

两个刻意的取舍：

- **保留 `partial_md5_checksum`**：statistics 插件就是靠它去数据库里认那一行
  （`plugins/statistics.koplugin/main.lua:829`），保留它历史阅读时长才不断档；
  代价是丢掉 `stats`（按旧页码记账）→ 上次落库之后没写进库的那点时长（一次会话量级）会丢。
- **`annotations` 默认丢**：高亮/书签的 `pos0/pos1` 是 xpointer，内容换了会**静默**指到别的句子，
  比丢掉更糟。条数会报出来，界面可以提示。

### 四、这轮踩到/避开的坑（都是本机能复现的）

1. **LuaSettings 的落盘格式不是 `dump()` 的输出。** 直接写 `dump(t)` 出来的文件是
   `{...}`（没有 `return`），`dofile` 读回来是 `nil`，KOReader 会当成「设置文件坏了」。
   真正的格式由 `util.writeToFile(data, path, force_flush, lua_dofile_ready=true, …)` 生成：
   前缀 `"-- " .. 文件路径 .. "\nreturn "`，末尾再加一个换行。设备上 `settings.reader.lua`
   第一行那个 `-- ./settings.reader.lua` 就是这么来的。夹具一开始漏了这一步，测试当场报
   `unexpected symbol near '{'`。
2. **`gsub` 返回两个值**，`tonumber(s:gsub("%s",""))` 会把第二个返回值当进制参数 →
   `bad argument #2 to 'tonumber' (base out of range)`。本机测试脚本里踩了一次。
3. **`SecWatchlist.commit(wl, plan)` 收的是「一组 update」**，单个 update 要包成
   `{ u }`。包错了不会报错，只是什么都不标记 —— 测试里就是这么暴露出来的。
   现在 `commit` 会认形状（有 `cik` + `new_filings` 就自动包成数组），并且接受 `nil`。
4. **把关注列表塞进现有 `secfilings.lua` 时，保存必须合写。** 如果它是从
   `["sec_watchlist"]` 键下读出来的，直接覆盖整份文件会把 `limit` / `include_reports`
   一起抹掉。现在 `save` 会记住来源容器并合并回去（有测试盯着）。
5. **设备上的 lfs 分支必须单独测。** Mac 上没有 libkoreader-lfs，所有本机测试走的都是
   shell 退化路径；`work/watchlist_lfs_test.lua` 用假 lfs 强制走真分支
   （29 项检查通过，假 lfs 被调了 64 次 `attributes` / 5 次 `mkdir`）。
6. **`restoreProgress` 不去建 `.sdr/cache/`。** 那是 KOReader 自己的目录；我们只在它**已经存在**时
   把里面的旧排版缓存清空。一开始测试写成「必须建出来」，是测试错了不是代码错了。
7. 性能（本机，7 家 × 1000 份元数据）：`planUpdates` 5 ms、`commit` < 1 ms、`save` 1 ms，
   列表文件 4.4 KB。设备慢一个量级也完全不是问题 —— `seen` 用了一次性建的 set 做 O(1) 比对。
8. **合成数据的盲区**（这条是本轮最有价值的一条）：`work/watchlist_test.lua` 里的 accession 是
   用 CIK 当前缀造的，所以「accession 单调递增」的假设在那里永远成立；直到拿真实的
   `sec_search.lua` 输出跑了一遍才发现它不成立（见上文「基线为什么必须按日期比」）。
   凡是「假设数据满足某个性质」的推论，都必须在真实数据上再验一次。

### 五、已知边界（如实记录）

1. **设备端没有实测。** 任务明确要求不访问设备，所以这轮所有结论都来自本机 LuaJIT
   加代码/源码证据。上设备后需要复跑一遍的是：`lfs` 分支（已有本机假 lfs 测试覆盖）、
   以及「改完 epub 后打开那本书，位置是否合理」这个只能人工看的动作。
2. **`.sdr` 夹具是「按真实格式重建」的，不是从设备拷下来的。** 字段集、取值都有出处
   （`copt_font_size = 22`、`copt_h_page_margins = {10,10}`、`doc_pages = 471` 来自
   FINDINGS 里那份真实阅读记录），`partial_md5_checksum` 是用 KOReader 的算法**真算**的，
   但 `last_xpointer` / `annotations.pos0` 这类 DOM 路径离线取不到真值，写的是合法形状。
   本轮只验证「这些键有没有被正确清掉」，不验证路径本身指向哪。
3. **`shift` 是估算**（见上文代价），不是精确恢复。
4. **放宽 `forms` 不补历史**；`resetBaseline` 会连 `last_accession` 一起清掉。
5. 不处理「同一 accession 下的多个文档（8-K 本体 + exhibit）」的合并下载：
   `planUpdates` 会把它们去重成一条并报出条数，要不要一起抓是 `sec_search.lua` +
   `sec_job.lua` 的事。
6. 没实现按 8-K 的 item（如 2.02 业绩发布）过滤；`items` 字段已经带出来了，留给下一轮。
7. **`sec_search.lua` 那边也有 `forms` / `since` 参数**，和本模块 per-公司 的 `forms` 是两层：
   建议取数时就把 `forms` 传给它（少拉数据、快），本模块再按名单做一次判定（防止两边理解不一致）。
   `sec_search.listFilings` 返回的 `entries` 字段名是 `accession_number` / `filing_date` /
   `primary_document`，本模块的 `normalizeFiling` 三套命名都认 —— 但这条是**跑真实数据验证过**的
   （`evidence/realsearch_test.txt`），不是看文档猜的。

---

## 追加三（2026-10-07）：图片抓取与嵌入 —— `sec_images.lua`

### 一句话结论

新增 `sec_epub/sec_images.lua`（纯逻辑、不 require `ui/*`）。用微软 **0001193125-26-380280**
那份 FY27 Segments exhibit 做端到端验证：**22 张图全部成功**，落盘字节与 SEC 原件
**逐张 md5 一致**，重写后的 HTML 里 22 个 `<img src>` 全部指向真实存在的内部路径，
`alt` 全保留。抓取阶段给 Lua 进程带来的峰值内存增量是 **0.80 MB**（其间流经 1.73 MB 图片），
即图片确实没有在内存里堆积。

### 那个「含 22 张图的文件」是哪一份

用户报告的幻灯片 exhibit 定位到：

| 项 | 值 |
| --- | --- |
| CIK | 789019（微软） |
| accession | `0001193125-26-380280`（8-K，2026-09-02） |
| 文档 | `d291965dex991.htm`（34,300 字节） |
| 基准 URL | `https://www.sec.gov/Archives/edgar/data/789019/000119312526380280/d291965dex991.htm` |
| 图片 | 22 张 `g291965ex99_1s1g1.jpg` … `s22g1.jpg`，**全部是 1200×675**，合计 1,808,803 字节 |

原文里的 `<img>` 形态非常规整，22 个都是
`<img src="g291965ex99_1sN g1.jpg" alt="Slide N" title="Slide N" >`。

### API（接线照这个来）

```lua
local SecImages = require("sec_images")
local res, err = SecImages:run(cleaned_html, base_url, {
    user_agent = UA,          -- 必填。SEC 不带邮箱一律 403；不硬编码，由设置传入
    dir        = work_dir,    -- 必填。图片写到 work_dir/images[/namespace]/
    namespace  = "msft-8k-20260902",  -- 多份 filing 打进同一个 epub 时**必须**唯一
    on_progress = function(done, total, name) end,  -- 可以 yield，在 pcall 之外调用
})
-- res.html     重写后的 HTML（src 变成 images/<ns>/imgNNN.jpg，alt 保留）
-- res.entries  { {id, href, arcname, path, mediaType, bytes, width, height, src, alt, refs}, ... }
-- res.failed   { {id, src, alt, err}, ... }
-- res.manifest 直接拼进 OPF <manifest> 的片段
-- res.stats    计数 / 字节 / 耗时（含 total_ms）
-- res.log      人类可读的说明行
```

接线三步：

1. `res.manifest` 拼进 `sec_epub.lua:buildContentOpf` 的 `<manifest>`。
   **注意现在 OPF 是 `version="2.0"`，不要加 `properties="svg"` 这类 EPUB 3 属性**，
   加了反而不合法。
2. 图片用 `epub:addPath("OEBPS/images", work_dir .. "/images", true, mtime)` 进包。
   `ffi/archiver` **没有** `addFileFromFile`，只有 `addFileFromMemory` 和 `addPath`；
   `addPath` 是按块流式读写（不整份读进内存），正好合适。`recursive=true` 才能覆盖
   `images/<namespace>/` 子目录。
3. 章节说明那句「本份原文含 N 张图片」要改掉 —— 现在图片真的进来了。
   （`sec_job.lua` 的 note 生成处。）

### `namespace` 不是可选项

本插件把 **7 家公司多份 filing 打进同一个 epub**，全文只有一个 `content.html` 和一个
`content.opf`。如果每份 filing 都从 `img001` 开始：

- 后面的图会覆盖前面的（同名文件）；
- OPF 里会出现重复的 `<item id="img001">`，XML 直接不合法。

所以 `namespace` 会被拼进**目录层级**和 **XML id**：
`images/<ns>/img001.jpg` + `id="<ns>-img001"`。`safeNamespace()` 会把非
`[A-Za-z0-9_-]` 的字符换成 `-`，并在以数字开头时补一个 `n`（XML 的 NCName 不能以数字开头）。

### 内存实测（这是本轮最关心的一项）

| 时刻 | 本进程峰值 RSS（`getrusage(RUSAGE_SELF)`，不含子进程） |
| --- | --- |
| 跑完 `cleanHtml`（已加载整个 `sec_source.lua` + 34KB 输入） | 2.64 – 2.70 MB |
| 再下完 22 张图（图片共 1.73 MB）之后 | 3.50 MB |
| **图片阶段带来的增量** | **0.80 – 0.86 MB** |

（区间来自多次复跑；差 60 KB 是分配器的噪声。）

增量不到 1 MB，而流经的图片是 1.73 MB —— 增量**小于**图片总量，说明图片没有在内存里堆积
（是边下边写盘）。如果实现成「先全部收进内存再一起写」，这里应该看到 1.73 MB 以上的增量。

**一个必须澄清的数字**：本轮 E2E 用 `/usr/bin/time -l` 跑出来
`maximum resident set size = 90,275,840`（86 MB）。这个数**不是 `sec_images.lua` 的**。
macOS 的 `time -l` 把「被等待过的子进程」也算进去，而本机测试替身每张图要 fork 一个 curl、
还要跑 `qlmanage` 渲染。逐个单独量：

```
单个 curl（下 1 张图）  :  7,733,248 字节（ 7.4 MB）
8 次 curl 串行后        :  7,782,400 字节（ 7.4 MB）
44 次 md5 串行后        :  2,129,920 字节（ 2.0 MB）
qlmanage 单独渲染一次    : 90,619,904 字节（86.4 MB）  <-- 就是它
```

`qlmanage` 单跑就是 90.6 MB，与整轮的 86 MB 基本一致。设备上没有 `qlmanage`，也不会
fork `curl`（用的是 LuaSocket 进程内连接）。证据：
`evidence/images_real/memory_control.txt`。

「边下边写盘」的直接证据（sink 探针，来自 `ltn12.sink.file` 的写入路径）：

```
第 1 次 sink 调用：本次 16384 字节，文件此刻 16384 字节
第 2 次 sink 调用：本次 10364 字节，文件此刻 26748 字节   <- 文件已经落地 26748 了
第 3 次 sink 调用：本次 16384 字节，文件此刻 16384 字节   <- 下一张图，重新开始
…
共 125 次 sink 调用（22 张图）
```

### 抓取统计（真实数据）

| 项 | 值 |
| --- | --- |
| 张数 | 22 成功 / 0 失败 |
| 总字节 | 1,808,803（1.73 MB） |
| 单张最大 | 169,424（img007） |
| 尺寸 | 全部 1200×675 |
| HTTP 请求 | 22 次 |
| 墙钟耗时 | 约 24.3 秒（含 21 × 120ms 节流 ≈ 2.5 秒） |
| 降采样 | `downscale_skipped_small = 22`（全部已 ≤ 1200px，**一步都没做**） |

**耗时不能当真机参考。** 24 秒里含了本机替身每张图 fork 一次 curl（进程启动 + TLS 握手）
的开销；设备上用 LuaSocket 是进程内连接，同一个 accessor 目录还能省掉一次 DNS。
但**节流 120ms 是真的**：SEC 的公平访问上限约 10 请求/秒，图片小、回得快，
22 张不节流会在两三秒内全部打完。`throttle_ms` 默认 120（≈8/秒），可以调。

### 高分屏图片会不会很糟？—— 有可用降采样途径，实测在本语料上不需要

**结论 1：设备上确实有可用的图片降采样途径，而且是 KOReader 自己的生产链路。**
（KOReader v2026.07.2，全部不依赖 `ui/*`）

| 步骤 | 接口 | 底层 |
| --- | --- | --- |
| 解码 | `ffi/pic` 的 `Pic.openDocument(path)`（按扩展名分派 jpg/png/gif/webp），`doc.image_bb` 就是 BlitBuffer | turbojpeg / lodepng |
| 缩放 | `ffi/mupdf` 的 `Mupdf.scaleBlitBuffer(bb, w, h)`（双线性） | MuPDF |
| 编码 | `BlitBuffer:writeJPG(path, quality)` / `writePNG(path)` | turbojpeg / lodepng |

证据不是推测：`frontend/ui/renderimage.lua:renderJpegImageDataWithTurboJpeg()` 走的就是
「`Pic.openJPGDocumentFromData` → `scaleBlitBuffer` → BlitBuffer」，而
`scaleBlitBuffer` 里写得很清楚：

```lua
if G_reader_settings:isTrue("legacy_image_scaling") then
    -- Uses "simple nearest neighbour scaling"
    scaled_bb = bb:scale(width, height)
else
    -- Better quality scaling with MuPDF
    scaled_bb = Mupdf.scaleBlitBuffer(bb, width, height)
end
```

`ffi/blitbuffer.lua:1441` 的 `scale()` 注释也自称 `uses very simple nearest neighbour scaling`。
**这意味着如果只用 `BlitBuffer:scale()`，文字密集的幻灯片会有锯齿**，所以
`downscaleFile()` 优先走 MuPDF，只有它不可用才退回最近邻。

`thirdparty/` 下确有 `libjpeg-turbo` 与 `lodepng`，`ffi.loadlib("turbojpeg", …)` /
`ffi.loadlib("lodepng")` 在设备上有实体可加载。

**结论 2：这一步已经实现（默认开），但在真实 SEC 语料上基本不会触发。**

`SecImages:downscaleFile()` 的行为：只有当解码后的**宽度 > `max_width`（默认 1200）**
时才做「解码 → 缩放 → 重新编码」；否则在拿到尺寸后立刻返回 `already-small`，
不动一个像素、也不白损失一次 JPEG 重编码的质量。产出还会做格式与尺寸复核，
任何一步失败都**保留原图**（图不能因为「优化」而消失）。

触发不了，是因为 SEC 的图片本来就小。抽样 7 家公司最近的 filing，取 16 张能解出宽高的图：

```
宽度分布: [190, 363, 450, 545, 672, 790, 920, 1200]
宽度 >1200 的: 0 张
最大宽度: 1200
```

（`evidence/images_real/image_width_survey.txt`）
微软那份 22 张幻灯片也全是 1200×675。**1200 这个阈值恰好卡在 SEC 的实际宽度上限上**，
所以默认开是安全的：能缩的会缩，能缩的目前一张都没有。

**结论 3：本机无法执行验证降采样代码本身。** 本机没有 `koreader-base` 的运行库，
`ffi/pic` / `ffi/mupdf` 的 C 库不存在，所以 `downscaleFile()` 在本机一律以
`no-library` 优雅跳过（计数在 `stats.downscale_unsupported`）。
也就是说「设备上真的能缩」这个结论目前**只建立在源码与生产用法上，没有在设备上跑过**。
上设备后需要补的验证：找一张宽度 >1200 的图（或人为把阈值调小到 600）跑一次，
确认 `stats.downscaled > 0` 且产出的图能正常显示。

**结论 4：万一张真是高分屏的，原样嵌进去的后果是什么。**

以 3000×1688 的 slide 为例（算术，不是实测）：

- **显示质量没有收益。** Paperwhite 5 屏宽 1236px、正文栏约 1198px，`sec_epub.lua` 的
  样式表已经有 `img { max-width: 100% }`，crengine 会把图缩到栏宽再画。多出来的
  124% 像素在屏上一个都用不到。
- **也没有「放大看」这条路。** EPUB 里的行内图片在 KOReader 里没有进入 `ImageViewer`
  的入口（那是封面/独立图片的路子），所以那些像素在电子书上永远看不到。
- **解码内存按像素数走。** crengine 取图后要用一张完整位图，3000×1688 若按 3 字节/像素
  算是约 15.2 MB，灰度是 5.1 MB —— 而整份 10-K 解析的峰值已经测到 115 MB。
  一本里多几张这种图，内存压力是实打实的。
- **体积线性增长。** 同一份语料里 1200×675 的 slide 在 17 KB – 169 KB 之间；
  像素数翻 6 倍，JPEG 体积大致也在同一个量级上翻。
- **唯一能救回来的**是渲染时把 KOReader 的「图片缩放」设成 `best`（双线性），
  但那只解决观感，不解决体积和内存。

所以默认就缩是对的。真要保留原图，设 `opts.downscale = false`。

### 这一轮踩到并修掉的坑（按危险程度排序）

**1. `ltn12.sink.file` 会自己关文件句柄，再 close 一次是抛错不是返回 nil。**

这是最危险的一个：LuaSocket 的 `receivebody` 用 `ltn12.pump.all`，而 `pump.step` 在源读完时
会调 `snk(nil, nil)` → `sink.file` 里的 `handle:close()` 被执行。之后代码里那句
`fh:close()` 对**已关闭**的文件句柄在 Lua 里是 `error("attempt to use a closed file")`，
不是安静地返回 nil。**不加判断，第一张图就会崩** —— 在设备上表现为整个插件挂掉。
修法：包一层 sink 记下「是不是被 sink 自己关过」，只在没关过时由我们关
（`SecImages.defaultFetch` 里的 `sink_closed`）。

顺带说：这个问题是本机替身测出来的 —— 替身里那份 `ltn12.sink.file` 是照抄上游实现的，
所以行为与设备一致。这一条如果只靠「读代码看起来没问题」是发现不了的。

**2. 半截文件必须删掉。** 网络中断时 `curl`/LuaSocket 都会留下一个不完整的文件。
留着它就会被当成「下载成功」写进 zip，在书里就是一张破图 —— 比直接跳过更难查。
`defaultFetch` 在每次失败后 `os.remove(dst)`；单元测试覆盖了这条。

**3. 属性解析里的两个下标错误（无引号属性、跳过空白）。**
`string.find` 返回的是**起止两个**下标，无引号值那里只取了第一个当终点用，
结果 `src=x.png` 解析出来的值是空串，还把 `x.png` 当成了一个新属性名。
另一个是 `local sp = body:find("^%s+", pos); if sp then pos = sp end`
—— `sp` 是起点，等于没前进。两个都修了，`work/images_unit.lua` 里各有一条用例盯着。

**4. 前缀判断写成了 6 个字符。** `low:sub(1,6) == "data:"` 拿到的是 `"data:i"`，
永远为假 —— 于是 `data:` URI 会被当作相对路径拼接成一个荒唐的 URL 去下载。
`data:` / `blob:` 是 5 个字符、`mailto:` 7 个、`javascript:` 11 个。单元测试里
每一条都有对应用例（这几条就是写测试时才发现的）。

**5. 输出里的占位标记不能外泄。**
本模块是「先扫描把 `<img>` 换成 `\1SECIMG:imgNNN\1` 占位、下载后再替换」。
原因是内部路径的扩展名要等下载后按魔数才能定。好处是不必回改全文、
也不必担心误伤正文里长得像的字符串。代价是**一旦中途出问题就可能把 `\1` 漏进正文**，
所以 `finalize()` 之后必须整体验一遍「输出里没有 `\1`」（E2E 与单测都查了）。

### 有意做出的、需要用户知道的取舍

1. **默认只抓 `sec.gov` 域下的图片**（`opts.allow_external_images = true` 可放开）。
   `src` 来自第三方文档内容，放行任意域名等于让 SEC 文档里的一个 URL 指挥我们去访问
   外部主机（跟踪像素、内网探测都属于这一类）。实测 SEC 归档里的图片本来就都在
   `sec.gov` 下，所以这个限制在真实语料上没有代价；被跳过的域名会写进 `res.log`。
2. **`srcset` / `data-src` 只删不认。** 留着就是一串指向外网的绝对 URL 躺在 epub 里，
   离线阅读器可能去访问。SEC 文件里极罕见（目标那份一个都没有），跳过的次数会记进
   `stats.srcset_removed` 与 `res.log`。
3. **`data:` URI 内嵌图片被跳过**（本轮不做 base64 解码），记进 `stats.skipped_data_uri`。
4. **媒体类型以文件内容为准**，不信 URL 扩展名。SEC 上有过 `.jpg` 里装 PNG 的情况；
   `sniff()` 用魔数判定，扩展名不符时会改名并写一条 log。
   文件名与内容不符的用例在单测里。
5. **`<img>` 缺失 `alt` 时补 `alt=""`**（空 alt 是「装饰性图片」的标准写法），
   补了几张会记进 `stats.alt_added`。目标那份 22 张都自带 `alt="Slide N"`。
6. **抓失败的图在正文里留 `<span class="secimg-missing">原 alt 文字</span>`**，
   不留指向不存在文件的破图引用。`sec_epub.lua` 的样式表里还没有这个类，
   建议加一条（例如 `span.secimg-missing { color: #777; font-size: 0.85em; }`），
   不加也能正常显示，只是没有视觉区分。
7. **越权不复用 `sec_source.fetch`**：本模块自己写了一份 `defaultFetch`
   （3 次重试、超时 120 秒、4xx 不重试、失败删半截文件），另外多了一个
   `opts.fetch(url, dst_path, opts)` 注入点，供无头测试替换传输层。

### 需要主会话注意的集成顺序

`sec_source.lua:cleanHtml` 的第 6 步现在是「把 `<img>` 整个删掉、只回报数量」。
接线时这一步要去掉（改成只计数），并且**要在第 9.5 步 `stripPresentation` 之后**再把
HTML 交给 `sec_images.lua`：`stripPresentation` 的属性白名单里已经保留了
`src` 与 `alt`（只留这两个），所以清理后的 `<img>` 正好是本模块期望的输入形态。

清理后的 `<img>` 实测长这样（注意**没有**自闭合斜杠 —— 本机 `libs/libkoreader-cre`
是桩所以没补；设备上 cre 会补上 `/>`，`stripPresentation` 会保留它）：

```
<img src="g291965ex99_1s1g1.jpg" alt="Slide 1">
```

`rebuildImgTag()` 总是输出自闭合的 `<img .../>`，所以两种输入都能处理，
顺带还修正了「XHTML 里 `<img>` 必须自闭合」这件事。

### 证据清单

| 文件 | 内容 |
| --- | --- |
| `sec_epub/sec_images.lua` | 新模块（1220 行，纯逻辑） |
| `sec_epub/work/images_unit.lua` | 纯逻辑自检，**84 项全通过**（URL 解析 / 属性大小写 / 魔数 / 去重 / 失败分支 / OPF） |
| `sec_epub/work/images_e2e.lua` | 端到端：真实 HTML → 真实清理 → 真实下载 22 张 |
| `evidence/images_real/unit_test.txt` | 单测输出（`UNIT OK`） |
| `evidence/images_real/e2e.log` | E2E 完整输出（`E2E OK`） |
| `evidence/images_real/01_raw_input.htm` | 从 SEC 下的原文（34,300 字节） |
| `evidence/images_real/02_cleaned_with_imgs.html` | 跑完真实 `cleanHtml` 的结果（26,642 字符，22 个 `<img>` 还在） |
| `evidence/images_real/03_rewritten.html` | 本模块重写后、可直接渲染的 HTML |
| `evidence/images_real/images/<ns>/img001-022.jpg` | **22 张图原件**（与 SEC 逐张 md5 一致） |
| `evidence/images_real/entries_and_manifest.txt` | 条目清单 + OPF manifest 片段 + stats |
| `evidence/images_real/zip_check.txt` | 用 arcname 真的组了个 zip 并 `unzip -l` 验证（25 条目 = 1,808,803 字节，与 stats 一致） |
| `evidence/images_real/render_out1/…png` | 重写后 HTML 的渲染图（就是那份 exhibit 的首页） |
| `evidence/images_real/render_out3/…png` | **22 张接触印相**：一屏看完 22 张 slide，逐张可辨 |
| `evidence/images_real/memory.txt` / `memory_control.txt` | 内存实测 + `time -l` 90MB 归属的控制实验 |
| `evidence/images_real/image_width_survey.txt` | SEC 图片宽度抽样（16 张，最大 1200） |
| `evidence/images_real/failtest_rewritten.html` | 真实 404 时的重写结果（留下 alt 文字、正文无损） |

可复跑：

```bash
cd <sec_epub>
luajit work/images_unit.lua                                              # 84 项纯逻辑自检
/usr/bin/time -l luajit work/images_e2e.lua | tee evidence/images_real/e2e.log
```

### 遗留问题

1. **降采样代码在设备上没有实跑过**（本机没有 koreader-base 运行库）。
   源码与生产用法都对得上，但这是「没验过」，不是「验过」。
   补验方法见结论 3。
2. **`addPath` 的 `recursive=true` 分支没有在真机上验证过**。
   本机只有 system `zip` 的等价验证（`zip_check.txt`），KOReader 那条路是
   `ffi/archiver` + libarchive，行为已按源码核对（`entry_path = entry_root .. "/" ..
   path:sub(#root+2)`），但没跑过。
3. **没做整本 EPUB 的组装验证**：`content.opf` 里插入 manifest 片段、
   `addPath` 进包、然后用 KOReader 打开 —— 这一步要等主会话接线后才能做。
   本轮只到「条目清单 + OPF 片段 + 图片文件」为止。
4. **耗时数字不代表真机**（见上文）。真机上应该复测一次，再决定 `throttle_ms` 要不要调。
5. **超大图的单张解码内存没有实测上限**：`ffi/pic` 的 `openDocument` 会把整个文件先读成
   Lua 字符串（`fh:read("*a")`），所以单张图的上限就是「一张图的大小」。
   目前语料里最大 169 KB，可以忽略；真遇到几十 MB 的图，那一次解码仍是几十 MB 的瞬时占用。
   没有为此设体积上限（用户已明确决定不设），但这一点要知道。

---

## 追加五（2026-10-07）：每本书开头的「关键指标」章节 —— `sec_metrics.lua`

> 这一节与上面的「追加四（关注列表）」和「图片抓取」是**并行交付的独立模块**，
> 各自只新增一个文件，都不改动 `main.lua` / `sec_job.lua` / `sec_epub.lua` / `sec_source.lua`。
> 集成由主会话统一做。本节的编号只为区分来源，与那两节没有先后关系。

### 目标

原始报表已经能读了（按列投影拆表），但读者仍要在几十张表里翻找数字，而 SEC 自己就把
这些数字做成了结构化数据。于是在每本书**开头**加一章干净的指标对照，原始报表原样留在后面
作为查阅依据 —— 这一章一个字节都没有改动原文。

### 交付物

| 文件 | 状态 | 说明 |
| --- | --- | --- |
| `sec_epub/sec_metrics.lua` | 新增，1212 行 / 55 KB | 纯逻辑模块：取数 + 解析 + 生成 XHTML 片段 |
| `sec_epub/work/metrics_run.lua` | 新增 | 本机 LuaJIT 的无头 harness（桩掉 json/logger） |
| `sec_epub/work/metrics_fetch.sh` | 新增 | 用 curl 抓 14 个 concept 到本地缓存（可复跑的取数） |
| `sec_epub/work/metrics_unit.lua` | 新增 | 62 项单元断言 |
| `sec_epub/work/metrics_crosscheck.py` | 新增 | 独立复核：逐格 / 溯源 / 表现层 / 溢出 / 语义自洽 |
| `sec_epub/work/metrics_mutation_test.sh` | 新增 | 复核脚本的灵敏度测试（注入 5 类错误） |
| `sec_epub/work/metrics_consistency_check.{sh,py}` | 新增 | 一致性抽查（回原始 filing 逐列比对） |
| `sec_epub/work/metrics_shot.py` | 新增 | 在真机等价宽度 408px 下渲染成 PNG |
| `sec_epub/work/metrics_memory.sh` | 新增 | 内存与耗时实测 |
| `sec_epub/work/metrics_verify_all.sh` | 新增 | 一键复跑上面全部步骤 |
| `evidence/metrics_<公司>.xhtml` ×7 | 证据 | 7 家公司章节的真实产物 |
| `evidence/metrics_<公司>.txt` ×7 | 证据 | 每家一份人读报告（选了哪个 tag、为什么、哪些期间） |
| `evidence/metrics_all.txt`、`metrics_summary.json` | 证据 | 7 家总报告 + 机器可读明细（含每行的 accn 与 filing URL） |
| `evidence/metrics_crosscheck.txt`、`metrics_mutation.txt` | 证据 | 独立复核结果、复核脚本灵敏度 |
| `evidence/metrics_consistency.txt`、`metrics_consistency/` | 证据 | 一致性抽查（含原始 10-Q 副本） |
| `evidence/metrics_memory.txt`、`metrics_unit.txt` | 证据 | 内存/耗时实测、单元测试输出 |
| `evidence/metrics_render/` | 证据 | 7 张 408px 全章渲染图 + 7 张 qlmanage 缩略图 |

### 对外接口（`sec_metrics.lua`）

```lua
local SecMetrics = require("sec_metrics")   -- 只 require json / logger，不 require 任何 ui/*

-- 1) 联网取数（14 个请求）→ 解析 → 返回一个纯数据表
local ok, data, err = SecMetrics.collectConcepts(
    { cik = 1318605, name = "特斯拉" },
    { user_agent = SecSource.user_agent },              -- 必填，UA 必须带邮箱，否则 403
    function(msg) return true end)                      -- 进度回调，返回 false 表示取消
-- ok=false 时 err 是原因（缺 UA / 网络失败 / 被取消）

-- 2) 组件 XHTML 片段（不含 <html>/<body>，可直接放进章节的 html 字段）
local ok2, xhtml, err2 = SecMetrics.buildChapter(
    { cik = 1318605, name = "特斯拉" }, data,
    { quarters = 8, cumulative = 6, instant = 8, min_metrics = 1 })

-- 3) 机器可读报告（排查「为什么选了这个 tag」、给验收脚本用）
local rep = SecMetrics.summary({ cik = 1318605, name = "特斯拉" }, data, {})
```

* 只有 `data.raw`（`{ [tag] = decoded_json }`）时也能调 `buildChapter`，它会自己解析 —— 离线测试方便。
* 错误一律走返回值，不用 `pcall` 包任何可能 yield 的东西，不用 `error()` 跨层传播；
  循环变量全部显式命名（`for _mi, x in ...`），避免遮蔽 gettext 的 `_`。
* 返回值与错误：`(true, xhtml)` / `(false, nil, "原因")`；单个指标取不到**不是**错误。

### 取数用哪个接口（实测）

用 **按概念逐个取** 的 `https://data.sec.gov/api/xbrl/companyconcept/CIK##########/us-gaap/<Tag>.json`。

| 方案 | 每家传输量 | 解码后内存 | 请求数 |
| --- | --- | --- | --- |
| 本模块（14 个 concept） | **159–323 KB** | Lua 堆峰值 **1.2–2.5 MB** | 14（每个几 KB–61 KB） |
| `companyfacts`（一次给全部指标） | 2.6–4.7 MB | 解码净增 **6.19 MB**（实测最大一份） | 1 |

`companyfacts` 的体积不像传说的「几十 MB」，7 家实测 2.62–4.66 MB；但它给的是**全部**标签
（我们只要 14 个），解码峰值堆要多花 6 MB 以上，而且单次请求要 3.3–4.7 秒。所以仍选
逐个取。原始数字见 `evidence/metrics_memory.txt`。

请求节奏：默认每次之间等 0.12 秒（SEC 软上限 10 次/秒）。本机实测 14 个请求
**11.1–13.7 秒**（网络主导），加上解析与生成总共不到 14 秒。

### 标签回退表（代码里的常量 `SecMetrics.METRICS`）

| 指标 | 口径 | 候选 tag（按顺序） | 7 家实测命中 |
| --- | --- | --- | --- |
| 营收 | 流量 | `RevenueFromContractWithCustomerExcludingAssessedTax` → `Revenues` → `SalesRevenueNet` | 首选 5 家；**英伟达、谷歌用第 2 位 `Revenues`**（见下） |
| 营业利润 | 流量 | `OperatingIncomeLoss` | 7/7 首选 |
| 净利润 | 流量 | `NetIncomeLoss` → `ProfitLoss`（含少数股东权益） | 7/7 首选 |
| 稀释每股收益 | 流量 | `EarningsPerShareDiluted` → `EarningsPerShareBasicAndDiluted` | 7/7 首选 |
| 经营现金流 | 流量 | `NetCashProvidedByUsedInOperatingActivities` → `...ContinuingOperations` | 7/7 首选 |
| 总资产 | 时点 | `Assets` | 7/7 首选 |
| 总负债 | 时点 | `Liabilities` | **6/7；亚马逊取不到**（见下） |
| 现金及等价物 | 时点 | `CashAndCashEquivalentsAtCarryingValue` → `CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents` | 7/7 首选 |

**选 tag 的规则**（可复现、能说出理由）：候选按声明顺序；能解析出期间的才算可用；
可用的候选里取**最新期间截止日最晚**的那个；并列时顺序在前的优先。

这条规则不是形式主义，实测直接改了结论：

* **英伟达**：首选 `RevenueFromContractWithCustomerExcludingAssessedTax` 只有
  2017-01-29 ~ 2022-01-30 的数据（28 条），而 `Revenues` 覆盖 2008-01-27 ~ 2026-07-26（280 条）。
  如果按「取到就停」的写法，英伟达的营收会停在 2022 年而**不报任何错**。
* **谷歌**：首选只到 2025-03-31，`Revenues` 到 2026-06-30 —— 同样必须用回退。
* **微软**：`Revenues` 只有 2007–2010，首选才是当期的 —— 这条规则也挡住了反向的错选。

**唯一取不到的**：亚马逊的**总负债**（`us-gaap:Liabilities` 返回 404）。
用 SEC 的 frames 接口独立交叉验证过：`CY2025Q4I`/`CY2026Q1I`/`CY2026Q2I` 三期分别有
5528 / 4976 / 4911 家实体申报了 `Liabilities`，其中 **AMAZON 出现 0 次** —— 亚马逊确实
从不申报这个标签，不是我们的请求出问题。章节里按「未取到」标注，并写明用过的候选 tag
与失败原因，**没有拿 `LiabilitiesAndStockholdersEquity` 之类的别的口径顶替**。

7 家公司 × 8 个指标 = 56 项，取到 **55 项**。

### 期间口径与「同一期间被申报多次」怎么取

* 期间按长度定性：约 3 个月 = 单季度、6 个月 = 半年、9 个月 = 前三季、12 个月 = 全年；
  非标准长度（财年变更的过渡期）单独一张表按实际天数标注。**不同长度绝不混在一列**：
  展示时按「单季度」与「累计（半年／前三季／全年）」分成两张表，另加时点表（资产负债类）。
* 取值规则：同一 `(start, end)` 期间有多条申报时，**一律取 `filed`（申报日）最新的一条**；
  `filed` 相同则取 accession 号大的（确定性，不依赖遍历顺序）。
* 实测:7 家合计折叠掉 **3331 组**重复申报；展示出来的 609 行里有 **8 行**被标了「*」
  （该期间的值被后来的申报改写过），每行都在表下写出两次的值与申报日。例子：

  > 特斯拉 2024-01-01 ~ 2024-03-31 的净利润，2024-04-24 的 10-Q 里是 **1,129,000,000**，
  > 2025-04-23 的 10-Q 里被写成 **1,390,000,000**。本模块取后者，并在行上标「*」。

  这条规则顺带解决了拆股：英伟达 10:1 拆股前的 EPS 是 44.15 这种量级，最新申报里是
  拆股后调整过的值 —— 取最新才让同一张表里的数字可比。

### 展示设计

每个指标 1–2 张 **窄表**（最多 3 列，远超项目 6 列的安全线），只用 `<table>/<tr>/<td>`
与内联 `text-align`，class 只用 `secmeta` / `secnote`（都在验收白名单里）：

```html
<p class="secmeta">营收 ｜ 单季度 ｜ 单位：百万美元 ｜ 数据来源 us-gaap 标签 RevenueFromContractWithCustomer<br/>ExcludingAssessedTax</p>
<table><tr><td>口径</td><td>报告期</td><td style="text-align:right">数值</td></tr>
<tr><td>2026 Q2</td><td>2026-04-01 ~ 2026-06-30</td><td style="text-align:right">28,236</td></tr>
…</table>
```

* 期间标「口径 + 报告期起止」；季度标签按**报告期截止日所属的自然季度**标（苹果的
  FY2026 Q1 截止 2025-12-27，标成 2025 Q4），章节开头写明了这条换算规则。
* 累计期间标「半年／前三季／全年 + 期止年-月」而不是「年」：实测亚马逊同一年里有不止一个
  12 个月期间（年初起的财年值 + 公司另行申报的 12 个月滚动值），只写年份会出现两个
  「2026 全年」，读者无法区分。检测到这种混排时表下会加一句提示。
* 金额单位：整张表按 `|值|` 的峰值决定用「百万美元」（保留 1 位，例如 `94,827`、`-639.6`）
  还是精确「美元」，单位写在表头。每股收益固定用「美元/股」，最多 4 位、至少 2 位小数。
* 每个指标都标了数据来源 tag；取了非首选 tag 时额外标出**口径提示**
  （例如「含受限现金」「含少数股东权益」）。

### 两个只有实测才会暴露的坑

1. **超长 tag 名会把段落撑出屏幕。** 实测把 epub 样式表套上后在真机等价宽度（408px 正文栏）
   下量：`us-gaap:CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents` 这种
   66 字符、不含空格与连字符的 token 会把段落撑到 **440px**（`scrollWidth` 实测 440/448，
   正文栏只有 408px），浏览器不会自己拆开一个超长单词 —— 在电子书上就是右边被切掉、
   而且没有任何报错。修法：在**驼峰处插 `<br/>`**，把每段压到 40 字符以内（40 字符 ≈ 20 em，
   正文栏约 30 em，留 1/3 余量），换行处不添加任何字符，所以标签名本身不变。
   复核脚本里有一条「不可断片段不得超过 40 字符」的检查守着它。
   踩坑记录：第一次写这条检查时用了 Lua 的 `[%!-~]`，而 `%!` 是转义、后面的 `-` 被当成
   字面量，集合退化成 `{! - ~}` 三个字符，于是「最长片段」永远是 1，检查形同虚设 ——
   改成 `[!-~]` 才真的开始抓到东西。

2. **现金流量表这类「按年初至今列示」的指标没有真正的单季值。** SEC 数据里特斯拉的经营
   现金流只有 `2026 Q1`、`2025 Q1`、`2024 Q1` 才有 3 个月的期间 —— 因为 Q1 的「年初至今」
   恰好等于单季。把这几行排进一张叫「单季度」的表，读者会以为它们是连续季度。
   现在的做法：**判据是「这些季度行里是否只有一种年内季度」。全是 Q1 就不上单季度表，
   改成一句说明并指向累计表**（实测 7 家里 6 家的经营现金流都命中这条，只有亚马逊和
   微软真的按季度申报现金流）。判据刻意**不**要求「相邻两期正好差一个季度」—— 10-K 只报
   全年，所以每年缺 Q4 是常态，那样会把正常数据也挡掉（我第一版就是这么写错的，
   结果 7 家的营收季度表全被吃掉）。

### 7 家公司的实测结果

| 公司 | 请求 | 收到 | 取到指标 | 章节片段 | 表数（单季/累计/时点） | 数据截至 |
| --- | --- | --- | --- | --- | --- | --- |
| 特斯拉 | 14 | 252 KB | 8/8 | 13.5 KB | 12（4/5/3） | 2026-07-23 |
| 英伟达 | 14 | 267 KB | 8/8 | 12.4 KB | 12（4/5/3） | 2026-08-26 |
| 苹果 | 14 | 292 KB | 8/8 | 13.3 KB | 12（4/5/3） | 2026-07-31 |
| 亚马逊 | 14 | 323 KB | **7/8** | 13.1 KB | 12（5/5/2） | 2026-07-31 |
| Meta | 14 | 208 KB | 8/8 | 12.2 KB | 12（4/5/3） | 2026-07-30 |
| 谷歌 | 14 | 159 KB | 8/8 | 12.0 KB | 12（4/5/3） | 2026-07-23 |
| 微软 | 14 | 315 KB | 8/8 | 12.9 KB | 13（5/5/3） | 2026-07-29 |

「数据截至」取数据里最新的一次申报日，而不是「今天」—— 设备时钟不可信。

### 验证（五层，全部可复跑：`bash work/metrics_verify_all.sh`）

1. **单元测试 62 项**（`work/metrics_unit.lua` → `evidence/metrics_unit.txt`，全过）：
   百万美元格式化的进位边界、每股收益小数位、期间定性（91/98/182/273/364/371 天）、
   闰年日期差、重复申报择一（取最新且标记改写）、空数据不生成章节、
   以及 `socket.http` 传输层的 404/500/网络错误分支（用桩，见「已知限制」）。
2. **独立复核**（`work/metrics_crosscheck.py` → `evidence/metrics_crosscheck.txt`）：
   期望值全部由 Python 从**原始 SEC 响应**重算（另写一遍格式化规则），与 XHTML 逐格比对；
   并做**溯源**：每一行的数字都要能在原始 JSON 里找到同 `(start, end, accn, val)` 的记录。
   7 家共 609 行，**逐格 0 处不符、溯源 609/609、表现层问题 0、不可断片段超长 0**。
3. **语义自洽**（同脚本）：连续两个季度之和 = 半年累计。核对 **58 组**，
   最大偏差 1,000,000 美元（这些公司按百万美元申报，各自独立四舍五入所致），
   超容差 0 组。这一条用财务恒等关系验证期间边界与列映射，比逐格比对更强。
4. **复核脚本的灵敏度**（`work/metrics_mutation_test.sh` → `evidence/metrics_mutation.txt`）：
   故意把某个数字改 1、给表头加一条非白名单 style、把两张表的表头互换、删掉一整行、
   把单位从「百万美元」改成「美元」—— 五类变异**全部被抓出**，跑完自动还原。
   一个「总是报 OK」的检查脚本等于没有检查，所以这步不能省。
5. **肉眼核对像素**：`evidence/metrics_render/*_408px.png`（7 张，Chrome 在真机等价宽度
   408px 下渲的全章图）+ `*.html.png`（qlmanage 缩略图，整页概览）。
   逐张看过：表格列没有串位、数字没有被折行、单位与口径标在表头、未取到的指标位置正确。

### 一致性抽查：回到原始 filing 对数字（8/8 对上）

抽查对象就是章节里标注的那份申报：**特斯拉 2026 Q2 的 10-Q**
（accession `0001628280-26-049270`，2026-07-23 提交）

* 归档目录 <https://www.sec.gov/Archives/edgar/data/1318605/000162828026049270/>
* 正文 <https://www.sec.gov/Archives/edgar/data/1318605/000162828026049270/tsla-20260630.htm>

| 指标 | 期间 | 章节显示 | 原文（Consolidated Statements of Operations / Balance Sheets） | 结论 |
| --- | --- | --- | --- | --- |
| 营收 | 2026 Q2 | 28,236 | `Total revenues 28,236 22,496 50,623 41,831` 第 1 列 | **对上了** |
| 营收 | 2025 Q2 | 22,496 | 同上第 2 列 | **对上了** |
| 营收 | 2026 半年 | 50,623 | 同上第 3 列 | **对上了** |
| 营收 | 2025 半年 | 41,831 | 同上第 4 列 | **对上了** |
| 总负债 | 2026-06-30 | 61,005 | `Total liabilities 61,005 54,941` 第 1 列 | **对上了** |
| 总负债 | 2025-12-31 | 54,941 | 同上第 2 列 | **对上了** |
| 总资产 | 2026-06-30 | 148,524 | `Total liabilities and equity $ 148,524 $ 137,806` 第 1 列 | **对上了** |
| 总资产 | 2025-12-31 | 137,806 | 同上第 2 列 | **对上了** |

原文标注 `(in millions, except per share data)`，与章节显示的「百万美元」是同一口径，
所以比对是字符串级的。**列序（哪一列是哪一年）也逐列核对过** —— 这一条专门防
「把去年同期的数字当成今年」。完整输出见 `evidence/metrics_consistency.txt`。

### 内存与耗时实测（`evidence/metrics_memory.txt`）

| 项目 | 数值 |
| --- | --- |
| 空 LuaJIT 进程峰值 RSS | 1.56 MB |
| 单家公司（离线）：Lua 堆采样峰值 | **1.2–2.5 MB** |
| 单家公司（离线）：进程峰值 RSS | 4.2–5.3 MB |
| 单家公司（直连 SEC 14 个请求，含 0.12s 间隔） | 墙钟 **11.1–13.7 s**，进程峰值 RSS 7.5 MB |
| 7 家一次跑完（harness 把 7 份报告都留在内存里，比真实集成更占内存） | 峰值 RSS 7.7 MB，堆采样峰值 2.0–3.2 MB |
| 对照：解一份最大的 `companyfacts` | 4.66 MB → 解码净增堆 **6.19 MB** |

结论：这一章的数据开销是**几 MB 级**，相对上一轮已经跑通的「8.6 MB 的 10-K 峰值 115 MB」
可以忽略；真正的成本是**网络耗时约 12 秒**（14 个请求），接进流程时应当给一句进度提示。

### 已知限制（如实记录）

1. **没有在设备上跑过**（本轮分工就是「不访问设备、不部署」）。模块是纯逻辑、只 require
   `json` + `logger`，本机验证用的是与设备同款的 LuaJIT 2.1；但真机集成后仍需复测一次。
2. **`socket.http` 那条传输路径没有真连网测过**：Mac 的 LuaJIT 没有 luasocket，
   所以真实网络走的是注入的 `opts.fetch`（curl）。设备上默认走 `SecMetrics.httpFetch`
   （LuaSocket），它的返回约定、404/500/网络错误分支、`TIMEOUT` 还原都用桩测过
   （12 项断言），实现方式与已在生产跑通的 `SecSource:fetch` 一致，但「真机真连」这一格是空的。
3. **只展示最近的期间**：季度 8 行、累计 6 行、时点 8 行、窗口 1100 天，都可通过 `opts` 调整；
   更深的历史没有列出来（原始报表本来就在书里）。
4. **12 个月滚动值可能与财年值同表**：亚马逊这类公司会在 10-Q 里另行申报「十二个月止于
   本季末」，它与年初起的财年值都是真值，都在表里，靠「期止年-月」标签区分，表下也有提示；
   但快速扫读的人仍可能混。
5. **金额显示为百万美元（保留 1 位）**，读数精度到 0.1 百万；精确到美元的原始值在数据里保留着
   （`metrics_summary.json` 里每行都有 `val` 与 `accn`），需要时可查。
6. **数值列的右对齐在「表格自动收窄到内容宽度」时看不出效果**：浏览器与 crengine 都会把
   最后一列压到刚好等于最宽内容，此时左对齐与右对齐的渲染结果一样。仍然保留
   `style="text-align:right"`（符合既有验收标准，且在列比内容宽时会生效）。
7. **只处理 `us-gaap` 分类法与 `USD` / `USD/shares` 单位**。若某家用别的单位（例如 EUR），
   模块不会硬套成美元：它会取实际存在的单位并把单位名写进表头。
8. **未接线**：`main.lua` / `sec_job.lua` / `sec_epub.lua` / `sec_source.lua` 一个字没改，
   集成（在哪一步调用、怎么把它插成第一章、进度提示文案）由主会话完成。
   建议：作为每本书的第一章、标题「关键指标」；取数失败时**跳过这一章继续做书**。

## 追加六（2026-10-07）：按公司 + 任意表格类型搜索 —— `sec_search.lua`

需求：现在只能下预先写死的 7 家公司的 8-K/10-K/10-Q。要能「输入公司代码或 SEC 编号，
看它都有哪些文件」，包括 13F-HR（机构持仓）、S-1（招股书）、DEF 14A（委托书）、
4（内部人交易）、SC 13D 之类。

新增一个纯逻辑模块 `sec_search.lua`（63416 字节），**没有改任何已有文件**，
集成由主会话完成。

### API

```
SecSearch:resolve(query, opts)      -> true, result | nil, err, err_kind
SecSearch:listFilings(cik, opts)    -> true, filings | nil, err, err_kind
SecSearch:cacheInfo(cache_dir)      -> true, info | nil, err       -- 设置页用，不联网
SecSearch:clearCache(cache_dir)     -> true, removed | nil, err    -- 设置页用
```

纯函数（点号调用，无状态无 IO）：`matchesForm` / `isAmendment` / `formSummary` /
`archiveDir` / `entryUrl`。

两类调用方式搞错了不会静默出错：需要状态的函数若被点号调用，会直接返回
「请用冒号调用：`SecSearch:resolve(...)`」。这是刻意加的 —— 否则 `self` 错位以后
报出来的会是「缺少 cache_dir」之类完全对不上的信息。

**`resolve` 的 result 字段**

| 字段 | 含义 |
| --- | --- |
| `query` | 去空白后的原始输入 |
| `cik` / `cik_num` | `"0000789019"` / `789019`（listFilings 收 `cik_num`） |
| `name` | 公司名，来自官方映射；按 CIK 查且映射里没有时为 `nil` |
| `ticker` | 代表 ticker，可能为 `nil` |
| `tickers` | 同一 CIK 的全部 ticker（Alphabet 4 个、Berkshire 2 个、美国银行 17 个） |
| `aliases` | **候选列表（含首选）**，可直接拿去渲染选择列表 |
| `ambiguous` / `tie` | 候选多于 1 个 / 首选与次选同分（后者必须让用户自己选） |
| `matched_by` | `"ticker"` / `"cik"` / `"name"` |
| `name_source` | `"index"` / `"submissions"` / `"unknown"` |
| `cache` | 命中情况：`hit` / `stale` / `degraded` / `age_seconds` / `refreshed` / `entries` |

**`listFilings` 的 filings 字段**

| 字段 | 含义 |
| --- | --- |
| `entries` | 文件数组，按日期倒序；每项 8 个字段（见下） |
| `total` | 扫到的记录数（未按表格类型过滤） |
| `matched` | entries 条数 |
| `truncated` | 是否被 `max_total` / `max_extra_files` / `limit` 截断（截断=会少文件） |
| `form_summary_all` | **扫到的全部表格类型的分布** `{{form=,count=},...}` |
| `form_summary_scope` | `full` / `since_window` / `partial`（分布覆盖到哪，别把它当全量） |
| `stats` | `sources_total/used/skipped/failed`、`duplicates_dropped`、`budget_full`、`stopped_by_since` |
| `source_errors` | 取不到的分片（单个分片失败不会让整张清单失败，但要如实记下） |

`entries` 每项的 8 个字段就是需求里点名的那些：`form`、`filing_date`、`report_date`、
`accession_number`、`primary_document`、`primary_doc_description`、`items`、`size`。

### 缓存落盘（要接进插件设置的部分）

调用方注入目录（本模块刻意不 `require("datastorage")`，那样就没法脱离设备测试）：

```lua
SecSearch.cache_dir = DataStorage:getDataDir() .. "/secfilings"
```

该目录下三个文件：

| 文件 | 内容 |
| --- | --- |
| `company_tickers.json` | SEC 原文，**字节等于服务器返回**（已用 sha256 核验），排障用 |
| `ticker_index.tsv` | 派生索引，`cik\tticker\ttitle\n` 逐行、按 (cik,ticker) 排序；resolve 实际读它 |
| `company_tickers.meta` | 逐行 `k=v`：`url` / `fetched_at` / `bytes` / `csum` / `count` / `index_bytes` / `index_csum` |

实测尺寸：原文 798727 字节、索引 382028 字节（10434 行）、meta 173 字节。

- 有效期 `SecSearch.ticker_ttl` 默认 7 天；`opts.refresh = true` 强制重取。
- 写入一律先写 `.tmp` 再 `rename`，且 **meta 最后写** —— meta 是「缓存已就绪」的标志，
  最后落地才不会出现「meta 说新鲜、索引却是半截」。FAT 上断电不会留下半成品被当成好缓存。
- 索引被写坏（行数与记录数不符、首末行解析不出来）会自动重取，不静默出错；
  `opts.verify_cache = true` 时连完整校验和一起验。
- 配置类错误（比如 UA 里没有邮箱）**不用旧缓存兜底**：它不会自己变好，静默降级只会
  让用户以为是网络问题。网络类错误才降级用旧缓存，并标 `stale = true` + `degraded = true`。
- 落盘失败只记警告、不影响本次结果（缓存是优化，不是正确性前提），错误写进 `cache.write_error`。
- `cache_dir` 落在系统分区（`/usr` `/proc` `/etc` `/var` …）或根目录会被**拒绝**：
  设备 rootfs 只剩约 11.7MB，缓存必须放 `/mnt/us` 下。

### 实测发现的 4 个坑（都已处理，改代码前先看这段）

1. **历史分片和主文件的 JSON 结构不一样。**
   主文件是 `{filings:{recent:{form:[...],...}}}`；分片 `submissions-00N.json` 却是
   **顶层对象本身就是那张列字典** `{form:[...],filingDate:[...],...}`，没有 `filings`/`recent`
   包装。按同一种结构解析分片只会拿到 `nil`，然后**静默**少掉一大半历史文件。
   处理点：`columnDict()`。
2. **分片 URL 必须用 JSON 里给的 `files[i].name` 拼**，不能自己按序号拼：
   实测 `.../CIK0000019617-submissions-000.json` 是 404，编号从 `001` 起。
   代码里还对 `name` 做了格式校验（`^CIK%d+%-submissions%-%d+%.json$`），不匹配就跳过并记录。
3. **巨头公司的清单非常大**，必须有上限，而且上限要按用户真正要的表格类型来花：

   | 公司 | 主文件 recent | 历史分片数 | 合计约 |
   | --- | --- | --- | --- |
   | JPMorgan (19617) | **26311 条**（4.43MB） | **70** | 168590 |
   | BlackRock (1364742) | 1088 | 22 | 48826 |
   | Vanguard (102909) | 3004 | 14 | 34335 |
   | 微软 (789019) | 1002 | 2 | 4525 |
   | 苹果 (320193) | 1000 | 1 | 2264 |

   所以 `listFilings` 是**边扫边筛**（`absorbColumns`）：先过 `form`/日期，只有要留下的
   才建完整记录。否则一次把两万多条 × 8 个字段全建出来，只为筛出 1 份 10-K。
4. **`company_tickers.json` 只收有股票代码的注册主体**（10434 家），
   而 SEC 的申报主体有几十万家（基金、机构、子公司都不在里面）。
   实测 Vanguard(102909)、BlackRock(1364742) 都不在这份映射里 —— 所以
   「按 CIK 解析」成功但 `name = nil` 是**正常情况**，不是错误；权威名称从提交索引取
   （`listFilings` 会返回 `name`，或 `resolve(..., {name_lookup=true})` 当场补）。

### 表格类型匹配（`matchesForm`，默认 boundary）

`boundary` = 完全相等，或后面紧跟 `/`、空格、`-`。实测效果：

| 想要的类型 | 命中 | 不命中 |
| --- | --- | --- |
| `10-K` | `10-K`、`10-K/A` | `10-K405` |
| `4` | `4`、`4/A` | `40-F`、`424B2`、`425` |
| `S-1` | `S-1`、`S-1/A` | `S-11` |
| `DEF` | `DEF 14A` | `DEFR14A` |
| `13F-HR` | `13F-HR`、`13F-HR/A` | — |

默认必须是 boundary：25 个边界用例已经固定成回归测试（见阶段 7 的 24 条 + 下面这条）。
用 `prefix` 模式的话，用户筛 `4`（内部人交易，最常见类型之一）会连 `40-F`/`424B2`/`425`/`497`
一起捞出来。修正件（`/A`）另由 `opts.amendments` 控制：`true`（默认含）/ `false`（排除）/
`"only"`（只要）。

### 真实数据验证（73 项断言全过 + Python 独立逐格比对）

复跑命令（在 `sec_epub/` 下）：

```bash
/opt/homebrew/bin/luajit work/sec_search_test.lua > evidence/search_run.txt 2>&1   # 73 项
python3 work/verify_search.py 2>&1 | tee evidence/search_verify.txt                 # 8 项
```

1. **定位**：`MSFT` / `msft` / `"  MSFT  "` / `789019` / `0000789019` / `CIK0000789019` /
   `tesla` / `alphabet` / `microsoft` / `MICROSOFT CORP` / `BRK.B` / `brk-b` 全部正确
   （`BRK.B`、`brk-b` 都能命中 SEC 的 `BRK-B`）。
2. **模糊输入返回多个候选**（`resolve("apple")` 实测 6 个，首选 Apple Inc.）：

   | # | 分数 | ticker | 公司名 | CIK |
   | --- | --- | --- | --- | --- |
   | 1 | 800 | AAPL | Apple Inc. | 320193 |
   | 2 | 800 | AAPI | Apple iSports Group, Inc. | 1134982 |
   | 3 | 800 | APLE | Apple Hospitality REIT, Inc. | 1418121 |
   | 4 | 400 | PAPL | Pineapple Financial Inc. | 1938109 |
   | 5 | 400 | MLP | MAUI LAND & PINEAPPLE CO INC | 63330 |
   | 6 | 400 | PNXP | PINEAPPLE EXPRESS CANNABIS Co | 1710495 |

   前 3 个同分 → `tie = true`，界面必须让用户选，不能替他猜。
3. **不存在的输入**：`resolve("ZZZZZZ")` / `resolve("qwertyuiopasdfg")` → `ok=nil`、
   `kind="no_match"`、err 是中文可读串；`resolve("微软")`（非 ASCII）同样返回 no_match
   而不是报错或乱码。
4. **全部表格类型分布**（`form_summary_all`）：
   - Meta(1326801)：合并 3 个数据源共 **4196 条、47 种**表格类型 ——
     `4`×3034、`144`×582、`8-K`×131、`PX14A6G`×65、`3`×61、`10-Q`×43、`SC 13G/A`×40、
     `CORRESP`×22、`UPLOAD`×21、`4/A`×20、`DEFA14A`×18、`5`×15、`10-K`×14、`DEF 14A`×14、
     `S-8`×10、`SD`×10、`S-1`×1 …
   - 微软(789019)：**4525 条、62 种** —— `4`×3095、`8-K`×281、`5`×107、`10-Q`×98、
     `11-K`×84、`SC 13G/A`×80、`3`×61、`DEFA14A`×47、`10-K`×33 …
5. **非财报类型实际结果** `forms={"13F-HR","S-1","DEF 14A"}`：
   - Berkshire(1067983)：扫 2403 条 → 命中 **240 条**（`13F-HR`×111、`13F-HR/A`×100、
     `DEF 14A`×29），最早一条 **1999-03-19** 的 DEF 14A —— 说明历史分片真的合并进来了。
   - Meta：`forms={"S-1"}` → **9 条**，正是 2012 年 IPO 那批（1 份 S-1 + 8 份 S-1/A，
     2012-02-01 起）。
   - 微软：`forms={"13F-HR"}` → `ok=true`、`matched=0`、空列表（**不是错误**）。
6. **修正件三种模式**（苹果 10-K）：全部 32 条（30 + 2 个 `/A`）；`amendments=false` → 30 条
   且不含 `/A`；`amendments="only"` → 2 条全是 `/A`。
7. **排序**：苹果 10-K/10-Q 共 132 条，首条 2026-07-31、末条 **1994-01-26**，严格日期倒序。
8. **缓存耗时**（`evidence/search_run.txt` 里那一次）：冷启动 `resolve("MSFT")` **1.624 秒**
   （下载 798727 字节 + 解析 + 建索引 + 写三个文件）；热缓存 **0.127 秒**（**12.7 倍**）；
   `refresh=true` 1.584 秒。两次独立运行的区间：冷 1.6–1.9 秒、热 0.13 秒 —— 具体值每次
   略有浮动，以存下来的日志为准（结论不变：热缓存稳定在冷启动的 1/12 左右）。
9. **截断行为**：JPMorgan `forms={"10-K"}, max_extra_files=3` → 命中 1 条、
   `truncated=true`、`sources_skipped=67`（共 71 个数据源），且**没有**把 10-K 挤掉；
   加 `since="2026-06-01"` 后 → 只拉主文件就收工（`stopped_by_since=true`、
   `sources_skipped=70`、`truncated=false`、`form_summary_scope="since_window"`）。
   注意这里刻意**不**把「按用户要求收敛」误报成截断。
10. **网络故障**（用注入 `opts.fetch` 精确制造）：映射一直 403 → 有旧缓存时降级并标
    `stale/degraded`，无缓存时如实报 `ratelimit`（各重试 3 次）；前两次网络错误第三次成功
    → 真救回来（断言刻意同时验「真的走了网络」，否则「重试全失败→降级用缓存」也会让
    `ok=true`，把失败误判成成功）；SEC 回 HTML 错误页 / 半截 JSON / 结构不符 → 都是
    `kind="json"` 的可读报错而不是抛异常；CIK 不存在 → `notfound` 且不重试；
    2 个分片坏 1 个 → 仍拿到 2523 条，`source_errors` 记 1 条，`truncated=true`。
11. **内存水位**（JPMorgan 26311 条，最大单响应 4.43MB）：解码期间采样峰值 **13.7 MB**，
    调用返回后仍被持有 **10.3 MB**（两次运行分别是 13.7 / 13.8 MB）。参考：微软 10-K 清理时
    测到过 115MB 峰值（见「追加」一节），同一台设备能承受这个量级。

### 无损证明（这个项目的硬要求）

`work/verify_search.py` 用 Python **独立实现**同一套解析，与 Lua 的输出逐字节比对，8 项全过：

| 比对 | 结果 |
| --- | --- |
| 缓存里的原文 vs 现在重新 curl 下载 | 798727 字节完全相同，sha256 `eb943bdc…` |
| Python 重建的 ticker 索引 vs Lua 的索引 | 382028 字节**逐字节相同**（10434 条记录无损） |
| Python 合并的微软全量清单 vs Lua 导出的 | 4525 行 **× 8 字段逐格相同**，sha256 `599f2d86…` |
| 字段里是否混入制表符/换行 | 0 条（说明 TSV 导出格式本身可靠） |

原始响应留存在 `work/sec_search_raw/`（16 个真实 JSON，含 4.43MB 的 JPMorgan 主文件），
Python 侧读的就是 Lua 侧同一批字节，所以这个比对不是「两边各抓一次再比」。

### 边界情况清单

| 情况 | 返回 |
| --- | --- |
| 公司名/ticker 一个都匹配不上 | `nil, "没有找到匹配的公司：X（ticker、CIK 或公司名片段都可以）", "no_match"` |
| 查询为空 / 不是字符串 | `nil, …, "config"` |
| 缺 `user_agent`、或 UA 里没有邮箱 | `nil, …, "config"`（提前拦，不等 SEC 回 403） |
| 缺 `cache_dir` | `nil, …, "config"`（避免每次重下 780KB） |
| 映射里没有的 CIK（如 Vanguard 102909） | `ok=true`，`name=nil`、`cik` 正确、`name_source="unknown"` |
| 公司没有该表格类型 | `ok=true`、`entries={}`、`matched=0`（**不是错误**） |
| `since` 之后没有任何申报 | `ok=true`、`matched=0` |
| CIK 不存在 | `nil, "SEC 没有 CIK … 的提交索引（这个编号不存在）", "notfound"`（不重试） |
| 网络重试后仍失败 | `nil, …, "net"` |
| 被 SEC 限流（403/429） | 退避重试 3 次后 `nil, …, "ratelimit"`；有旧缓存则降级且标 `stale` |
| 响应不是 JSON / 解析不了 / 结构不符 | `nil, …, "json"`（可读报错，不抛异常） |
| 单个历史分片失败 | 整张清单仍可用，`source_errors` 记下，`truncated=true`、`form_summary_scope="partial"` |
| 非法日期 / `forms` 类型不对 / CIK 传公司名 | `nil, …, "config"` |
| `cache_dir` 在系统分区 | `nil, …, "config"`（保护 11.7MB 的 rootfs） |

### 这一轮自己踩到并修掉的（都留着回归测试）

1. **`opts.amendments = false` 被静默忽略**：`(x ~= nil) and x or true` 在 Lua 里
   `true and false or true` = `true`（`false` 是假值）。表现是「要求排除修正件，`10-K/A` 还在」。
   测试里那条 `amendments=false 里不再出现 /A` 抓出来的。
2. **`"^/(usr|proc|…)"` 这类守卫从来没生效过**：Lua 模式**没有** `|` 交替运算符，
   它会把 `usr|proc|…` 当成字面量字符串。改成「取顶级目录名再查表」。
   是「应当拒绝却没拒绝」的断言抓出来的。
3. **`cacheInfo`/`clearCache`/`resolve`/`listFilings` 定义成点号却用了 `self`** → 直接崩
   （`attempt to index global 'self'`）。现在统一成方法（与 `sec_source.lua` 一致）并加了
   误用守卫。
4. **模式里塞 NUL 字节**：`dir:find("[\0\n\r]")` 报 `malformed pattern`。改成
   plain find（`find(s, 1, true)`）。
5. **配置类错误被旧缓存兜底救成了「成功」**：UA 缺邮箱时 `resolve` 仍然返回 ok（用旧缓存），
   用户只会看到「每次搜索都取不到新数据」。现在 config 类错误不走降级。
6. **`until` 是 Lua 保留字**：`opts.until`、`{until = ...}` 都写不出来（语法错误），
   结束日期改名 `opts.to`。
7. **测试工具自身的一次假通过**：`_G.__sec_fetch_real` 名字打错（应为 `__sec_real_fetch`）
   导致「重试第 3 次成功」那条断言其实是靠缓存兜底才 `ok=true` 的。
   教训：凡是「预期它失败」的用例，断言里必须同时验「真的走了那条路径」，否则兜底逻辑
   会把它变成假通过。

### 已知限制 / 这轮没做

1. **未接线**：`main.lua` / `sec_job.lua` / `sec_epub.lua` / `sec_source.lua` 一个字没改。
2. **提交索引没有缓存**：每次 `listFilings` 都会重下（JPMorgan 是 4.43MB + 分片）。
   建议集成时**先调一次 `forms=nil` 拿全量**，再在插件里用 `SecSearch.matchesForm` /
   `formSummary` 做本地筛选 —— 改筛选条件不该再走一次网络。若确实需要缓存，再加一个
   短 TTL（避免把「今天刚发的新 8-K」藏起来）。
3. **`max_extra_files` 默认 8** 意味着超出 8 个分片的历史不会列出来
   （JPMorgan/BlackRock/Vanguard 会命中这条）。`truncated` 与 `stats.sources_skipped`
   会如实说明，界面应当提示「历史未列全」。
4. **boundary 模式不命中 `10-K405` / `8-K12B` 这类古老变体**（要的话传全名或切 `prefix`）。
5. **模糊匹配是子串式的，不纠错**：`microsft` 匹配不到；`apple` 会把 `PINEAPPLE` 系列带上
   —— 这是「给候选」而非「猜一个」的代价，靠 `tie` 与候选列表让用户决断。
6. **`logger` 是本模块唯一的 KOReader 侧依赖**（与 `sec_source.lua` 相同），
   无头测试按既有 `work/stub_env.lua` 的做法打桩；没有 `require` 任何 `ui/*`。
   另外 `socket.http` / `ltn12` / `json` / `socket` 是设备自带库（本机无 luasocket，
   测试用 curl 实现传输层）。
7. **索引只做「行数 + 首末行」的廉价校验**：整份 600KB 的逐字节校验和要显式传
   `verify_cache=true`（默认关，每次搜索都跑太贵）。FAT 上中段被改坏理论上测不出来。
8. **`datastorage:getDataDir()` 的具体取值这一轮没在设备上核过**（本轮不碰设备），
   集成时请确认它落在 `/mnt/us/koreader/...` 下。
9. **UTF-8 安全的匹配代码有，但真实数据没覆盖**：当前 `company_tickers.json` 的 10434 个
   title/ticker 全是 ASCII（已核验，无制表符/换行/非 ASCII）。中文查询走的是
   「归一化后匹配不上 → no_match」这条已测通的路径。

### 本轮产物

| 文件 | 状态 | 说明 |
| --- | --- | --- |
| `sec_search.lua` | 新增，63416 字节 | 纯逻辑模块；`sha256=5e838de899d433a5196251a2b3dbc0a6`（前 32 位） |
| `work/sec_search_env.lua` | 新增 | 真联网测试环境（curl 传输层 + 自带 JSON 解码器，后者已被 Python 逐字节验证） |
| `work/sec_search_test.lua` | 新增 | 17 个阶段、73 项断言，全过 |
| `work/verify_search.py` | 新增 | Python 独立实现的无损比对，8 项全过 |
| `evidence/search_run.txt` | 证据 | 全部场景的真实输出（含被测量文件的 djb2 指纹） |
| `evidence/search_verify.txt` | 证据 | 无损比对的完整输出 |
| `evidence/search_lua_index.tsv` | 证据 | Lua 建出的索引（382028 字节） |
| `evidence/search_lua_entries_msft.tsv` | 证据 | Lua 合并出的微软全量清单（4525 行） |
| `evidence/search_artifacts.txt` | 证据 | 代码与证据的 sha256/字节数指纹（把证据绑到具体版本） |

---

# 波次二 · 集成期的真机发现（主会话，2026-10-07 16:20–16:30）

以下全部是在**真机**（Kindle PW5 + KOReader v2026.07.2）上跑出来的，不是本机推断。
脚本留在 `work/`，输出留在 `evidence/wave2/`。

## 1. 7 个模块在真机上都能被 require（`work/wave1_load_test.lua`）

证据：`evidence/wave2/device_module_load.txt` —— **通过 36 项，失败 0 项**。

这消掉的是集成期最大的一个风险：如果 `sec_search` / `sec_metrics` / `sec_images` 在设备上
找不到依赖，插件会**整个不出现**，而表现和「逻辑写错了」一模一样，极难定位。
实测 `socket.http` / `ltn12` / `json` / `ffi/archiver`（加载时打出 `ffi.load: libs/libarchive.so.13`）
在设备上全部就位，HTTPS 取数可用。

**踩到的坑**：`SecJob.gather` 是文件内部的 `local function`，**刻意不导出**
（公开面只有 `ensureDir` + `run`）。我一开始把它写进「期望存在的 API」，
真机上报 `sec_job.gather 存在（nil）`，差点误判成模块导出有问题。
教训：验证脚本里的「期望」本身也是可能写错的断言，报错先怀疑断言。

## 2. 搜索链路在真机上通了，但暴露出一个产品级问题（`work/search_probe.lua` / `search_probe2.lua`）

证据：`evidence/wave2/device_search_probe.txt`、`evidence/wave2/device_probe2_types.txt`。

`resolve("AAPL")` → `Apple Inc.` / `CIK 0000320193` / 单候选 / `matched_by=ticker`；
`listFilings(320193, {since=3年前})` → 扫到 1000 条、窗口内 264 条、耗时 **0.2s**、
`form_summary_scope = "since_window"`。

**三年窗口内的类型分布（苹果，23 种类型）**：

| 类型 | 份数 | | 类型 | 份数 |
| --- | ---: | --- | --- | ---: |
| **Form 4** | **135** | | 3 | 6 |
| Form 144 | 41 | | **10-K** | **3** |
| **8-K** | 26 | | DEF 14A | 3 |
| PX14A6G | 11 | | SC 13G/A | 3 |
| **10-Q** | **9** | | 其余 13 种 | ≤3 |

**结论（改产品，不是改代码）**：不筛类型时，**51% 的条目是内部人交易（Form 4）**，
用户搜一家公司只会看到一堵 Form 4 的墙，真正想看的 10-K/10-Q 被埋在十几页之后。
所以「按类型筛选」是**必需功能**，不是装饰。已在 `main.lua` 落地两条入口：
「只看年报季报（10-K / 10-Q / 8-K）」和「按类型筛选（选项来自真实分布）」。

**顺带一条接口陷阱**：`listFilings` 的 `limit` 会让「边扫边筛」提前收工，
于是 `form_summary` 只统计到被截断的那一小段 —— 实测 `limit=12` 时分布里**只有 Form 4 和 144**。
所以算分布时**不能设 limit**，边界交给 `since`（时间窗）+ `max_total`（内存上限）。

## 3. 任意表格类型的主文档，拿回来有三种形态（`work/search_probe2.lua`）

| 类型 | primary_document | 字节 | 拿回来是什么 |
| --- | --- | ---: | --- |
| Form 4 | `xslF345X06/form4.xml` | 25,819 | **完整 HTML**（`<!DOCTYPE html …>`，18 张表）—— 能做成书 |
| 10-Q | `aapl-20260627.htm` | 1,018,328 | XHTML + XBRL，正常 |
| DEF 14A | `aapl014016-def14a.htm` | 1,248,543 | XHTML，342 张表 |
| S-8 | `ef20049219_s8.htm` | 48,082 | **裸 EDGAR 提交包** |

Form 4 那个 `.xml` 后缀一开始看着很危险（.xml 不是 .htm），实测 SEC 的 XSL 渲染目录
`xslF345X06/` 给出的**就是渲染好的 HTML**，现有 HTML 清理链路可以直接吃。
（Form 4 尽管是内部人交易，用户明确要求「任意类型」里包含它，所以必须能读。）

**S-8 是真问题**：返回体以 EDGAR 的 SGML 外壳开头 ——

```
<DOCUMENT> <TYPE>S-8 <SEQUENCE>1 <FILENAME>ef20049219_s8.htm <DESCRIPTION>S-8 <TEXT> <html> …
```

现有清理链路只处理过 8-K/10-K/10-Q，而这三类的主文档都**不带**这个外壳，所以一直没暴露。
现在搜索把任意类型都放进来了，必须先剥壳，否则书的第一页会是一行
「S-8 1 ef20049219_s8.htm S-8」这样的原始元数据。
→ 记为波次二收尾项：在 `cleanHtml` 里加 `stripEdgarWrapper()`（找到最后一个 `<TEXT>` 之后开始）。

## 4. epub 验收器 `work/epub_check.py`（新工具）

结构类硬检查：mimetype 必须存在 / 是第一条 / STORED；OPF 声明的每个 item 必须在 zip 里且非 0 字节；
封面 `meta name="cover"` 必须指得到；TOC 每个 navPoint 的 src 必须存在；
**内联表现属性残留**（会压过读者的字体设置，是用户抱怨的根源）；
class 必须在 `sec_epub.lua` 样式表白名单内。

判据的边界是靠变异测试定的（`evidence/wave2/epub_check_mutation.txt`，7 个件）：
- `td/th/tr` 上的 `style="text-align:…"` → **通过**（这是 `stripPresentation` 刻意保留的表格对齐）
- 同一个 `td` 上混进 `font-size` → **抓**
- `p` 上任何 `style`（含 text-align）→ **抓**

**这个边界本身踩过一次误报**：第一版只看「属性名在不在白名单」，
于是 7 本真机 epub 全被报成「残留 3025–3593 处 style」，
实际那些全是 `td` 上的 `text-align`（特斯拉 1861 处 = 1432 right + 429 center）。
差一点就把一个**正确**的设计当成回归去「修」。

**7 本真机 epub 的改前基线**（`evidence/wave2/before_epub_check.txt`，全部通过）：
Meta 708,924 字 / 谷歌 239,959 / 微软 339,217 / 亚马逊 242,873 / 苹果 180,747 / 特斯拉 162,967 / 英伟达 158,566。
唯一警告是 7 本都**没有封面**（`meta name="cover"` 缺失）→ 睡眠屏用不了封面，正是波次二契约 1 要补的。

**顺手排除一个疑似异常**：Meta 的正文量是其他公司的 3–4 倍（708,924 字），
查过后确认是**两份真实的 10-Q**（346,433 字 / 93 张表 + 329,671 字 / 66 张表），
不是垃圾混入 —— Meta 的季报本来就极长。

## 5. F1 产物的独立验收

`evidence/epub_images/msft_images_cover.epub`（1,853,586 字节）用上面那个验收器跑：
manifest 26 项 / 图片 23 张 / 封面 `cover-image -> images/cover.jpg` 解析正确 /
正文 22 个图片引用 / 无排版残留 / class 全在白名单内 → **结构验收通过**。
（21,412 字 + 0 张表 —— 这是微软的分部业绩幻灯片，可见内容本来就在图里。）

---

## 追加七（2026-10-07）：EPUB 的图片与封面 —— `sec_epub.lua`（波次二 F1）

> 本节只讲 F1。波次二的总契约见 `INTEGRATION-WAVE2.md`；
> 主会话对本产物的独立验收记在上面「波次二 · 集成期的真机发现」第 5 节，
> 两处数字一致（manifest 26 项 / 图片 23 张 / 封面 `cover-image -> images/cover.jpg`）。

### 改了什么

`sec_epub.lua`：263 → 574 行。
sha256 `d4072f03875846549bb7035aa16ab94c35f1afe3bc29ee4f94afdec3f19b9548`。
波次一原文件逐字留档在 `work/baseline_sec_epub_wave1.lua`
（sha256 `252875639498a7a86988c47ed784db18cf8c4fc9644552e3a69d07dda7fe062e`），
专门用来做「不给 images 时逐字节同构」的对照，不要删。

对外签名不变（`SecEpub:write(epub_path, book)`），新增：

- `SecEpub:imagePlan(book)` → `plan, err, warnings`。
  `plan.items` 是 OPF `<manifest>` 的条目、`plan.dir` 是交给 `addPath` 的目录、
  `plan.bytes` 是图片总字节。**它也是本轮的警告出口**（见下）。
- `write` 现在返回第三个值 `warnings`（数组）。老调用方写
  `local ok, err = SecEpub:write(...)` 不受影响。
- `buildContentOpf(book, bookid, plan)` 多了第三个可选参数；不传 = 没有图片。

### 三条 archiver 事实（都是实测出来的，改这段代码前先看）

本轮把波次一遗留的「`addPath` 只用 system `zip` 近似验证过」补成了真验证：
本机有 libarchive，于是把**设备那一版**的 `ffi/archiver.lua` 直接跑起来
（KOReader v2026.07.2 锁的 koreader-base 修订 `6e4bc81a`，与 master 逐字节相同；
`libarchive 3.7.4`，soname 13 与设备一致）。复现命令：

```bash
luajit work/archiver_probe.lua          # 6 组对照实验
cat work/ko_archiver/PROVENANCE.md      # 上游件来源与 sha256
```

**① `addPath` 成功时也返回 `false`。** 源码收尾是 `return r == ARCHIVE_OK`，
而遍历正常结束时的 `r` 是 `ARCHIVE_EOF`(=1)、`ARCHIVE_OK`(=0)，永远不相等：

```
── ① root 不带尾斜杠（契约里的写法） ──
   addPath 返回值  = false   （注意这一栏！）
   addPath 后 err  = nil
   产出的 zip 大小 = 2342
```

失败时（目录不存在）它才既有 `err` 又有 `false`：

```
── ④ root 不存在 ──
   返回值 = false   err = …/does_not_exist: Cannot stat
```

所以判成败**只能看 `epub.err`**。我一开始就是按「返回 false = 失败」写的，
那版代码会把每一本带图的书都判成失败 —— 这个检查是必须有的，不是防御性编程。

**② `addPath` 的路径映射是纯字符串 `entry_root .. "/" .. path:sub(#root + 2)`，
`root` 尾部多一个斜杠就会吃掉每个子条目名的第一个字符**：

```
── ② root 带尾斜杠 ──
     OEBPS/images/sA/          ← 本该是 nsA/
     OEBPS/images/over.jpg     ← 本该是 cover.jpg
```

这是**静默**的：zip 里文件名变了，OPF 里的 href 没变，读者看到的是破图。
`sec_epub.lua` 因此先 `stripTrailingSlashes(images_dir)`，
并且测试里专门有一个「故意带尾斜杠」的场景核对 zip 内 `.jpg` 集合。

**③ zip 的压缩方式是写 header 那一刻从 requested 快照来的**，
所以可以在两次 `setZipCompression` 之间切换。实测 `mimetype` 与图片是 `Stored`、
5 个文本文件是 `Defl:N`：

```
      20  Stored       20   0%  …  mimetype
     235  Defl:N      160  32%  …  META-INF/container.xml
  26748  Stored     26748   0%  …  OEBPS/images/cover.jpg
  19410  Stored     19410   0%  …  OEBPS/images/msft-…/img019.jpg
```

（这一条同时确认了波次一那个「mimetype 必须第一个且 STORED」的写法没被破坏。）

### 顺带挖出一个上游笔误：`addFileFromMemory` 写进 zip 的权限是 `0o1204`

渲染 `content.html` 时渲染出来**全白**，查下去发现不是内容问题，是权限：

```
$ unzip -q epub && ls -la OEBPS/
--w----r--  1 bahr staff  27810  content.html      ← owner 自己都读不了
-rw-r--r--  1 bahr staff  26748  images/cover.jpg ← addPath 进去的正常

$ python3 -c "…external_attr…"
OEBPS/content.html   external_attr=0x82840000  >>16 = 0o101204   ← 权限位 0o1204
OEBPS/images/…/img001.jpg  external_attr=0x81a40000 >>16 = 0o100644  ← 权限位 0o644
```

`work/ko_archiver/ffi/archiver.lua:264` 是
`libarchive.archive_entry_set_perm(entry, 0644)`，
而 **Lua 5.1 没有八进制字面量**：这个 `0644` 是十进制 644 = 八进制 `1204`
（`--w----r--`）。作者想要的是八进制 `644`（十进制 420）。

- 影响：用 `unzip` 解包后文本文件 owner 读不了；qlmanage / QuickLook 渲染出来全白。
  我最初的 `content.html.png` 是空白就是这个原因，**不是**内容有问题
  （对照实验：设备上波次一的真产物 `work/epub_after/3.epub` 解出来一样是全白）。
- 设备上**无害**：KOReader 在进程内读 zip，不经过文件系统权限位。
- **不修**：这是 `ffi/archiver.lua`（上游文件，由 koreader-base 提供）的问题，
  而且 `addFileFromMemory` 没有传权限的参数，从 `sec_epub.lua` 改不了。
  本目录的渲染命令因此都先 `chmod -R u+rwX`。

### 契约 1 的落地方式：manifest 与 zip 位置由同一份数据推出来

契约要求「F1 自己生成 `<item>`，不要用 `sec_images` 给的 `res.manifest` 字符串」，
理由在实现里写清楚了：`addPath` 是**按目录结构铺文件**的，
所以 zip 里的位置由磁盘目录决定；manifest 里的 href 由我们写。
两边分别生成，只要有一处不同（比如一个补了 `n` 前缀、一个没补），
OPF 就会指向 zip 里不存在的文件 —— 而且不会有任何报错。

因此 `imagePlan` 只认 `href`（**`book.images[].path` 与 `book.cover.path` 实际没有被使用**，
它们不参与任何判断），并按 `href` 反过来算磁盘位置：

```lua
local rel  = href:match("^images/(.+)$")        -- images/<ns>/img001.jpg → <ns>/img001.jpg
local disk = dir .. "/" .. rel                  -- addPath 铺出来一定是这个位置
if lfs.attributes(disk, "mode") ~= "file" then  -- 不在就**从 manifest 去掉**
    warn("%s 对应的文件不在磁盘上，已从 manifest 去掉（留着就是读者眼里的破图）：%s", …)
end
```

于是「manifest 说的位置」与「zip 里真实的位置」由同一个 `rel` 决定，不可能漂。

封面按契约用 OPF **2.0** 的写法，不用 3.0 的 `properties=`：

```xml
<metadata>
  …
  <meta name="cover" content="cover-image"/>
</metadata>
<manifest>
  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  <item id="content" href="content.html" media-type="application/xhtml+xml"/>
  <item id="css" href="stylesheet.css" media-type="text/css"/>
  <item id="cover-image" href="images/cover.jpg" media-type="image/jpeg"/>
  <item id="msft-8k-20260902-fy27segments-img001" href="images/…/img001.jpg" media-type="image/jpeg"/>
  …
```

id 的规则：封面固定 `cover-image`（先登记，保证不被图片抢走）；
图片用 `book.images[].id`（波次一给的 `<ns>-imgNNN`），缺失时从 href 推、
过 `safeId()`（NCName：不能以数字/点/横线开头），并且**查重**——
撞了就加 `-2` 后缀并记警告。7 家公司打进同一本书时这是必需项。

### 小计线样式（契约 2）

`STYLESHEET` 里加了两条，两种写法都有（F2 可能把 class 加在 `<tr>` 上，
也可能加在 `<td>/<th>` 上）：

```css
.secsum td, .secsum th { border-top: 1px solid #999999 }
td.secsum, th.secsum { border-top: 1px solid #999999 }
```

### 「addPath 会把整个目录都打进包」这件事：报出来，不静默

`addPath` 加的是**目录下所有文件**，不只是 manifest 登记的那些。
所以 `images_dir` 里如果残留上一次运行的图，它们也会进包（白占体积）。

`imagePlan` 会走一遍目录、和 manifest 的期望集合比对，多出来的文件通过
**`write` 的第三个返回值 + `logger.warn`** 报出来：

```
! images_dir 下有 2 个文件没被任何 manifest 条目引用，但 addPath 仍会把它们打进 zip：cover.jpg, stray_from_last_run.jpg
```

只报告、**不删文件**：那个目录归 `sec_job` / 主会话管，`sec_epub.lua` 没有权限替它们清理。
这一条实测证明「报警告的东西确实进了 zip」（`evidence/epub_images/stray_file.epub`）。

**这是给 F3 的一条硬要求**：`images_dir` 下只能放本次这本书要的图。
workspace 里复用同一个 `work_dir` 时，要么每次先清空 `images/`，要么给每本书独立目录。

### 向后兼容的证明方式（不是「看起来没变」）

用**波次一的原实现**（`work/baseline_sec_epub_wave1.lua`）对**同一本书、同一份正文**
各打一次包，然后逐条比：

- 条目清单完全相同（**没有多出 `OEBPS/images/` 空目录条目** ——
  一条图都没登记上时 `plan.dir` 就是 `nil`，压根不调 `addPath`）；
- 每个条目的压缩方式相同；
- `content.html` / `toc.ncx` / `META-INF/container.xml` 逐字节相同；
- `content.opf` 把 `secfilings_<时间戳>` 归一化后逐字节相同；
- `stylesheet.css` 去掉那两条小计线规则（先去注释再比）后逐字节相同 ——
  这是本波次**有意**的唯一改动。

再与设备上波次一的真产物（`work/epub_after/3.epub`，KOReader v2026.07.2 生成）
对照：条目清单与压缩方式完全一致。

### 验收结果

| 检查 | 结果 |
| --- | --- |
| `luajit work/epub_images_test.lua` | **71 项，失败 0** |
| `python3 evidence/verify_epub.py …`（项目自带严格验收器） | **全部通过** |
| `python3 work/epub_images_check.py`（独立 Python 复核） | **29 项，失败 0** |
| `xmllint --noout --nonet` × 4 个 XML | 全部良构 |
| 22 张图从 zip 解出后与磁盘原件 | **sha256 逐个相同**（逐字节无损） |
| 22 张图从 zip 解出后解码尺寸 | 全部 1200×675 |
| 像素：`content.html` 与 22 张图的联络表 | 真的显示，无破图（`render_from_epub_*.png`） |

主产物：`evidence/epub_images/msft_images_cover.epub`，1,853,586 字节，31 个 zip 条目。

```
  Length      Date    Time    Name
       20  10-07-2026 16:30   mimetype
        0  10-07-2026 16:30   OEBPS/images/
        0  10-07-2026 16:30   OEBPS/images/msft-8k-20260902-fy27segments/
    26748  10-07-2026 16:30   OEBPS/images/cover.jpg
    19410  10-07-2026 16:30   OEBPS/images/msft-8k-20260902-fy27segments/img019.jpg
   …（22 张图）
    27810  10-07-2026 16:30   OEBPS/content.html
---------                     -------
  1871126                     31 files
```

`unzip -l` 的合计 1,871,126 比 epub 的 1,853,586 多出来的 17,540 字节，
正好是 5 个文本文件 deflate 省下的量；图片是 STORED，一个字节都没省也没多。

### 这一轮自己踩到并修掉的一个（留着当教训）

`imagePlan` 我一开始写成**点方法** `function SecEpub.imagePlan(book)`，
却用**冒号**调 `self:imagePlan(book)` —— 于是 `book` 位置收到的是模块表本身，
`book.images` 读成 `nil`、静默走了「这本书没有图片」那条分支：
一本没有图的书「成功」写出来了，没有任何报错、没有任何警告。
第一次跑测试时看到的正是这个现象（zip 只有 6 个条目）。

值得记下来是因为**它属于本波次最要防的那一类失败**：产出物看起来是对的，
只是少了一整块内容。抓住它的不是代码审查，是那条
「zip 里的 `.jpg` 集合必须等于 22 张图 + 封面」的断言。

### 已知限制 / 没做的

1. **仍然没有在真机上跑过**。本机跑的是同版本的 `archiver.lua` + Homebrew 的
   libarchive 3.7.4，不是 koreader-base 自己编进包里的那个二进制。
   真正在 Paperwhite 上打开一本带图的书这一步，仍归主会话。
2. **没做 epubcheck**（本机没装）。`verify_epub.py` + 独立 Python 复核覆盖了
   zip 合法性、CRC、mimetype、四个 XML 良构、manifest↔zip 双向对应、
   压缩方式、class 与排版残留；`epubcheck` 那些更细的规范检查（如
   `dc:identifier` 的 ISBN 形态、`guide`、`page-progression-direction`）没有跑。
3. **图片体积没有上限**。22 张 1,766 KB 时 epub 1,810 KB，在设备上没问题；
   但一份带 200 张大图的 10-K 会把 epub 推到几十 MB。
   是否要在 `sec_images` 那边设总量上限，属于产品决定，F1 不做。
4. **`book.images[].path` / `book.cover.path` 没有被使用**。契约里给了这两个字段，
   实现只认 `href`。如果 F3 把文件放得和 `href` 不一致，结果是「那张图从 manifest
   去掉 + 一条警告」，不会产生损坏的 epub —— 但 F3 应该按契约保证两者一致。
5. 图片在 zip 里的**顺序**是 `addPath` 走目录的顺序（本机是 APFS，设备是 ext4/FAT，
   可能不同）。EPUB 只规定 `mimetype` 必须第一个，其余顺序无约束，所以测试里
   不对图片顺序做断言。

### 本轮的产物

| 路径 | 作用 |
| --- | --- |
| `sec_epub.lua` | 本轮唯一改动的产品文件 |
| `work/ko_archiver/` | 设备那一版的 `ffi/archiver.lua` + `libarchive_h.lua` 原文（只下载，未改），含 `PROVENANCE.md` |
| `work/archiver_env.lua` | 在 Mac 的 LuaJIT 上跑真 archiver 的环境（`ffi.loadlib` → libarchive 13，lfs/ffi.util/logger 用替身） |
| `work/archiver_probe.lua` | 上面的 6 组对照实验，复现三条 archiver 事实 |
| `work/baseline_sec_epub_wave1.lua` | 波次一原文件逐字留档，向后兼容对照用 |
| `work/mk_epub_fixture.py` | 从波次一真实产物记录生成 `book.images` fixture |
| `work/epub_images_test.lua` | 主验证（71 项） |
| `work/epub_images_check.py` | 独立 Python 复核（29 项） |
| `evidence/epub_images/` | 上面这些命令的真实输出与像素证据，见该目录 `README.md` |

---

## 追加七（2026-10-07）：把四个模块接进产品链路 —— `sec_job.lua`（波次二 · F3）

> 本节只讲 **F3 = `sec_job.lua`**（编排层）。F1 = `sec_epub.lua` 的图片打包、F2 =
> `sec_source.lua` 的保留 `<img>` / 表格宽度 / UA 占位由各自的工作流负责，这里只记录
> 「接起来以后实际跑成了什么样」，以及两处尚未落地时如何验证。

### 一句话结论

真实 SEC 数据跑通了一本完整的书：**书首是「关键指标」章（8/8 个指标、13 张表）、
正文是微软 FY27 segments 那份 8-K（原文 22 张图全部下载并嵌在正文里）**，
成品 1.78 MB，`unzip -l` 里 `OEBPS/images/n789019-8-K-2026-09-02-1/img001..022.jpg`
整整齐齐，四个 XML 全部良构，toc 里有指标章与正文各自的锚点；
**峰值内存 8.4 MB**；图片少一张、指标接口全挂，书照样生成，失败原因如实进结果。

### 交付物

| 文件 | 状态 | 说明 |
| --- | --- | --- |
| `sec_epub/sec_job.lua` | **改写**（226 → 921 行） | 唯一的产线改动：图片 / 指标章 / 增量 / 进度保留 / UA / 新开关 |
| `sec_epub/work/mac_env.lua` | 新增 | Mac 上的整链路运行环境（替掉设备才有的库；含 archiver 替身） |
| `sec_epub/work/wave2_job_e2e.lua` | 新增 | 6 个场景的 E2E：offline / live / break / sentinel / bigreport / mixed |
| `sec_epub/work/wave2_verify_epub.py` | 新增 | **独立**验收（stdlib zipfile + ElementTree，与生成侧无共享代码） |
| `sec_epub/work/wave2_render.py` | 新增 | 解包 → 切片段（标签边界）→ qlmanage + Chrome 渲染 |
| `sec_epub/work/wave2_verify_all.sh` | 新增 | 一键复跑上面全部步骤 |
| `evidence/wave2_f3/**` | 证据 | 6 份 `e2e_*.txt` + 4 份 `verify`/`render` + `artifacts/*.epub` + 渲染图 |

复跑（在 `sec_epub/` 下，本机真实联网，约 6 分钟）：

```bash
bash work/wave2_verify_all.sh        # 全部场景 + 独立验收 + 渲染，日志落 evidence/wave2_f3/
luajit work/wave2_job_e2e.lua live   # 只跑主场景
```

### 一、五个契约是怎么接的（逐条 + 证据）

| 契约 | 落点 | 证据 |
| --- | --- | --- |
| 1 图片 | `fetchImages()` 把 `res.entries` 原样累加进 `book.images`，`book.images_dir = <work>/co_<cik>/images` | `unzip -l`：22 张在 `OEBPS/images/n789019-8-K-2026-09-02-1/`；OPF 的 `<item>` 与 zip 条目**双向**核对通过；22 张与波次一留下的 SEC 原件**逐字节 md5 一致** |
| 2 小计线 | F3 不涉及（F1/F2 的界面） | `stylesheet.css` 里 `.secsum td/th` 规则已在（F1 已落地） |
| 3 表格宽度 | `configureSource()` 把 `opts.table_avail_em / table_max_cols / table_projection` 写进 `sec_source`；参数名不存在时**报出来**而不是静默忽略 | `sec_source.lua:56/60/63` 三个模块字段（F2 未落地，接线已就位） |
| 4 User-Agent | `resolveUserAgent()`：`opts.user_agent` > `user_name+user_email` > `SecSource.user_agent` > 占位值；没邮箱时把 `USER_AGENT_HINT` 放进 **errors[1]** 与 `info.warnings` | `e2e_offline.txt` 场景⑤：`errors[1]` 就是「去设置里填邮箱」；`info.user_agent_set=false` |
| 5 阅读进度 | `keepProgress` → `SecEpub:write` → `restoreProgress{policy="reset"}` 三步 | 打包前种一份 `.sdr`（含 `copt_font_size=22`、`last_xpointer`、`percent_finished`、`cre_dom_version`）；打包后：**设置留住、位置与 DOM 版本清掉**、另写了进度台账 |

### 二、几个必须写下来的实现决定（都是被真实数据或设备约束逼出来的）

1. **工作目录按公司分，落在 `/mnt/us/secfilings-work`，打完包即清。**
   图片走 `addPath`，而 `addPath` 会把目录下**所有**文件都打进 zip；共享一个 `images/`
   就等于「清理时漏一个子目录，上一家的图会跟着进下一本书」。所以
   `dir = <work>/co_<cik>`、`book.images_dir = <work>/co_<cik>/images`，两者逐字对齐
   （sec_epub 用 `images_dir .. "/" .. href去掉images前缀` 推磁盘路径，差一层目录它会
   静默把图从 manifest 里去掉 —— 这正是第一次跑通时踩到的：成品 13 KB、图片一张没进包）。
   不放在插件数据目录（`/mnt/us/koreader`）是因为 rootfs 只剩约 11.7 MB。
   `keep_images=false`（默认）时整目录删掉，`live` 第三轮就是验这个。

2. **指标章失败只跳过它自己。** 取数失败 / 生成失败 / 用户关掉，三种情况分开记：
   失败进 `warnings` 并 `logger.warn`，**不进 errors**，其余章节照做；
   用户主动关掉（`metrics_chapter=false`）连「注意」都不报（那不是失败）。

3. **增量计划造了一份「视图」。** `include_reports` 这个老开关与关注列表的 `forms`
   会打架，所以 `planView()` 造一份浅拷贝、把 `forms` 按开关收窄，只交给 `planUpdates`；
   `seen` / `seen_upto_date` 仍是同一引用（只读），落账用的是**原列表**，用户数据不被改。
   基线是 `filing_date` 比较 —— 这是波次一的结论，F3 只负责不把它绕回去
   （`live` 第二轮：基线 2026-09-02，`seen` 记到 accession，没有重新下载）。

4. **不在关注列表里的公司退回旧行为，取消关注的公司不偷偷下回来。**
   这两个分支必须分开：前者是「只下某一家」的既有用法（不静默跳过），
   后者是用户的明确选择（`enabled=false` → 报一句就跳过）。
   `e2e_offline.txt` ④⑤ 各有一条断言。

5. **落账只记真的下成功的。** `commit()` 会把 update 里的**全部** accession 标成见过，
   所以只有「选的都下成功」时才用它；否则只 `markSeen` 成功的那几份、**不推进基线**
   （下次还会再出现），并且**打包失败时一份都不标**（用户手里没有东西，不能算成功）。

6. **可能 yield 的回调一律在 pcall 之外。** `SecImages` 的 `on_progress`、
   `SecMetrics` 的 `progress_cb` 都由本文件直接调用；本文件里唯一的 `pcall` 是
   `SecSource:new{}` 这个纯构造（不 yield），且失败就退回模块字段。

7. **「图片没进包」要有哨兵。** 图片总量 > 成品体积在物理上不可能（JPEG 压不动），
   所以 `size < image_bytes` 一定是打包层没读 `book.images`。这条警告在 F1 落地后
   仍有价值（跨版本），F1 自己那条「zip 体积 ≤ 图片字节数就报错」更强。

### 三、真实数据 E2E（6 个场景，60 条断言全过）

| 场景 | 断言 | 产物 | 说明 |
| --- | --- | --- | --- |
| `offline` | 18/18 | 4 KB 的小书 | 增量语义：首轮取 2 份 / 第二轮「没有新文件」/ 冒出新文件只取新的 / 取消关注跳过 / 没邮箱给提示 |
| `live` | 23/23 | 1.78 MB，2 章 | 真实 SEC：22 张图 + 指标章（8/8）+ 进度保留 + 第二轮无新文件 + 工作目录清理 |
| `break` | 8/8 | 1.62 MB，1 章 | 第 7 张图 404、指标接口全失败：书照做（21 张图 + 1 处 alt 占位），原因如实 |
| `sentinel` | 2/2 | 11 KB | 故障注入「打包层忽略 book.images」→ 哨兵报警，不静默 |
| `mixed` | 6/6 | 1.89 MB，3 章 | 指标章 + 22 图的 8-K + 8.6 MB 的 10-K（最重的真实组合） |
| `bigreport` | 3/3 | 112 KB | 内存对照，见下节 |

独立验收（`wave2_verify_epub.py`，Python 标准库重算一遍）：

```
msft_full.epub      PASS 26  FAIL 0    22 张图 + 指标章
msft_mixed.epub     PASS 27  FAIL 0    章序：metrics_789019=关键指标 | secf1=8-K | secf2=10-K
msft_degraded.epub  PASS 24  FAIL 0    21 张图、1 处 secimg-missing、没有指标章
msft_naive_packer   PASS 23  FAIL 1   ← 故意的：打包层忽略图片时，<img> 引用必然悬空
```

`unzip -l`（完整那本，节选）：

```
      20  stored    mimetype
   26748  stored    OEBPS/images/n789019-8-K-2026-09-02-1/img001.jpg
   ...
   17453  stored    OEBPS/images/n789019-8-K-2026-09-02-1/img022.jpg
     235  deflate   META-INF/container.xml
    3605  deflate   OEBPS/content.opf
     797  deflate   OEBPS/toc.ncx
    2897  deflate   OEBPS/stylesheet.css
   41002  deflate   OEBPS/content.html
28 个条目，解压后合计 1857359 字节；zip 文件 1826273 字节
```

章序与锚点（`mixed`）：`content.html` 里第一个 `<h1 class="secfiling">` 是
`metrics_789019=关键指标`，接着是 `secf1=微软 8-K · 2026-09-02`、`secf2=微软 10-K · 2026-07-29`；
`toc.ncx` 三条 navPoint 分别指向 `#metrics_789019` / `#secf1` / `#secf2`。

### 四、内存实测（本机 LuaJIT 2.1，与设备同款运行时）

| 场景 | 内容 | 峰值 RSS（不含 curl 子进程） | 墙钟 |
| --- | --- | --- | --- |
| `live` | 22 张图 + 指标章（正文是 34 KB 的 8-K exhibit） | **8.4 MB** | 44 s |
| `bigreport` | 8.6 MB 的 10-K + 指标章（无图） | **99.5 MB** | 28 s |
| `mixed` | 指标章 + 22 张图 + 8.6 MB 的 10-K | **94.8 MB** | 55 s |
| 空进程基准 | — | 2.3 MB | — |

结论：**图片和指标章对峰值几乎没有贡献**。`mixed`（94.8 MB）与「只有 10-K」（99.5 MB）
在测量误差内相同，而只有 8-K + 22 张图那一本只有 8.4 MB —— 说明 22 张图确实是
**边下边写盘**（`ltn12.sink.file` 每收到一个 TCP 分片就落盘，sink 探针记了 60 次写入），
内存里从头到尾没有多存一份图片；真正的内存成本仍然是 superframe 那一份 8.6 MB 的
10-K 解析（与本轮改动无关，见前面「追加三」）。

### 五、降级验证（真实数据）

```
images_fetch 注入：第 7 张图返回失败          → 21 张图进包，img007 记为失败并写出原因
metrics_fetch 注入：所有指标请求都失败        → 「关键指标章节未生成（只有 0 个指标取到数据…）」
结果：成功 1 家，失败 0 条；章节 1；成品 1616 KB；结果里逐条写出上面两件事
```

正文里那张失败的图变成 `<span class="secimg-missing">Slide 7</span>`，
像素上是一行普通文字，**没有破图方框**（`evidence/wave2_f3/render_degraded/missing_placeholder_crop.png`，
按占位元素的实际 y 坐标裁出来看的）。

### 六、与 F1 / F2 的接口现状（本节最需要主会话关注）

* **F1（`sec_epub.lua`）在本轮中途落地了**（16:24–16:27 两次改动）。`mac_env.installModules()`
  会先检测文件里有没有 `book.images`：已落地就直接用真文件，没落地才在内存里补契约那两行。
  所以本轮 live/mixed 的成品是**真的 F1 代码**打出来的，不是替身。
* **第一次跑通时踩到的正是接口缝隙**：`book.images_dir` 我一开始写成 `<work>/co_<cik>/images`、
  而图片实际落在 `<work>/images/<ns>/`，F1 的 `imagePlan()` 会按「磁盘上没有这个文件」
  把 22 条全部从 manifest 去掉，成品只有 13 KB —— **没有任何报错**。修法是把两边对齐，
  并在 `write()` 的第三个返回值（F1 新增的 warnings）上把打包层的抱怨带回结果里。
  这类「两边各自推路径」的坑，建议以后新增字段时先跑一次 `unzip -l` 数字对不对。
* **F2（`sec_source.lua`）本轮未落地**（仍是 13:01 的版本）：`cleanHtml` 第 6 步照样
  把 `<img>` 整段删掉。本轮的图片证据是**在内存里**把这一步换成「只计数不删除」跑出来的
  （补丁内容就是契约里那一行，`mac_env` 里带断言定位；F2 一落地，harness 自动改用真文件）。
  * 同时 `sec_job` 里加了**哨兵**：`cinfo.images > 0` 但清理后的 HTML 里没有 `<img` 时，
    结果里会出现「清理管线把 img 标签丢掉了，本轮一张图都没抓」。也就是说，
    如果 F2 最后没有去掉那一步，**不会静默出一本没图的书**，而是会明确报出来。
* **表格宽度参数**已按契约写进 `sec_source` 的模块字段；若 F2 最终改成实例构造
  （`SecSource:new{...}`），`configureSource()` 会优先用实例，并且两条路都设了 UA。
  这条接缝建议 F2 落地后与主会话对一次。

### 七、给 F4（`main.lua`）的接线要点

* `SecJob.run(companies, opts, progress_cb)` 返回值变成**三个**：
  `results, errors, info`（旧的取两个返回值的写法照样能用，第三个是新增的汇总）。
  `info` 里有：`planned / made / no_new / images / images_failed / image_bytes /
  metrics_ok / metrics_failed / cancelled / user_agent_set / warnings`。
* 每本 `results[i]` 多了：`images / images_bytes / images_failed / metrics / metrics_ok /
  new_count / warnings`。
* 新 `opts`：`user_agent`（或 `user_name`+`user_email`）、`fetch_images`、`metrics_chapter`、
  `table_avail_em`、`table_max_cols`、`table_projection`、`work_dir`、`keep_images`、
  `keep_progress`、`progress_policy`、`watchlist`、`save_watchlist`、`scan_limit`、
  `first_run_new`、`since_date`、`image_*`、`metrics_tags`。
* **没填邮箱时 `errors[1]` 就是那句提示**（放在最前面是故意的：界面只显示前 3 条失败，
  否则用户看到的是七条 HTTP 403）。建议 F4 顺手加一个「联系邮箱」设置项，
  并把这条提示改成可点的引导。
* 工作目录默认 `/mnt/us/secfilings-work`（不是 rootfs），UI 上不必暴露，除非用户要保留图片。

### 八、已知限制与遗留（如实记录）

1. **没在设备上跑过**。本节所有数字都来自 Mac 的 LuaJIT 2.1（与设备同款运行时）。
   真机要复测的是：`ffi/archiver` 的 `addPath`（本机是系统 `zip` 替身）、内存峰值、
   以及 22 张图真机下载的耗时（本机 44 s，其中指标取数占约 12 s）。
2. **`ffi/archiver` 是替身**：本机没有 koreader-base 的运行库。替身按调用顺序登记条目、
   并尊重每条当时的压缩方式（mimetype 与图片 STORED、文本 deflate），
   因为 F1 正是用「zip 体积 > 图片字节数」来验证图片进包的 —— 替身不忠实这一点，
   会得出「图片没进包」的**假失败**（本轮真的这么假失败过一次）。
3. **`span.secimg-missing` 在样式表里没有规则**（`sec_epub.lua` 里 grep 为 0）。
   抓失败的图目前渲染成一行普通文字，与正文没有视觉区分。建议 F1 补一行
   `span.secimg-missing { color: #777; font-size: 0.85em; }`（波次一就已提出的建议）。
4. **截图渲染有一个坑**：本机 Chrome headless 的**最小窗口宽度是 500px**，
   `--window-size=424` 时页面仍按 500px 排版、截图却只有 424px 宽 —— 会看到
   「文字被切掉」的**假溢出**。正确做法是 `body{width:Npx}` 把宽度钉死（`wave2_render.py` 已这么做）。
5. **`qlmanage` 只给固定视口的方形缩略图**，长文档会被压成一团；判断排版要看
   Chrome 那条路（408px 等价宽度），qlmanage 只当总览。
6. **指标的耗时**：14 个请求约 12 s，是整轮里最慢的一段（下载 22 张图约 20 s）。
   真机上如果觉得慢，`opts.metrics_tags` 可以只取一部分指标。
7. **多公司时 `book.description` 里的图片数**是按本书累计的（书的描述本来就是给这一本看的），
   与 `results[i].images` 一致。

### 九、证据清单

| 文件 | 内容 |
| --- | --- |
| `evidence/wave2_f3/e2e_{offline,live,break,sentinel,bigreport,mixed}.txt` | 6 个场景的完整输出（含每条断言的 PASS/FAIL、耗时、峰值 RSS） |
| `evidence/wave2_f3/e2e_*_logger.txt` | 落进 `logger` 的原文（设备上是 crash.log 的内容） |
| `evidence/wave2_f3/verify_epub.txt` | 独立验收（4 本，含 `unzip -l` 与逐字节 md5 比对） |
| `evidence/wave2_f3/artifacts/{msft_full,msft_mixed,msft_degraded,msft_naive_packer}.epub` | 四份成品 |
| `evidence/wave2_f3/render_mixed/` | 最重那本：首页 / 指标章整章（408px）/ 正文开头（含 22 图） |
| `evidence/wave2_f3/render_degraded/` | 降级那本：正文开头 + `missing_placeholder_crop.png`（按 y 坐标裁出的缺图处） |
| `evidence/wave2_f3/render_{mixed,degraded}.txt` | 渲染过程输出（含「以 '<' 开头但不是标签的片段 = 0 处」这类结构性检查） |

复跑全部命令：

```bash
cd <sec_epub>
bash work/wave2_verify_all.sh

# 单跑
luajit work/wave2_job_e2e.lua offline|live|break|sentinel|bigreport|mixed
python3 work/wave2_verify_epub.py evidence/wave2_f3/artifacts/msft_mixed.epub \
    --expect-images 22 --expect-metrics yes --unzip-list
python3 work/wave2_render.py evidence/wave2_f3/artifacts/msft_mixed.epub /tmp/w2render
```
