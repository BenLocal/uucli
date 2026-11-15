# 代码 checklist（强制自检）

> 写完 / 改完代码必须逐条对照的硬性自检清单；新增条目直接追加本文件。

本文件由 `AGENTS.md`（即 `CLAUDE.md`）拆出，收敛「写代码时必须逐条自检」的硬性条目。顶层只留一条强制指针，条目细节都在这里；新增条目直接追加到本文件，不要写回 `AGENTS.md`。

uucli 只有一种语言（Zig 0.17.1，外加 `vendor/` 里少量 C 配置），所以没有按语言拆分的专项文件。行为契约以 `docs/spec.md` 为准，本清单只收「改代码时最容易违反、违反了后果最重」的红线。

## 怎么写一条 checklist

每条包含四部分，前三部分缺一不可——只写规则不给例子，下一个 agent 照样会踩：

1. **规则**：一句话说清「必须怎样 / 禁止怎样」。
2. **反例**：真实踩过的写法，标明后果。
3. **正例**：照抄就对的写法。
4. **强制**：由什么自动拦下，写成 `强制：<测试名 / 命令>`；只能靠人判断的写 `强制：无（靠自检）`。

条目来源优先级：**真机 / 线上问题 > 评审反复提的意见 > 团队口头约定**。软性建议归 `coding-guidelines.md`。

---

## 1. 线上协议必须和上游逐字节一致

签名、请求头、protobuf 编码、envelope、echo、端口映射帧、SDP 处理，错一个字节服务器或主机就会拒绝，而且报错往往只是「超时」或「被拒」。

- 反例：凭读上游 Rust 代码手工改 `wire.zig` 的字段号或编码顺序，本地单测自己和自己比对通过，真机连接直接失败。
- 正例：改 `api.zig` 签名 / 请求头或 `wire.zig` 编码时，确认 `src/vectors_test.zig` 覆盖了这条路径并通过；`tests/vectors/*.json` 是上游代码算出的标准答案，**不要手改**。新协议字段先在 `docs/spec.md` 写明来源（上游文件或真机抓到的报文）再实现。
- 强制：`zig build test`（`src/vectors_test.zig`）。

## 2. stdout 只放结果；任何日志级别都不输出凭据和用户内容

spec §3.1：日志、进度、提示、二维码走 stderr；`--json` 时 stdout 只有一个 JSON 文档。token、csrf、QR ticket、room token、ICE 凭据、终端内容、文件内容在任何日志级别都不能打印。agent 和脚本靠 stdout 解析结果，混进一行日志就解析失败。

- 反例：为排查方便 `log.debug("{s}", .{resp.data})` 打出整个登录响应体；或把提示信息 `print` 到 `app.out`。
- 正例：只记录状态码和截断后的状态 JSON，例如 `log.info("open: code {d}: {s}", .{ code, body[0..@min(body.len, 200)] })`（OPEN_RESP 只含 `{code,message}`）；面向用户的提示写 `app.err`。
- 强制：无（靠自检）。改了输出路径时，用 `uucli … -j | python3 -m json.tool` 实跑确认 stdout 仍是合法 JSON。

## 3. 改行为就同步改 spec

`docs/spec.md` 是命令行契约、退出码、协议格式和验收结果的唯一来源。改了命令、参数、退出码、协议字段或真机结论而 spec 没跟上，下一个 agent 会照旧文档写出错的代码。

- 反例：给 `terminal` 加了新参数，只改了 `--help`，spec §3.4 / §11.1 没动。
- 正例：同一个提交里改代码、`--help`、README 和 spec 对应小节；真机结果写进 spec §12 的记录表并带日期。
- 强制：无（靠自检）。

## 4. 测试用 `std.testing.allocator`，不漏内存

测试分配器在测试结束时报告泄漏并让测试失败。e2e 测试里异步事件在循环结束后还会入队，最容易漏释放。

- 反例：fake host 停止读取后，队列里剩下的 WS / RTC 事件没人释放，测试报 leak（2026-11-15 修过，见 `src/e2e_test.zig` 的 `Host.drain`）。
- 正例：每个 `alloc` / `dupe` 紧跟 `defer` 或 `errdefer` 释放；有队列的地方在退出路径上 drain 并释放剩余元素。
- 强制：`zig build test`。

## 5. I/O 走 `std.Io`；libdatachannel 回调只在 `rtc.zig` 里碰

spec §2、§8：libdatachannel 在自己的线程上回调，回调里只复制数据并推进 `Io.Queue`。别的模块直接碰回调线程或 libdatachannel 句柄会引入数据竞争；调用 `rtcCleanup()` 会和库自身的异步关闭死锁。

- 反例：在 `tools/*.zig` 里注册 libdatachannel 回调，或在回调里做阻塞操作。
- 正例：新事件类型加到 `rtc.zig` 的事件定义里，由 `session.zig` 分发给工具。
- 强制：无（靠自检）。

## 6. 每个源文件以 SPDX 头开头

项目是 GPL-3.0-or-later（spec §2），每个源文件第一行必须是 `// SPDX-License-Identifier: GPL-3.0-or-later`（`.service` 文件用 `#`）。

- 正例：新文件第一行写 SPDX 头；移植自上游的模块在文件头或 spec §9 注明对应的上游文件。
- 强制：`git ls-files '*.zig' '*.h' '*.c' | xargs grep -L SPDX-License-Identifier` 输出必须为空。

## 7. 不把真实设备名、账号信息、密码写进仓库

设备名、账号名、密码、登录配置都属于个人信息。示例统一用 `office-pc`、`me` 这类占位名。

- 反例：2026-11-15 把真实 Windows 主机名写进 spec 的实机记录并推送，事后只能改写提交并强推。
- 正例：实机记录写成「Windows host」「Mac host」；需要命令里带密码时只放进环境变量，不写进文件、日志和提交信息。
- 强制：无（靠自检）。提交前看一遍 `git diff --staged`。

## 8. 不引入新依赖，不升级工具链和锁定版本

C 依赖（libdatachannel、libjuice、usrsctp、plog、Mbed TLS、qrcodegen）按 hash 锁定在 `build.zig.zon`；Zig 版本锁定 0.17.1；上游参考锁定在 `v0.2.59`。升级任何一项都是 spec 层面的变更（spec §2、§13 的 drift log）。

- 正例：需要新能力先查 Zig 标准库和已有依赖；确需升级时先改 spec 写明原因，再单独提交。
- 强制：无（靠自检）。
