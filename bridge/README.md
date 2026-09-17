# MiMo Desktop 本地桥（DSH ⇄ Xiaomi MiMo Desktop）

让 DSH 把本机正在运行的 **小米 MiMo Desktop** 当成一个外部执行体来用：读它的会话、
给它派活、读回结果和产物。

```
DSH ──(MimoDesktop.ps1)──► 127.0.0.1:<port> /v1/... ──► MiMo Desktop 的 agent
                                                          └─ 用它自己的工具干活
                                                             (bash / python / 浏览器 / computer-use)
DSH ◄──(messages / events)──── 会话记录 + 产物文件 ◄────────┘
```

MiMo Desktop 是 Electron 应用，启动时会在本机回环地址上开一个 HTTP API，并把
端点与 Bearer token 写进：

```
%APPDATA%\Xiaomi MiMo\desktop-api.json    →  {"api":1,"port":49206,"token":"...","pid":42196}
```

## 用法

本机是 Windows PowerShell 5.1（没有 `pwsh`），且执行策略会拦直接运行脚本，
所以统一用 `-ExecutionPolicy Bypass -File`：

```powershell
$b = 'D:\Deepseek Harness\_mimo_bridge\MimoDesktop.ps1'

powershell -NoProfile -ExecutionPolicy Bypass -File $b start
powershell -NoProfile -ExecutionPolicy Bypass -File $b health
powershell -NoProfile -ExecutionPolicy Bypass -File $b list -Limit 10
powershell -NoProfile -ExecutionPolicy Bypass -File $b messages -SessionId ses_xxx -Last 3 [-Full] [-WithReasoning]
powershell -NoProfile -ExecutionPolicy Bypass -File $b progress -SessionId ses_xxx -Since <unix_ms> [-Max 80] [-DetailMax 110]
powershell -NoProfile -ExecutionPolicy Bypass -File $b attachments -SessionId ses_xxx
powershell -NoProfile -ExecutionPolicy Bypass -File $b saveattachments -SessionId ses_xxx -Out <目录>
powershell -NoProfile -ExecutionPolicy Bypass -File $b send -SessionId ses_xxx -Message "..." [-Dir D:\path] [-Perm ask|full]
powershell -NoProfile -ExecutionPolicy Bypass -File $b ask  -SessionId ses_xxx -Message "..." [-TimeoutSec 180]
powershell -NoProfile -ExecutionPolicy Bypass -File $b watch -SessionId ses_xxx [-TimeoutSec 30]
powershell -NoProfile -ExecutionPolicy Bypass -File $b file -SessionId ses_xxx -Path <相对路径> -Out <本地文件>
```

`ask` = `send` + 轮询 `messages` 直到助手回复稳定，是"委托一件事并拿结果"的原子操作。

## 实时进度窗口

MiMo 自己的窗口**不会**实时显示外部注入的轮次（它只在"选中会话"时拉全量历史），
而 DSH 侧的 agent 只能在回合结束时说话、无法主动播报。所以实时进度由一条独立控制台提供：

**双击 `MimoProgress.cmd`**（或 `powershell -File MimoProgress.ps1`）。它每 2 秒调一次
`progress` 动作并打印：

```
23:18:59  [say  ] 在 D:\DSH and MIMOdesktop\bridge-demo 目录下做三件事：一、写 README.md...
23:19:15  [think] thinking (336 chars)
23:19:19  [tool ] bash   completed  Create bridge-demo dir and README.md
23:19:19  [file ] + bridge-demo\README.md
23:19:27  [tool ] bash   running    $path = "...\progress.txt"; if (Test-Path $path) { ...
23:19:30  ---- running 00:00:30  say/think 1/2  tools 2  tokens out 50656 think 18017 ----
  turn finished after 00:00:41   tools=4  text=1  thinking=4  tokens out=51131 think=18062
```

- `[think]` 思考长度、`[say]` 文本、`[tool]` 每次工具调用**及其自身标题/命令**、
  `[file]` 监视目录下新增或改动的文件、每 30 秒一行心跳、本轮结束自动收尾。
