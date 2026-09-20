# 🎧 绝区零千夏电脑帧数性能监视器

**ZZZ Sunna PerfMonitor · v1.0**

> 实时播报你选定屏幕的 **FPS / CPU / GPU / 内存**。纯 PowerShell 5.1 + WPF。

## 快速开始

1. 解压后双击 `daemon\pet_launcher.vbs`（或右键 `pet.ps1` → "使用 PowerShell 运行"）。
2. 想要**真实游戏帧率**（可选）：双击 `daemon\install_rtss.vbs` 一键安装
   RTSS——包内已附**官方原版安装包**（Redist\，未做任何修改），装完自动启动、桌面自动生成
   RTSS 快捷方式。之后 **RTSS 随桌宠自动管理：桌宠运行时它自动启动（若系统弹出确认框点"是"即可），
   退出桌宠时也会一并尝试关闭**。没装 RTSS 时面板显示所选屏幕的刷新率，其余功能不受影响。
3. 开机自启（可选）：把 `daemon\pet_launcher.vbs` 的快捷方式放进 `shell:startup`，
   或以管理员运行 `daemon\register_task.ps1`（注册提权计划任务，顺带获得 RTSS 掉线自动复活）。
4. 桌面出现 5 个组件（人物/数据栏/吉他/画架/泡泡酱）即成功——气泡说话时才出现，平时看不到是正常的；拖任意组件=整组移动，滚轮=整体缩放。

## 架构

```
数据源                          采集（全在 C# 内部线程）
RTSS 共享内存 RTSSSharedMemoryV2 → 选中屏游戏 FPS（前台 pid 优先 + 覆盖率兜底）
GetSystemTimes 差分             → CPU %
GlobalMemoryStatusEx            → 内存 %
NVML(nvml.dll) / nvidia-smi     → GPU %
EnumDisplayMonitors             → 物理屏幕表（主屏优先、其余按 X 升序）+ 刷新率

WPF 侧（UI 线程）
6 个独立 Window（无边框/置顶/分层/不进 Alt+Tab）
物理坐标唯一权威 = Win32 SetWindowPos；WPF 内容按 WPF 自报缩放换算 DIP
情绪状态机（2s 评估 + 滞回）→ 切姿势（懒加载 .wpm，只驻留 1 段）
台词库 assets/lines.json（按情境挑选，数据实时嵌入）
```

**组件与基线物理尺寸**（s=1.0 时；每组件可独立缩放 0.5–1.6）

| 组件 | 尺寸 | 素材 |
|---|---|---|
| pet | 高 300，宽=按当前 clip 宽高比 | `assets/wpm/*.wpm`（151 帧 @30fps） |
| panel | 360×79.07 | `assets/panel/panel.png` |
| guitar / easel / bchan | 150 / 200 / 95(+26 名字) 高 | `assets/accessory/*.png` |
| bubble | 215×106.3 | `assets/bubble/bubble_fill.png` |

## 运行

- 桌面快捷方式 **性能监视桌宠**（= `daemon\pet_launcher.vbs`，纯 ASCII，路径按自身位置推导）
- 开机自启：`HKCU\...\Run\ZZZSunnaMonitor` → 同一个 launcher
- 手动：`powershell -NoProfile -ExecutionPolicy Bypass -File pet.ps1`
- 再次双击快捷方式 = **优雅重启**（请求旧实例退出后新实例接管；若旧实例不响应则唤出它）
- 退出：右键桌宠 → 👋 退出
- 验收（两道门都要跑）：
  `powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoke_test.ps1`（16 项，逻辑/几何/落盘）
  `powershell -NoProfile -ExecutionPolicy Bypass -File tools\input_test.ps1`（**真实鼠标输入** 4 项，会移动光标并复原）

## 游戏掉帧了？先分清是谁的锅

实测开销（同一分钟内 A/B 对比）：**桌宠占用约 1.9% 单核 CPU、2–3 个百分点的 GPU 利用率**；
退出桌宠后 GPU 基线几乎不变。所以它本身不太可能把游戏拖到"很低"。

历史上出现过"打开游戏帧率很低、退出桌宠也没用"——**退出没用就说明元凶不在桌宠进程里**。常见三类：

