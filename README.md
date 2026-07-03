# Codex Quota Resumer

Codex Quota Resumer 是一个给 **Windows + Codex Desktop** 使用的本地小工具。它在 Codex 额度接近用完时监控指定线程，备份后续 user message；如果额度耗尽，它会读取恢复时间，并在恢复后把备份任务重新投递到同一个 Codex 线程。

它还带一个 Windows 托盘 watcher：Codex Desktop 打开时启动 resumer，Codex 关闭时停止 resumer，并在右下角托盘显示等待重投的任务。

## 前提

已验证环境：

- Windows 11：`Microsoft Windows NT 10.0.26200.0`
- Windows PowerShell：`5.1.26100.7019`
- Node.js：`v24.14.0`
- Codex CLI：`codex-cli 0.142.3`
- Codex Desktop：需要已安装并能正常登录使用

使用前确认这些命令可用：

```powershell
node --version
codex --version
```

如果 `codex --version` 不存在，先安装或修复 Codex CLI。这个项目依赖 `codex app-server --stdio`，只安装 Codex Desktop 但没有可用的 `codex` 命令时不能运行。

## 下载后进入目录

用 Git clone：

```powershell
git clone https://github.com/627150795/codex-quota-resumer.git
cd codex-quota-resumer
```

或从 GitHub 下载 ZIP 后：

```powershell
Expand-Archive .\codex-quota-resumer-main.zip -DestinationPath .
cd .\codex-quota-resumer-main
```

下面所有命令都假设你已经在项目目录里，也就是能看到 `start.ps1`、`watch-codex.ps1` 和 `codex-quota-resumer.mjs` 的目录。

## 获取 threadId

`threadId` 是目标 Codex 线程的内部 id。resumer 必须知道它要把任务重投到哪个线程。

推荐按这个顺序找：

1. 在 Codex Desktop 打开你要续跑的线程。
2. 如果 UI 有复制线程链接、分享链接、Copy Link、Open in Browser 等入口，复制链接。
3. 把链接粘到 PowerShell 里提取 UUID：

```powershell
$url = Read-Host "Paste Codex thread link"
[regex]::Matches($url, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") | ForEach-Object Value
```

4. 如果 UI 没有链接入口，尝试从本机 Codex 日志或状态文件里搜索最近出现的线程 id：

```powershell
$roots = @("$env:APPDATA", "$env:LOCALAPPDATA", "$env:USERPROFILE\.codex")
Get-ChildItem $roots -Recurse -File -ErrorAction SilentlyContinue |
  Select-String -Pattern "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}" -ErrorAction SilentlyContinue |
  Select-Object -First 50 Path, LineNumber, Line
```

5. 如果 UI 链接和本机日志都拿不到，当前版本没有一个稳定公开的“列出当前线程 id”命令；你需要自己从当前线程链接、开发者工具、日志或其他本机状态里确认 thread id。

不要把真实 `threadId` 提交到公开仓库或截图发到公开渠道。

## 手动启动

PowerShell 默认可能拦截本地脚本。最可复制的启动方式是对当前命令使用 `ExecutionPolicy Bypass`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -ThreadId "你的 Codex threadId"
```

也可以直接跑 Node 脚本：

```powershell
node .\codex-quota-resumer.mjs --thread-id "你的 Codex threadId"
```

常用参数：

```powershell
node .\codex-quota-resumer.mjs --thread-id "..." --high-risk-percent 90
```

- `--high-risk-percent`：达到多少额度使用百分比后开始高频监控和备份，默认 `95`。
- `--data-dir`：状态、日志、备份目录，默认 `.codex-quota-resumer`。
- `--no-notify`：关闭 Windows 通知。
- `--once`：只检查一次额度，适合测试。
- `--replay-now latest`：立刻重投最近一条未完成备份。

## 安装 watcher

安装“登录后常驻 watcher”：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-watcher-startup.ps1 -ThreadId "你的 Codex threadId"
```

安装脚本会：

- 在 Windows 启动目录创建 `Codex Quota Resumer Watcher.lnk`。
- 立即以隐藏窗口启动 `watch-codex.ps1`。
- watcher 每隔一段时间检查 Codex Desktop 是否运行。
- Codex Desktop 运行时启动 resumer；Codex 关闭时停止 resumer。
- 托盘图标可双击查看等待重投的任务，右键可打开日志或退出。

## 卸载 watcher

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall-watcher-startup.ps1
```

卸载脚本会删除启动目录里的 watcher 快捷方式。已经运行中的托盘 watcher 如果还在，右键托盘图标选择 `Exit` 退出；或重启 Windows。

## 数据和隐私

默认数据目录：

```text
.codex-quota-resumer/
```

里面会保存：

- `state.json`：线程 id、备份状态、待重投任务、prompt 文本预览和完整消息内容。
- `resumer.log`：运行日志、额度读取、重投状态、错误信息。
- `watcher.log`：watcher 启停、托盘通知、异常信息。
- `backups/`：本地图片副本。脚本会把 user message 里的本地图片复制一份到这里。

这些文件默认不会上传 GitHub，但它们可能包含 prompt、图片路径、图片副本、线程 id 和任务内容。不要把项目放在 OneDrive、Dropbox、iCloud、公司共享盘或会自动同步/共享的目录里。不要把 `.codex-quota-resumer/` 打包给别人。

## 限制和风险

这个项目依赖 Codex Desktop 当前可用的 `codex app-server --stdio` 能力。它不是 OpenAI 官方承诺稳定的自动化接口；如果 Codex Desktop 或 Codex CLI 调整 app-server 协议、事件名、字段结构、鉴权方式或额度返回格式，脚本可能失效，需要同步更新。

多窗口和多线程限制：

- 一个 watcher 安装只绑定一个 `threadId`。
- 多个 Codex Desktop 窗口同时打开时，watcher 只判断 Codex Desktop 进程是否存在，不会自动识别当前激活窗口属于哪个线程。
- 如果你想监控另一个线程，需要卸载后用新的 `threadId` 重新安装，或手动启动另一份并指定不同 `--data-dir`。
- 不建议多个 resumer 同时监控同一个 `threadId`，可能重复备份或重复重投。
- 已经重投到线程的任务只表示 user message 可见；Codex 后续是否完整生成 assistant 回复，仍取决于当时额度、网络和模型请求状态。

## 推广前测试 checklist

发布给陌生用户前，至少在干净目录跑一遍：

- `node --version` 和 `codex --version` 都能输出版本。
- 从 GitHub clone 或 ZIP 解压后，按 README 的 `cd` 步骤能进入正确目录。
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -ThreadId "..."` 能启动。
- 用错误或不存在的 `threadId` 测试时，错误信息能在 `.codex-quota-resumer/resumer.log` 里看到。
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\install-watcher-startup.ps1 -ThreadId "..."` 会创建启动目录快捷方式，并出现托盘图标。
- Codex Desktop 关闭后，watcher 会停止 resumer；重新打开 Codex Desktop 后会再启动。
- 托盘右键 `Open log` 能打开日志。
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall-watcher-startup.ps1` 会删除启动目录快捷方式。
- `.codex-quota-resumer/` 没有被 Git 跟踪，且没有放在同步盘/共享目录。
- 在当前 Codex Desktop/CLI 版本上确认 `codex app-server --stdio` 协议仍可用。
