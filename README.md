# Codex Quota Resumer

这是一个给 Codex Desktop 用的本地小程序：当 Codex 额度接近用完时，它会开始轻量监控当前线程的新消息；如果额度用尽，它会备份你后续发出的任务，读取额度恢复时间，并在恢复后把任务重新投递回原来的 Codex 线程。

它解决的问题很简单：你不用盯着额度刷新，也不用手动复制失败任务。额度恢复后，小程序会自动把已备份的任务续上。

## 功能

- 监控 Codex Desktop 的额度使用情况。
- 额度高风险时备份当前线程的新 user message。
- 支持备份文本和本地图片路径；图片会复制到本地备份目录。
- 额度耗尽后读取恢复时间，自动安排恢复后重投。
- 重投到同一个 Codex threadId。
- 用 Windows 通知弹窗提示备份、安排、重投成功或失败。
- 本地保存状态和日志，方便排查。

## 使用

先确认本机能运行：

```powershell
node --version
codex --version
```

启动监控：

```powershell
.\start.ps1 -ThreadId "你的 Codex threadId"
```

安装成“登录后常驻 watcher”：watcher 会低频监控 Codex 桌面进程；Codex 打开时启动续跑小程序，Codex 关闭时关闭续跑小程序。
右下角会出现一个蓝色 `C` 托盘图标，双击可以查看等待发送的任务；任务一旦投递到线程，就不会再出现在等待列表里。

```powershell
.\install-watcher-startup.ps1 -ThreadId "你的 Codex threadId"
```

卸载：

```powershell
.\uninstall-watcher-startup.ps1
```

也可以直接运行：

```powershell
node .\codex-quota-resumer.mjs --thread-id "你的 Codex threadId"
```

`threadId` 可以从 Codex 线程链接、日志或你自己的测试脚本里取得。不要把真实线程 ID 上传到公开仓库。

## 常用参数

```powershell
node .\codex-quota-resumer.mjs --thread-id "..." --high-risk-percent 90
```

- `--high-risk-percent`：达到多少百分比后开始高频监控和备份，默认 `95`。
- `--data-dir`：状态、日志、备份目录，默认 `.codex-quota-resumer`。
- `--no-notify`：关闭 Windows 弹窗。
- `--once`：只检查一次额度，适合测试。
- `--replay-now latest`：立刻重投最近一条未完成备份。

## 通知

`backup-saved` 和 `replay-scheduled` 会写入 `state.json` 的 `notificationEvents`，同时尝试直接调用 Windows 气泡提示。watcher 托盘会用常驻托盘图标消费这些事件，写入 `shownAt`，并在 `watcher.log` 记录 `notification-shown`。普通高风险轮询和正常 user message 不会创建通知事件。

## 成功标准

小程序把任务重新投递到线程后，会检查线程记录里是否能读到对应的 user message。只要读到，就标记为 `visible_in_thread`。

Codex 后续能不能生成完整 assistant 回复，仍然取决于 Codex 当时的额度、网络和模型请求状态。

## 数据位置

默认数据目录：

```text
.codex-quota-resumer/
```

里面会有：

- `state.json`：备份和重投状态。
- `resumer.log`：运行日志。
- `backups/`：图片等本地备份。

这些文件不会上传到 GitHub。

## 注意

这个项目依赖 Codex Desktop 当前可用的 `codex app-server --stdio` 能力。它不是 OpenAI 官方发布的稳定自动化接口；如果 Codex Desktop 以后调整 app-server 协议，需要同步更新脚本。