- 参数：`-Follow` 一直等下一轮；`-Replay` 从头看历史（默认只看新活动）；
  `-Dir <目录>` 指定要监视的文件树；`-IntervalSec` 调节刷新频率。
- 游标规则：`progress` 的 `lastAt` 是"会话最新活动"，**没有新事件时它会小于当前游标**；
  调用方必须判 `>` 再前进，否则旧事件会重复刷出（踩过）。

## 自启动

用户已授权桥自行拉起 MiMo Desktop，所以派活前不需要人先把应用打开：

- `start` 动作：应用没开就启动它，然后轮询 `desktop-api.json` 直到 `/v1/health` 返回 200。
- **其它动作也会自动拉起**（`Get-MimoCred` 发现凭据失效就走同一条路）；想禁止用 `-NoAutoStart`。
- **绝不启动第二个实例**：应用进程已在但凭据还没就绪时，只等待、不启动——重复实例会用
  新端口改写 `desktop-api.json`，直接打断正在工作的桥。
- 实测：应用在运行时调 `start` 返回 `alreadyRunning: true`，进程数 5 → 5，未产生副本。

## 委托分工（用户授权的长期规则）

规则全文在 `~/.dsh/AGENTS.md`（全局指令，DSH 每次会话自动加载），工作区细节在
`D:\Deepseek Harness\AGENTS.md`。要点：

- **默认把体力活派给 MiMo**：批量脚手架、素材/图片生成、文档、重复性改动。
- **我负责**：拆任务、写清验收标准、**独立验收**（磁盘 / API / 截图），不采信它的自述，
  以及集成、收尾、最终交付。
- **接管条件**：连续 2 次产出不达预期或卡在同一限制 → 亲自做完，不再重复派同类活。
- **长任务分段等待**，每段 ≤10 分钟并给用户反馈，禁止长时间静默（这是踩过的坑）。

## 实测：端到端已跑通

worker 会话 `ses_ffe5f503bf1a2ffeCS40Wd6Cku`（目录 `D:\DSH and MIMOdesktop`，界面标题 `hi`），
id 记在 `worker-session.txt`。

```
ask -SessionId ses_ffe5f503bf1a2ffeCS40Wd6Cku -Message 'Reply with exactly this line and nothing else: bridge-ok round2'
-> {"sessionId":"ses_ffe5f503bf1a2ffeCS40Wd6Cku","newMessages":2,"completed":true,"timedOut":false,"emptyReply":false,"reply":"bridge-ok round2"}
```

中文往返正常。助手消息的 parts 是**分类型**的：

| part type | 含义 |
|---|---|
| `step-start` / `step-finish` | 一轮的起止标记，无文本 |
| `reasoning` | 思维链（默认不取） |
| `text` | 可见答复（默认只取这个） |

所以 `ask` 默认只返回干净答复；要看思维链加 `-WithReasoning`。
消息的 `info` 里带 `providerID/modelID`（如 `xiaomi/mimo-auto`）、`tokens`、`cost`、`finish`。

## 逆向出的接口（应用版本 26.914.142245）

| 方法与路径 | 作用 |
|---|---|
| `GET /v1/health` | `{ok,api,app,engine}`，`engine:"ready"` 表示可用 |
| `GET /v1/sessions?limit=N` | 会话列表（`id,title,directory,time,...`；含完整 system prompt，很重） |
| `GET /v1/sessions/{id}/messages?dir=` | 完整消息历史 `[{info,parts}]`（247 条一次性返回，limit 对 messages 无效） |
| `GET /v1/sessions/{id}/events?dir=` | SSE 事件流：首帧 `meta`，随后 `busy / ui / text-partial / permission / usage / title / idle`（`idle` = 一轮结束，重复帧已由 `watch` 去重） |
| `POST /v1/sessions/{id}/turns` | 派一轮任务，body `{message,model,dir,perm,origin,files,plugins}` → `202 {ok:true}` |
| `GET /v1/sessions/{id}/files?u=&dir=` | 取会话附件。**实践中不可用**：`u` 必须命中消息里 `type:"file"` part 的 `url`，而该 url 又必须以 `file:` 开头；实测 7 个会话的附件**全是 `data:` 内联，`file:` 数量为 0**，所以任何请求都返回 403 `forbidden-file`。用 `saveattachments` 代替（见下） |

