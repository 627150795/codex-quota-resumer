# Codex Quota Resumer

给 **Windows + Codex Desktop** 用的本地小工具：当 Codex 额度快用完或已经用完时，帮你备份待继续的任务，等额度恢复后自动投回同一个 Codex 线程。

它还带一个右下角托盘 watcher：Codex Desktop 打开时自动启动，Codex 关闭后自动停下；点托盘图标可以看当前等待重投的任务。

**English Summary:** A local Windows helper for Codex Desktop. It backs up pending messages near quota limits and replays them after quota recovers. This is not an official stable Codex automation API.

## 它能做什么

- 监控一个指定的 Codex 线程。
- 额度接近用完时备份你后续发的任务。
- 额度恢复后自动把任务发回原线程。
- 支持 Windows 通知和托盘图标。
- 本地保存日志，方便排查问题。

## 使用前准备

需要：

- Windows 11
- Codex Desktop 已安装并能正常登录
- Node.js 可用
- Codex CLI 可用

先确认：

```powershell
node --version
codex --version
```

如果 `codex --version` 不存在，请先安装或修复 Codex CLI。

## 安装

```powershell
git clone https://github.com/627150795/codex-quota-resumer.git
cd codex-quota-resumer
```

也可以直接下载 ZIP，解压后进入项目目录。

## 获取 threadId

`threadId` 是你要自动续跑的 Codex 线程 ID。

推荐从 Codex Desktop 里复制当前线程链接，再用 PowerShell 提取：

```powershell
$url = Read-Host "Paste Codex thread link"
[regex]::Matches($url, "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}") | ForEach-Object Value
```

不要把真实 `threadId` 发到公开截图、公开仓库或群里。

## 手动启动

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -ThreadId "你的 Codex threadId"
```

## 安装托盘 watcher

想让它登录 Windows 后常驻，并随 Codex Desktop 自动启停：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-watcher-startup.ps1 -ThreadId "你的 Codex threadId"
```

卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall-watcher-startup.ps1
```

## 数据和隐私

默认数据目录：

```text
.codex-quota-resumer/
```

里面可能包含任务内容、线程 ID、日志和图片副本。不要把这个目录上传 GitHub，也不要放在 OneDrive、Dropbox、iCloud、公司共享盘等会自动同步的位置。

## 限制

- 这个工具依赖当前可用的 `codex app-server --stdio`，不是 OpenAI 官方承诺稳定的自动化接口。
- 一个 watcher 默认绑定一个 `threadId`。
- 多窗口同时打开时，它只判断 Codex Desktop 是否运行，不判断当前激活窗口是哪条线程。
- 自动重投成功只代表 user message 已发回线程，后续回复是否完整仍取决于当时额度、网络和模型状态。

## 快速自检

推广或安装前建议确认：

- `node --version` 和 `codex --version` 正常。
- 手动启动命令能跑起来。
- watcher 安装后右下角能看到托盘图标。
- 托盘菜单能打开日志。
- 卸载脚本能删除启动项。