| 类别 | 表现 | 怎么处理 |
|---|---|---|
| 残留/提权的常驻进程 | 抓帧/监控类探针（如 `PresentMon` 一类 ETW 工具）、被无超时反复拉起的子进程等后台残留会一直跑，桌宠退出也不消失 | 跑 `tools\check_system_load.ps1` 看第 2 节；清残留用提权守护：`runtime\command.txt` 写 `cleanup-leftovers` 后运行计划任务 `ZZZSunnaMonitor_RTSS`（命令 30 秒未被消费会自动清除并记日志） |
| RTSS 自身的设置 | RTSS 是独立程序，桌宠会随自身启动/退出自动管理它；但 RTSS 以管理员权限运行（官方要求），桌宠退出时若系统拒绝关闭，它会继续运行 | 托盘退出 RTSS，或在 RTSS 里关掉 OSD / 把限帧设为 0 |
| 全屏模式被迫降级 | 置顶窗口会阻止游戏进入独占全屏/独立翻转，游戏退化成窗口化走 DWM 合成 → 帧率明显下降，而且**要重启游戏才能恢复**（这就是"退出桌宠也没用"的典型情形） | 玩之前右键取消置顶（会记住），或把 `config.json` 的 `untopInGame` 设为 `true`（检测到游戏时自动取消置顶，游戏结束自动恢复） |

`tools\check_system_load.ps1` 一次性给出：桌宠实例数与 CPU、常驻相关进程（含是否可被结束=是否提权）、
六个窗口的置顶状态、GPU 当前利用率；并提示怎么判读。

## 交互（位置固定，只有整体缩放）

| 操作 | 效果 |
|---|---|
| 拖动任意组件 | **整组刚性移动**（五个组件相对排布恒定，可跨屏、可骑跨屏幕边界） |
| 滚轮（任意组件上） | **整体缩放**：组件尺寸与相互间距同比例缩放（锚点=人物左上角） |
| 左键单击人物 | 循环切换动作（7 个姿势）并说一句；手动选的姿势最多保持 5 分钟 |
| 左键单击泡泡酱 | 切换 FPS 监控屏（千夏=主屏 / 南宫 / 爱芮），**位置不动**，名字同步；单屏时只换名字并口头提醒，属正常 |
| 右键任意组件 | 说句话 / 换个动作 / 复位布局与缩放 / 切换监控屏 / **开机自启开关**（菜单实时显示当前状态）/ 置顶 / 退出 |

没有逐组件移动/缩放，也没有"锁定布局"开关（位置本来就固定）。基准排布与单组件基础尺寸改
`config.json` 的 `layout`，或用右键"复位布局与缩放"回到默认。**个性气泡永远在最上层**（每 5 秒随其它组件一起重申置顶，且显示时立即抬到最前）。

### 人物动作什么时候会变？（回答"除了点击，会不会自己随机换"）

**不会随机换**。动作只在这三种情况下变：

| 触发 | 说明 | 频率 |
|---|---|---|
| 情绪状态变化 | 由数据决定（见下表），带 6 秒确认 + 20 秒最小驻留，避免抖动 | 状态真的变了才换 |
| 同情绪内的变体轮换 | 在该情绪的姿势池里重挑（`config.json` 的 `rotateSec`，默认 60 秒） | 目前只有"游戏中高帧"的池有 2 个姿势（庆祝↔加油），其余池都是 1 个 → 实际上不换 |
| 你左键点击人物 | 依次循环 7 个姿势，手动选的姿势最多保持 5 分钟（或直到情绪状态变化） | 即时 |

想要更活泼：在 `config.json` 的 `statePoses` 给某个情绪多配几个姿势（如 `"idle": ["idle","sleepy"]`），或调小 `rotateSec`。

### 台词与情境的对应（`assets/lines.json`，12 个池 / 49 条）

| 触发条件 | 台词池 | 条数 |
|---|---|---|
| RTSS 读不到（未启动） | `nortss` | 2 |
| GPU≥85% 或 CPU≥88% 或 内存≥92% | `worried` | 4 |
| 游戏中 且 FPS≥75 | `skill_praise` | 5 |
| 游戏中 且 36≤FPS≤74 | `game_eval` | 6 |
| 游戏中 且 1≤FPS≤35 且 负载≥55 | `comfort_lag` / `encourage`（各半） | 4 / 5 |
| 情绪=thinking（未游戏、负载≥60） | `busy` | 4 |
| 情绪=sleepy（白天、负载≤15） | `sleepy` | 3 |
| 情绪=asleep（23:00–07:00、负载≤15） | `night` | 2 |
| 其他（默认闲聊） | `browsing` | 8 |
| 点击人物换姿势时 | `idle_switch` | 4 |
| 单屏时点击泡泡酱（没有别的屏可切） | `single_screen` | 2 |