- 鉴权：`Authorization: Bearer <desktop-api.json 里的 token>`；只监听 `127.0.0.1`，
  并校验 Host 必须是 `127.0.0.1`/`localhost`/`[::1]`。
- 错误码：`unauthorized(401) / forbidden-host(403) / forbidden-file(403) / not-found(404) /
  busy(409) / bad-request(400) / engine-not-ready(503) / not-logged-in(503)`。
- `model` 合法值：`mimo-auto`（默认）、`mimo-flash`、`mimo-pro`。
- `perm` 合法值只有两个（应用内是中文枚举）：`-Perm ask`（改文件前问你，应用默认）、
  `-Perm full`（完全访问）。脚本用码点拼这两个字符串，保证文件本身是纯 ASCII。

## 实测结论与坑

已在本机实测通过：`health`、`list`、`messages`、`watch`(SSE)、`send`、`ask`。

1. **没有建会话的接口。** 应用里的"新建会话"在发出第一条消息之前只是客户端草稿，
   引擎里并不存在（日志 `loadEngineSessions: 原始条数 = 6`），所以 API 看不到它。
   要拿到一个可用会话，先在界面上发出任意一条消息。
2. **伪造的 session id 会返回 `202 {"ok":true}` 然后静默什么都不做。**
   harness 起了一瞬即结束、会话不会被创建、随后读取该 id 是 404。
   所以 `202` 只代表"已受理"，不代表"跑起来了"——务必用真实存在的 id。
3. `send` 是**异步**的，结果要靠 `messages` / `events` 轮询拿。
4. 用它派活会**真实出现在你的 MiMo 会话界面里**，并沿用该会话自身的权限设置。
   建议专门开一个 worker 会话，不要拿正在进行中的正经会话当靶子。
5. 这是**非官方内部接口**，随应用更新可能变化；应用重启后端口和 token 都会变
   （脚本每次调用都重新读 cred 文件，所以能自动跟上）。
6. 桥跑在用户自己的机器、自己的应用、自己的账号上；token 只在本机回环使用。

## 工具调用、权限与工作目录（已实测）

派一个"列出当前目录文件"的只读任务，事件流给出了完整答案：

```
event: ui      {"kind":"tool","tool":"bash","status":"running","input":{"command":"Get-ChildItem -Force"}}
event: permission  {"type":"permission","req":{"permission":"bash","patterns":["Get-ChildItem -Force"],
                    "always":["Get-ChildItem *"],"sessionID":"ses_...","tool":{"callID":"call_..."}}}
event: ui      {"kind":"tool","tool":"bash","status":"completed","output":"..."}
event: idle    {"type":"idle"}
```

1. **工具调用会发审批请求。** 即使只是 `Get-ChildItem` 这种只读命令，也会推一条
   `permission` 事件，带 `permission`（工具种类，如 `bash`）、`patterns`（本次要批的命令）
   和 `always`（"以后总是允许"的匹配式，如 `Get-ChildItem *`）。桥能**看到**这个请求，
   于是"派活后卡在审批上"是可检测的，不会静默挂死。
2. **本轮里它是被执行了的**（`status: completed` + 真实输出）。至于是 GUI 里点了批准还是
   系统轮次自动放行，需要看当时界面才知道——这一点尚未定论。
3. **工作目录默认不是会话目录！** 第一次 bash 落在了 `C:\Users\MI\XiaomiMiMoProjects`
   （应用的默认项目根），MiMo 自己发现后带 `workdir` 重试才落到会话目录。
   **所以派活时用 `-Dir <绝对路径>` 明确钉住工作目录**，否则它会跑在别处。
4. `{"type":"idle"}` 是一轮结束的信号（`watch` 现在据此提前退出）；
   期间会不停重复 `{"type":"busy"}`，`watch` 已做去重。

想要全自动（不弹审批）的两条路：在界面把该 worker 会话权限切到「完全访问权限」，
或派活时加 `-Perm full`（等于对该轮提权，谨慎）。

