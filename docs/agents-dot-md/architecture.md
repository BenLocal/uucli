# 系统架构

> 组件边界、一次连接的完整链路与关键设计取舍；动结构、加模块、改连接流程前先看本文。

本文是 `docs/spec.md` 的导读，只讲结构和取舍；格式、字段、超时等细节一律以 spec 为准（文中标了对应小节）。技术选型和命令见 `tech-stack.md`。

## 组件与调用方向

```text
              主控端（uucli，Linux / macOS）                              被控端（官方 UU 客户端）
 main.zig ──> api.zig ──HTTPS──> UU 云端 API（登录、设备列表、加入房间）
    │
    └──> session.zig ──> signal.zig ──> ws.zig ──WSS──> 信令服务（Socket.IO）<──> 被控端
              │
              └──> rtc.zig ──libdatachannel（ICE / DTLS / SCTP）──────────────> 被控端
              ▲        │ 事件队列（Io.Queue）
              │        ▼
         tools/portmap.zig · tools/terminal.zig · tools/files.zig
```

- Each process owns one `std.Io` instance. A background `__mux` process holds the shared connection; port streams run in parallel and terminal / exec / files clients take serial leases. `session start` keeps it open; automatic connections expire when idle (spec §7.2–§7.4).
- 依赖方向：`main` → `tools/*` → `session` → `api` / `rtc` / `signal` / `wire`；`tools/*` 只依赖 `session` 和 `wire`，彼此互不依赖；`login` → `api` → `config`；`signal` → `ws`。没有反向依赖，`rtc`、`wire`、`ws`、`config` 不依赖任何项目模块。

- Local management follows `main` → `mux` → `lease` / `tools/portmap` / `session`. `mux.Control` owns the keep flag and management requests; transport setup remains in `session`.

## 模块边界

| 模块 | 职责 | 不做什么 |
| --- | --- | --- |
| `main.zig` | 参数解析、简写、设备解析、退出码映射 | 不碰协议细节 |
| `config.zig` / `login.zig` / `api.zig` | 配置文件（权限、锁）、设备注册与扫码登录、REST 签名与错误码映射 | 不碰 WebRTC |
| `mux.zig` / `lease.zig` | Local socket identity, connection management, keep / idle state, and serial tool leases | No remote business protocol encoding |
| `session.zig` | 加入房间 → 信令 → WebRTC → echo → ready；把消息路由给工具 | 不理解工具的业务帧 |
| `rtc.zig` | libdatachannel 绑定，回调里只复制数据推进队列 | 其他模块都不直接碰 libdatachannel |
| `wire.zig` | protobuf 编解码、envelope、echo、connect options | 无 I/O |
| `tools/*.zig` | 各工具的业务协议（spec §7、§11） | 不直接收发信令 |

## 关键链路：`uucli term DEVICE`

1. `main.zig` 用 `device list` 把名字或 ID 解析成设备（spec §3.3）。
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

- 新工具 / 子命令：照 `tools/terminal.zig` 的结构写，`main.zig` 里用 `runToolSession(app, DEVICE, capture_type, …)` 接入；capture type 见 spec §6.3。
- 新的协议字段：先在 spec 里写明来源（上游文件或真机报文），再改 `wire.zig` 并补测试。
