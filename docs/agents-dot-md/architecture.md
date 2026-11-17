# 系统架构

> 组件边界、一次连接的完整链路与关键设计取舍；动结构、加模块、改连接流程前先看本文。

本文是 `docs/spec.md` 的导读，只讲结构和取舍；格式、字段、超时等细节一律以 spec 为准（文中标了对应小节）。技术选型和命令见 `tech-stack.md`。

## 组件与调用方向

```text
main.zig -> cmd/*.zig -> app.zig / target.zig
                     -> tool_runner.zig -> session.zig -> api / signal / rtc
                     -> mux_client.zig -- Unix socket --> mux_server.zig
                                                            -> mux / lease / session
```

- Each public top-level command owns one `cmd/<command>.zig` module with a `run(app, args)` entry.
  `main` initializes the process, parses global flags, resolves fixed aliases, dispatches commands,
  and maps uncaught errors. Commands do not import each other or `main`.
- `app` owns CLI context, configuration loading, output helpers and exit codes. `target` resolves
  devices and favorites and handles assistance codes. `tool_runner` runs tools on direct sessions
  or leases and owns interruption, teardown and direct portmap reconnects.
- `mux_client` starts the background process and handles local stream / lease connections.
  `mux_server` implements internal `__mux`; `mux.Control` owns keep / idle state and management.
  Shared modules never import command modules. Protocol modules remain under `tools/`.
- Each process owns one `std.Io` instance. Port streams share a background connection in parallel;
  terminal / exec / files take serial leases. `session start` keeps the connection open; automatic
  connections expire when idle (spec §7.2–§7.4).

## 模块边界

| 模块 | 职责 | 不做什么 |
| --- | --- | --- |
| `main.zig` | Process startup, global flags, fixed aliases and dispatch | No command execution logic |
| `cmd/*.zig` | Command-specific parsing, execution, output and tests | No protocol encoding |
| `app.zig` / `target.zig` | Shared CLI context, errors, config handling, device resolution and assistance codes | No command dispatch |
| `tool_runner.zig` | Direct / leased tool execution, interruption and reconnects | No command-specific parsing |
| `mux_client.zig` / `mux_server.zig` | Background process startup, Unix socket clients and internal server | No user command parsing |
| `config.zig` / `login.zig` / `api.zig` | 配置文件（权限、锁）、设备注册与扫码登录、REST 签名与错误码映射 | 不碰 WebRTC |
| `mux.zig` / `lease.zig` | Local socket identity, connection management, keep / idle state, and serial tool leases | No remote business protocol encoding |
| `session.zig` | 加入房间 → 信令 → WebRTC → echo → ready；把消息路由给工具 | 不理解工具的业务帧 |
| `rtc.zig` | libdatachannel 绑定，回调里只复制数据推进队列 | 其他模块都不直接碰 libdatachannel |
| `wire.zig` | protobuf 编解码、envelope、echo、connect options | 无 I/O |
| `tools/*.zig` | 各工具的业务协议（spec §7、§11） | 不直接收发信令 |

## 关键链路：`uucli term DEVICE`

1. `main` dispatches to `cmd/terminal.run`; `tool_runner` uses `target.resolveTarget` to resolve the name or ID (spec §3.3), then selects a shared lease or direct session.
2. `api.zig` 调 `room/join/by_device/{id}`；被控端正被别的主控端控制时返回 API `2002`，直接以退出码 6 结束（spec §6.1）。
3. `session.zig` 走 Socket.IO 信令发 offer、收 answer，`rtc.zig` 建立 ICE / DTLS 和 5 个数据通道，双方 echo 后进入 ready（spec §6）。
4. `tools/terminal.zig` 先发环境检查（官方 Windows 主机不回应，3 秒后视为不支持），再在 BINARY 通道发 `TERM` 帧 OPEN；成功后在 raw 模式下双向转发（spec §11.1）。
5. 退出时总是发 CLOSE；Windows 主机每个连接只有一个终端，断开即结束。

## 设计决策

- **自己注册设备身份，不复用官方客户端**（spec §2）：uucli 以独立设备登录同一账号，和本机的官方客户端互不干扰。代价是被控端把它当成另一台主控端，例如 Windows 被控端的「自动解锁」不对它生效。
- **协议照搬上游并用 golden vectors 锁住**（spec §10）：向量由上游 Rust 代码算出，Zig 实现逐字节比对；生成器已删除，需要重新生成时从提交 `aeff338` 找回。
- **libdatachannel 只在 `rtc.zig` 里出现，从不调用 `rtcCleanup()`**（spec §8）：回调线程和 Zig 的 I/O 模型之间只隔一个队列，避免数据竞争；`rtcCleanup()` 会和库自身的异步关闭死锁。
- **默认忽略环境代理**（spec §3.1）：会做 TLS 拦截的本地代理会让登录和信令失败；`UUCLI_USE_PROXY=1` 可以打开。
- 重新评估的信号：上游锁定版本前移、官方主机协议变化（记进 spec §13 的 drift log）、或需要支持新的被控端平台。

## 扩展点

- New commands live in `cmd/<name>.zig` and are dispatched from `main.run`. Follow `cmd/terminal.zig` / `cmd/files.zig` and call `tool_runner.runToolSession` for remote tools; capture types are defined in spec §6.3. Keep remote protocol implementation in `tools/`.
- 新的协议字段：先在 spec 里写明来源（上游文件或真机报文），再改 `wire.zig` 并补测试。