台词按情境挑选后会插入实时数据（`{fps}`/`{cpu}`/`{gpu}`/`{mem}`/`{load}`），并在日志里留一行
`say [长度] pool=<池> emo=<情绪> mode=… load=… :: 内容`，可以直接核对"什么情况说了什么话"。

### 气泡文字不会溢出

气泡的可写区域不是整个图，而是美术的内框（实测 `bubble_fill.png`：左右各约 10%、上 16%、下 11%）。
程序按这个内框设内边距，并且**每条台词都会用 `FormattedText` 实测行数**，装不下就自动缩字号（最多缩到 55%），
所以再长的台词也不会画到气泡外面。`petcmd.txt: linetest` 可对全部台词做一次装填体检。

## 配置（`config.json`）

```json
{ "cfgVer": 6, "screenIdx": 0, "topmost": true, "untopInGame": false, "groupScale": 1.0,
  "rotateSec": 60, "bubbleDy": 105, "side": "L",
  "emo": { "celebrateFps": 90, "worriedGpu": 85, "worriedCpu": 88, "worriedMem": 92,
           "thinkFpsMax": 35, "thinkLoad": 55, "busyLoad": 60, "idleLoad": 15,
           "nightStart": 23, "nightEnd": 7, "holdTicks": 3, "minDwellSec": 20, "evalSec": 2 },
  "statePoses": { "happy": ["celebrate","cheer"], "worried": ["surprised"],
                  "thinking": ["thinking"], "idle": ["idle"],
                  "sleepy": ["sleepy"], "asleep": ["sleeping"] },
  "layout": { "pet": {"x":2766,"y":962,"s":1.15}, "panel": {"...":{}}, "...": {} } }
```

- `layout` = **固定的基准排布**（绝对物理坐标 + 各组件自身缩放）；`groupScale` = 滚轮控制的全局缩放。
- 运行时几何 = `基准人物左上角 + (基准坐标 − 基准人物左上角) × groupScale`，尺寸 = `基准s × groupScale`。
  拖动只改基准，滚轮只改 `groupScale`，所以**反复缩放不会漂移**。

**情绪判定顺序**（`statePoses` 决定每个情绪用哪些姿势，一个情绪多个姿势时按 `rotateSec` 轮换）：

| 优先级 | 条件 | 情绪 |
|---|---|---|
| 1 | GPU≥85% 或 CPU≥88% 或 内存≥92% | worried（惊讶） |
| 2 | 游戏中 且 FPS≥90 | happy（庆祝/加油） |
| 3 | 游戏中 且 1≤FPS≤35 且 max(CPU,GPU)≥55 | thinking（思考） |
| 4 | 游戏中 且 负载≥60（帧率中等但机器吃满） | thinking |
| 5 | 未游戏 且 负载≥60 | thinking |
| 6 | 未游戏 且 负载≤15 且 23:00–07:00 | asleep（安睡） |
| 7 | 未游戏 且 负载≤15（白天） | sleepy（犯困） |
| 8 | 其他 | idle（待机） |

## 自动化钩子（测试/脚本用）

向 `runtime\petcmd.txt` 写一行即被执行（读后即删，每次一条）：

`quit` · `say` · `state` · `diag` · `hittest:<组件>` · `shot` · `reload` · `menu` · `pose:<名>` ·
`screen:<序号>` · `sayfrom:<池名>` · `saytext:<任意文字>` · `linetest` ·
`uclick:<组件>` · `udrag:<组件>:<dx>:<dy>` · `uwheel:<增量>`

- `sayfrom:<池>` / `saytext:<文字>`：把指定的台词写进气泡（验证排版/装填用）。
- `linetest`：对 `lines.json` 里全部台词逐条跑"装填体检"，日志给出每条的字号与是否可以装下。

`uclick`/`udrag`/`uwheel` 只驱动**逻辑**（不经过 Windows 输入通路），因此"逻辑全过但真机点击无效"是可能的
——交互类改动必须用 `tools\input_test.ps1` 做真实输入验收。

## 工具（`tools\`）

