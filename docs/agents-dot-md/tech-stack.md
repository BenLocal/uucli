# 技术栈与实现规范

> 技术选型、构建与验证命令、新代码照着写的既有实现；写代码前先看本文，按既有方式扩展。

本文回答「这个项目用了什么、新代码该照着什么写、改完怎么验证」。系统结构见 `architecture.md`，命令行契约和协议细节见 `docs/spec.md`，三处别重复。

## 项目定位

- uucli 是网易UU远程的**主控端**命令行工具（headless controller），跑在 Linux / macOS 上，主要给 agent 和脚本调用：列设备、远程终端、端口转发 / ssh ProxyCommand、单文件传输。
- 它不是被控端，也不做远程桌面（spec §1 的 non-goals）。被控端是官方 UU 客户端。
- 协议移植自上游 `VallierDev/uu-remote-linux` `v0.2.59`（Rust），每个模块对应的上游文件见 spec §9。

## 技术选型

| 层 | 选型 | 版本 | 备注 |
| --- | --- | --- | --- |
| 语言 / 运行时 | Zig | 0.17.1（`build.zig.zon` 的 `minimum_zig_version`） | 所有 I/O 走 `std.Io`（`std.Io.Threaded`） |
| WebRTC | libdatachannel（C API） | v0.24.6 | 由 `build.zig` 从源码编译，连同 libjuice、usrsctp、plog、Mbed TLS 静态链接；不带媒体 |
| TLS | Mbed TLS | 3.6.6 | 配置在 `vendor/mbedtls/uucli_mbedtls_config.h` |
| 二维码 | nayuki QR-Code-generator | v1.8.0 | 登录时在终端画二维码 |
| 构建工具 | `zig build` | — | 依赖按 hash 锁定，`.lazy = true` 按需下载 |

没有数据库、缓存、配置中心。配置是一个 JSON 文件（spec §4，`UUCLI_CONFIG` 可指定路径，权限 0600）。

## 构建与验证命令

```bash
zig version                      # 必须是 0.17.1；PATH 上的 zig 版本不对时换用 0.17.1 的二进制
zig build                        # 调试构建，产物 zig-out/bin/uucli
zig build test                   # 离线测试：单元测试 + 上游 golden vectors + 进程内 fake host 的 e2e
zig build test --summary all     # 看每个步骤是否成功
zig build test -Dtest-filter=名字 # 只跑名字含该字符串的测试
zig build -Doptimize=ReleaseSafe # 发布构建
zig build release                # 4 个平台的 tar.gz，写到 zig-out/release/
zig fmt --check <改动的文件>      # 只检查自己改的文件
```

- `zig fmt --check src` 目前会报 `src/main.zig` 等几个文件：Zig 0.17 想把 `@intFromEnum` 这类旧 builtin 改写成新名字，这是改动之前就有的。不要顺手整体重排格式，只保证自己新增的代码格式正确。
- `zig build test` 偶尔会在输出里打一行 `failed command: …`，但退出码是 0、汇总 15/15 成功；以退出码和 `--summary all` 为准。
- macOS 目标的 release 构建需要在装了 SDK 的 macOS 上跑（usrsctp 依赖 SDK 头文件）。

## 实机验证

离线测试覆盖不了真实主机的行为，改了连接、终端、端口映射、文件相关代码后要实机跑：

```bash
zig-out/bin/uucli login               # 首次：手机 UU app 扫码
zig-out/bin/uucli dev ls -j
zig-out/bin/uucli -v term DEVICE -l   # -v 能看到主机拒绝时返回的状态 JSON
```

被控端的状态会直接决定结果（锁屏、同时只接受一个主控端等），排查前先看 `docs/memory/` 里的实机经验。结果按日期记进 spec §12。

## 约定

- 提交：conventional commits，英文 subject + body，带 `Signed-off-by`；远端是 GitHub。
- 仓库里的代码注释、spec、README、提交信息一律英文（见 `translation.md`）。
- CLI 输出：结果进 stdout，其余进 stderr；列表类命令支持 `--json` / `-j`；退出码按 spec §3.2。
- 子命令和参数的简写是固定别名表（`src/main.zig` 的 `command_aliases`），不做前缀匹配；新增命令时决定是否加简写，并同步 `--help`、README 和 spec §3.5。

## 新增一个功能怎么落（照着既有实现抄）

以「给某个工具加一个子命令或参数」为例：

1. `src/main.zig` — 在对应的 `cmdXxx` 里解析参数，参照 `cmdTerminal` / `cmdFiles` 的写法；错误走 `usage(...)`（退出码 2）或 `app.fail(...)`。
2. `src/tools/<tool>.zig` — 实现协议交互，请求 / 应答用工具自带的 `request(...)`，参照 `Terminal.list` / `Terminal.open`。
3. `src/wire.zig` — 只有新的 protobuf 结构才需要改；改了就补 golden vector 或单元测试。
4. `src/e2e_test.zig` — 用进程内 fake host 补一条端到端测试。
5. `docs/spec.md`、`README.md`、`usage_text` — 同步命令说明。