### 全自动派活 + 写文件（已实测、磁盘独立验证）

```
ask -SessionId ses_ffe5f503bf1a2ffeCS40Wd6Cku -Dir 'D:\DSH and MIMOdesktop' -Perm full `
    -Message '在当前工作目录创建文件 mimo-bridge-proof.txt，写入三行：...'
-> {"newMessages":3,"completed":true,"timedOut":false,"emptyReply":false,
    "reply":"```\nbridge-ok\n2026-09-17 22:32:00\nmimo-v2.5-pro\n```"}
```

磁盘核对（不采信 MiMo 自述）：`D:\DSH and MIMOdesktop\mimo-bridge-proof.txt`，50 字节，
内容与它贴回的**逐字一致**。加 `-Perm full` 后，需要 bash 的任务也直接跑完，13.1 秒返回。

### 两个会让桥误判的坑

5. **不要用"有没有文本"判断这轮结束。** 我采样时看到某轮 `chars=0`，一度以为它回了空话，
   其实那轮**还在跑**——`time.created` 到 `time.completed` 相隔 **96 秒**（reasoning 12558 token），
   最终文本是 `watch-path-ok`。在它结束前采样就会看到空文本，从而误判成"空回复"或"超时"。
   所以 `ask` 以 `info.time.completed`（而不是文本是否非空）作为结束判据，
   返回 `completed / timedOut / emptyReply`；`emptyReply` 是防御性字段，尚未真实遇到。
6. **`-Dir` 必须给。** 不给就会跑在 `C:\Users\MI\XiaomiMiMoProjects`，
   MiMo 得自己发现后带 `workdir` 重试才能落到正确目录。

### 审批与界面可见性（已实测）

用本地 API 派活时的两个反直觉行为：

- **不会弹审批框。** 实测 22:29–22:32 那几轮（含 bash 列目录、创建文件、读回文件），
  应用日志里 permission / approval 相关记录**一条都没有**，界面上也毫无动静，
  而命令照样执行完成。也就是说 `source=system` 这类外部注入的轮次是**直接放行的**，
  可以无人值守。桥仍会通过事件流把 `permission` 帧推给调用方，纯粹用于观测。
- **界面可见性取决于 `origin`。** 不带 origin 注入的轮次在日志里是 `origin=__main__`，界面**看不到**
  （实测那时引擎里已有 18 条消息，界面仍只显示最早那一问一答）。给桥传
  `-Origin <该会话的 convo id>`（本例 `c1789655256245-1`，从应用日志里 `source=user` 那行拿到）之后，
  日志变成 `origin=c1789655256245-1 ... source=system`，`turn-power-save` 标签也从
  `run:__main__` 变成 `run:<convo-id>` —— **这条请求就出现在界面上了（用户实测确认）**。
  没带 origin 的历史轮次，靠"切走会话再切回"强制重载也能看到。

结论：**界面不是可靠的状态指示器，一切以 API / 磁盘为准。** 这对"当 worker 用"反而是好事
——不抢你的界面、不需要你点任何东西。

### 审计：怎么查这些活到底是谁跑的

应用自己的日志会区分两种来源，这是外部无法伪造的对照
（`%APPDATA%\Xiaomi MiMo\logs\<date>.log`）：

```
22:27:36 [info] [harness] session created sid=ses_ffe5f503bf1a2ffeCS40Wd6Cku
22:27:36 [info] [harness] session origin=c1789655256245-1 ... source=user   msgLen=2
22:28:04 [log]  [mimo][api] POST /v1/sessions/ses_ffe5f503.../turns
22:28:04 [info] [harness] session origin=__main__          ... source=system msgLen=78
22:28:04 [info] [turn-power-save] acquired sysId=2 ... first=run:__main__
22:28:10 [info] [turn-power-save] released sysId=2 ...
```

- `source=user` + `origin=<convo-id>` = **人在界面上打的字**（那行 `msgLen=2` 就是 "hi"）。
- `source=system` + `origin=__main__` = **桥注入的轮次，界面看不到**。
- `source=system` + `origin=<convo-id>` = **桥注入且界面可见的轮次**（派活时传了 `-Origin`）。
- 每轮都有 `turn-power-save acquired/released` 配对，说明是应用自己在跑。
- 引擎侧另有逐轮 token 账（`info.tokens`）与模型名（如 `xiaomi/mimo-auto`）。

顺带印证了前面两条结论：`session created` 恰好发生在人发出第一条消息的那一刻
（新会话在此之前不存在）；而 22:30:38→22:32:05 那对 acquire/release 就是那轮
"跑了 96 秒"的慢轮次。

## 取回附件与产物

三条路，按可靠性排序：

1. **普通产物文件 → 直接读磁盘。** MiMo 写到 `-Dir` 钉住的目录里，DSH 用文件工具读即可。
   已用 `mimo-bridge-proof.txt` 独立核对过（不采信 MiMo 自述）。
2. **内联附件 → `saveattachments`。** MiMo 把生成的图片以 `data:<mime>;base64,...` 挂在消息
   `type:"file"` 的 part 上，这个动作把 base64 解码落盘。实测某会话取出 17 个文件
   （4 张 PNG + 13 张 JPEG，约 17 MB），PNG 签名 `89504e47...`、JPEG 签名 `ffd8ffe0...` 全部有效。
3. **`/v1/.../files` → 不要用。** 见接口表：它只认 `file:` 开头的 url，而实测没有任何会话
   产生这种 url，所以恒定 403。桥里的 `file` 动作保留着，但只在这类 url 真出现时才有用。

另外 `attachments` 会把 `data:` url 截断到 160 字符再显示——它们动辄几 MB，
整条打出来会直接刷爆终端和分析上下文。

## 没能走通的路（记录以免重复尝试）

- **把 MiMo 挂成 DSH 的模型 provider**：需要 `sk-`（按量付费）或 `tp-`（Token Plan）密钥。
  本机 `%USERPROFILE%\.mimo\config.json` 不存在，`MIMO_ROUTER_KEY` 也没设，
  应用走的是小米账号登录态，密钥不落盘。
- 应用内部路由域名 `mimorouter.llmcore.ai.srv` 不公网可达（DNS 不存在），
  只在应用进程内部使用，不能拿来当 OpenAI 兼容端点。
- 引擎服务（`127.0.0.1:50491`，opencode 派生，`Basic opencode:<token>`）的 token 只存在
  于内存，不落盘，因此没法绕过去无头建会话。

要走官方正路，去 <https://platform.xiaomimimo.com> 拿密钥后，Base URL 为
`https://api.xiaomimimo.com/v1`（OpenAI 兼容）或 `https://api.xiaomimimo.com/anthropic`；
Token Plan 则是 `https://token-plan-cn.xiaomimimo.com/v1`。

