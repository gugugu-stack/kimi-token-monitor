# Kimi Code token 用量监视器（kimi-token-monitor）

给 Kimi Code 桌面端加一个常驻的 **token 用量**监视器：一个可以拖动的小球显示 `↑输入 / ↓输出 / 命中率`，
双击展开成详细面板（按天/区间 × 当前会话/全部会话统计，含缓存读取、缓存命中率与 **API 请求次数**）。
数据全部来自本机客户端自己的会话事件文件，不联网、不上报。

## 效果

- **小球**：深蓝玻璃球 + 缓慢流动的噪波，竖排三行 token 信息，命中率颜色随数值绿→黄→红（低于 80% 开始转黄）
- **面板**：半透明卡片，可拖动；两个下拉框切换时间区间与统计范围。指标排成两列——
  第一行 `输入（非缓存）` / `缓存读取`，第二行 `输出` / `请求次数`，`缓存命中率` 单独一行。
  请求次数是精确计数而非估算（每次 LLM 调用恰好一条用量记录，`stepId` 不重复）
- **托盘图标**：任务栏通知区的蓝球 + 粗体 K，右键菜单可显示面板 / 显示小球 / 全部收起 / 退出
- **全局快捷键**：默认 `Ctrl + Alt + K`，有界面时收起、收起时唤出小球；可在面板的 ▼ 里改
- 位置、快捷键都记在文件里，重启客户端后恢复原样

## 安装

需要 Windows + Kimi Code 桌面端（自带 PowerShell 5.1，无需额外依赖）。

1. 把整个 `kimi-token-monitor` 文件夹放到 `%USERPROFILE%\.kimi-code\` 下
   （即 `C:\Users\<你>\.kimi-code\kimi-token-monitor\`，必须整个文件夹一起放，脚本互相引用）
2. 双击 `安装.cmd`（它会往 `config.toml` 写一条 SessionStart 钩子，并自动备份原配置）
3. 重启 Kimi Code —— 钩子只在会话启动时加载

之后每次启动客户端，小球或面板会自动出现。

## 卸载

双击 `卸载.cmd` 删掉钩子，再删掉这个文件夹即可。

## 会改动你机器的哪些地方

- `%USERPROFILE%\.kimi-code\config.toml`：增加一条 `[[hooks]]`（安装时备份成 `config.toml.bak-kimi-token-monitor-*`）
- 注册表 `HKCU\Control Panel\NotifyIconSettings`：把本程序的托盘图标设为「始终显示」
  （等同于你手动把它从 `^` 折叠区拖到任务栏）
- 全局快捷键占用 `Ctrl + Alt + K`（可在设置里改；被其他程序占用时会提示并回滚）

本文件夹内只会生成 `widget.state.json`（位置）、`widget.settings.json`（快捷键）、
`diag.log`（运行日志）、`widget.pid` 四个文件，都已在 `.gitignore` 里。

## 文件说明

| 文件 | 作用 |
|---|---|
| `start-widget.ps1` | 钩子入口：读取宿主传入的 JSON、单实例守卫、拉起主程序 |
| `usage-widget.ps1` | 主程序：面板 / 小球 / 托盘图标 / 全局快捷键 / 设置窗口 |
| `usage-core.ps1` | 数据层：扫描会话事件文件、按天分桶、区间统计、命中率配色 |
| `pet-render.ps1` | 绘制：球体（渐变 + 柏林噪波）、文字层、托盘图标 |
| `hotkey.ps1` | 全局快捷键（RegisterHotKey + NativeWindow 消息宿主） |
| `fonts/` | 数字用的拉丁字体（Schibsted Grotesk，含 OFL 许可文本） |
| `install.ps1` / `卸载.cmd` 等 | 安装与卸载 |

## 字体

- **数字与拉丁**：`Schibsted Grotesk`，与 Kimi Code 桌面端界面用的是同一款。
  随仓库分发在 `fonts/`（两个静态字面 Regular / Bold），由控件**进程内私有加载**——
  不装进系统字体列表，卸载即消失。文件缺失时数字会自动退回中文字体，功能不受影响。
- **中文**：`Noto Sans SC`，同样与客户端一致。这一款**不随仓库分发**，依赖系统已安装；
  没装则退回系统默认中文字体。
- 许可：Schibsted Grotesk 为 SIL OFL 1.1，全文见 `fonts/OFL.txt`。

## 已知限制

- 只支持**桌面端**：终端 TUI 启动时会自动跳过（`start-widget.ps1` 判断 `client_type`）
- 切换对话后要**在新对话里发一次言**数据才会更新——判据是「最近被写入的事件文件」，
  而不是客户端内部状态（试过订阅日志信号，会认错会话，已放弃）
- 客户端退出后本程序会在约 60 秒后自行结束（宽限是为了让客户端自动更新的秒级重启不误杀）
- 若客户端版本改了事件字段名（`inputOther` / `inputCacheRead` / `inputCacheCreation` / `output`），
  `usage-core.ps1` 需要跟着改