| 脚本 | 用途 |
|---|---|
| `smoke_test.ps1` | 逻辑/几何验收：语法、进程、六窗几何、钩子、拖动落盘与回滚、整体缩放、渲染转储（16 项） |
| `input_test.ps1` | **真实鼠标输入**验收：点人物、点泡泡酱、滚轮、拖动（4 项；会移动真实光标并复原） |
| `pet_info.ps1` | 进程 + 六个窗口的物理矩形 + 日志尾部 |
| `rtss_dump.ps1` | 打印 RTSS 共享内存全部条目（**游戏实机验证用**：确认游戏进程被钩住且是前台） |
| `screenshot_desktop.ps1` | 抓真实桌面像素到 `runtime\shots\`（含置顶分层窗） |
| `check_system_load.ps1` | 掉帧排查：桌宠实例/CPU、常驻相关进程（含提权标记）、窗口置顶状态、GPU 利用率 |
| `ps_alias_audit.py` | 审计 pet.ps1 的 PowerShell 变量同名覆盖陷阱（改完必跑） |
| `restart_pet.ps1` / `check_syntax.ps1` | 重启 / 语法检查 |

## 已知边界

- 浏览器/视频播放的帧数拿不到（RTSS 钩不进 Chromium GPU 沙箱）；游戏正常。
- **RTSS 必须在游戏之前启动**才会被钩住；未运行时面板显示刷新率并提示。桌宠启动时会自动把已安装的 RTSS 拉起（若系统弹确认框点"是"即可）。
- RTSS 以管理员权限运行（官方要求）：桌宠退出时若系统拒绝关闭它，RTSS 会继续运行，可从其托盘菜单手动退出；桌宠下次启动会继续自动管理。
- GPU 利用率走 NVIDIA 驱动接口（NVML），**N 卡自动可用**；其他品牌显卡该数字会显示 0%，其余功能不受影响。
- "FPS/游戏中" 判定要求游戏窗口在**当前选中屏**上；UWP 游戏宿主 pid 可能匹配不上 → 落回日常模式。
- 姿势放大到约 1.6× 以上时画面会有轻微软化。
- 内存稳态约 255–265MB（WPF 基线 + 单段 clip 约 32MB 位图）；快速连续切姿势时峰值可到 ~360MB（后台 GC 会回落，实测无泄漏）。

## 目录结构

```
ZZZ-Sunna-PerfMonitor/
├── pet.ps1            主程序（纯 ASCII，路径自 $PSScriptRoot 推导，可任意目录放置）
├── config.json        首次运行自动生成（布局/阈值/台词开关都在这里改）
├── assets/
│   ├── wpm/           7 个姿势的帧动画（151 帧 @30fps BGRA）
│   ├── panel|bubble|accessory/   面板/气泡/配件美术
│   ├── ui.json        界面文案与屏幕昵称（names 数组，默认 千夏/南宫/爱芮，可改）
│   ├── lines.json     12 个情境池 / 49 条台词（可自行增删，改完 petcmd.txt 写 reload 生效）
├── daemon/            启动器（vbs）、RTSS 一键安装、守护与提权任务注册
├── tools/             验收与诊断：smoke_test / input_test / rtss_dump / check_system_load 等
├── Redist/            RTSS 官方原版安装包（一键安装用，未修改）
```

## 常见问题

- **双击 pet.ps1 没反应 / 提示禁止运行脚本**：用启动器 vbs，或右键 pet.ps1 →"使用 PowerShell 运行"；
  启动器内部已带 `-ExecutionPolicy Bypass`，不需要改系统策略。
- **杀毒软件提示**：脚本行为只有读传感器、开无边框小窗、写自己的 runtime 目录，可加入信任。
- **换了显示器 / 拔掉副屏**：桌宠会在 5 秒内自动回到最近的可见屏幕，重启也不会丢。
- **游戏里帧率不对 / 怀疑桌宠拖慢游戏**：见上方"游戏掉帧了？先分清是谁的锅"，或跑 `tools\check_system_load.ps1`。

## 许可

代码部分以 MIT 开源（见 LICENSE）。**制作人：洛星舞（LuoXingwu）**。

**美术素材（`assets/` 全部内容：人物立绘、帧动画、面板/气泡/配件美术等）版权归制作人洛星舞所有**，
随包分发仅供个人使用；**转发、二次分发或转载请注明制作人洛星舞**，并保留本 README 与 LICENSE。

`Redist\` 内的 RivaTuner Statistics Server 安装包为**官方原版**（© Unwinder / Guru3D，
免费软件），为方便用户随包附带、未做任何修改；RTSS 的权利归其作者所有。