## 文件

- `MimoDesktop.ps1` — 桥本体，纯 ASCII（避免 PowerShell 代码页把非 ASCII 字符读坏），
  内含完整接口注释与踩坑说明。
- `worker-session.txt` — 当前 worker 会话 id。

### PowerShell 5.1 踩过的坑

- 字符串 body 按 ISO-8859-1 编码 → 必须把 JSON 转成 UTF-8 字节再发，否则中文提示词乱码。
- `[string]::Concat(char,char,char,char)` 四参重载在 5.1 下抛 "Value cannot be null"。
- `System.Net.Http.HttpClient` 需先 `Add-Type -AssemblyName System.Net.Http`。
- .NET Framework 只有 `ReadAsStreamAsync()`，没有 `ReadAsStream()`。
- 源文件里放非 ASCII（如省略号 …）会被代码页读坏导致语法错误 → 保持纯 ASCII。
- **脚本参数就是有类型的变量，而且变量名不区分大小写。** 局部变量 `$last` 与参数
  `[int]$Last`（`messages -Last N` 用的）是**同一个变量**，往里面存一个消息对象会抛
  `Cannot convert ... to System.Int32`，且报错行指向赋值语句、与 Int32 毫无关系——最难查的一个。
  桥里的局部变量因此统一避开参数名（`$newest` 而不是 `$last`）。
