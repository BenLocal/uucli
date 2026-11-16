# 实机验证经验

> 对官方 Windows / Mac 被控端做实机验证时踩过的坑：被控端状态、主控端互斥、解锁、官方 CLI 对照。

- 2026-11-15 Windows 被控端打开终端返回 `401 device_not_logged_in` → 原因是被控端**锁屏**，不是账号没登录、也不是协议问题 → 先把被控端解锁到桌面再连。佐证：同一时刻官方 `uuyc-cli term -d DEVICE list` 也失败（`Terminal environment check timed out`，code 105）；解锁并断开其他主控端后，uucli 不发任何密码就打开了终端并执行命令成功。
- 2026-11-15 加入房间返回 API `2002`（uucli 报 `the device is being controlled from another device`，退出码 6）→ 被控端同一时间只接受一个主控端，官方 app 的远程桌面窗口、app 里打开的终端都算 → 让用户在 app 里退出远控 / 终端页面后再试。注意本机 `uuyc-cli device status` 显示 0 个连接不代表没人占用，占用者可能是手机或其他设备上的 app。
- 2026-11-15 尝试由 uucli 自己发被控端系统密码完成验证，两种格式 Windows 被控端都**没有任何回应**：CONTROL 上的 SimpleAction `15 AUTO_UNLOCK_SYSTEM` + `{"key": …}`（上游 Linux 被控端的格式），以及 TERM 帧 `UNLOCK_REQ (14)` + `{"password": …}`（上游定义了常量但没人实现）。结论：这两条都不是官方 Windows 被控端接受密码的方式；真实格式未知，要做需从官方客户端找。
- 2026-11-15 官方帮助文档（uuyc.163.com 帮助页「UU远程终端怎么用」）：被控端锁屏时进终端前需要「系统账户验证」，用被控端的系统账户密码；Windows 被控端的自动验证只在 macOS / iOS / Android 主控端发起时生效。uucli 以 Windows 设备身份注册（`device/windows/init`），按文档推断它拿不到自动验证（待验证）。
- 2026-11-15 本机若装了官方 UU 客户端，`/usr/local/bin/uuyc-cli` 可作对照：它经 XPC 驱动官方 app，`uuyc-cli term -d DEVICE list|new` 能判断问题在 uucli 还是在被控端状态。它和 uucli 抢同一个被控端，对照完要断开。
- 2026-11-15 `files DEVICE ls` 对 Windows 被控端在会话就绪后 30 秒内没有应答（`the device did not answer in time`），对 Mac 被控端也一样；原因未查（待验证）。
- 2026-11-15 远程终端的输出是 ConPTY 屏幕流，夹着大量 ANSI 控制序列；用管道喂命令时要先 `sleep` 等提示符、命令以 `\r` 结尾，结果需要剥掉 ANSI 再找，建议在命令输出里打一个独特前缀（如 `MARK:`）再 grep。
- 2026-11-15 Windows 被控端上 `px` / `portmap` 能用：`ssh -o ProxyCommand='uucli px DEVICE 127.0.0.1 22' …` 完成密钥交换并走到认证阶段（被控端装有 Windows OpenSSH sshd）。前提同终端：被控端已解锁、没有其他主控端连着；否则会在会话就绪前失败（`control request refused by the host` 或 `signaling ended: RoomClosed`）。
- 2026-11-15 会话就绪前失败时 uucli 曾 double free 并 panic（`src/session.zig` 的 arena 被 `errdefer arena.deinit()` 和 `errdefer s.close()` 各释放一次）→ 已修，回归测试是 `src/e2e_test.zig` 的 "session open fails cleanly after the session exists"。看到 `SafeAllocator … in free … session.zig` 的栈，先确认装的是修复后的二进制。
- 2026-11-15 Windows 被控端的 ConPTY 输出常用 `ESC[row;colH` 定位光标代替 CR LF、用 `ESC[nC` 代替空格；只剥 ANSI 会把表格的多行粘成一行、找不到结束标记 → `exec` 的 Stripper 按行列跟踪光标（`src/tools/terminal.zig`）。实测 `Get-Service … | Select-Object` 的表格输出靠这个才正确。
- 2026-11-15 Windows 被控端上 shell 一执行完就 `exit`，最后一屏更新会丢（`Format-Table` 输出和结束标记都没到）→ PowerShell 包装行不带 `exit`，uucli 收到结束标记后自己关会话。佐证：同一命令去掉 `exit` 后连续多次都拿到完整输出。
- 2026-11-16 连上 Windows 被控端后 PowerShell 打出 PSReadLine 异常（`ArgumentOutOfRangeException ... top 实际值是 -1`，`上 1 个密钥: Ctrl+Enter`）→ 原因：输入验证码后、会话就绪前多按的回车，在本地终端还是 cooked 模式时被 ICRNL 转成 `\n` 留在输入缓冲，进入 raw 模式后原样发出；ConPTY 把 LF 当成 Ctrl+Enter，PSReadLine 执行 InsertLineAbove，光标在第一行时越界 → `tty.Raw.enter` 改用 `TCSAFLUSH` 丢弃进入 raw 前积压的输入。复现：cooked 模式下 `printf '\r\r'`，进入 raw 后读到 `{10, 10}`；修复后为空。连上之后再发 `\n` 不一定触发（光标已不在第一行）。
