# Zig 测试踩坑

> Zig 0.17 测试运行器的非显然行为：error 级日志算失败、输出里的 failed command 怎么读。

- 2026-11-15 Zig 0.17 的测试运行器把测试期间任何 `log.err` 都算失败（`run test N pass; 1 error logs`，构建步骤失败），而且没有放行预期错误日志的机制（查过 `lib/compiler/test_runner.zig` 的 `log_err_count`）→ 测失败路径时，选一条不走 `log.err` 的路径触发同一段代码（例如往 bus 放 `.interrupt` 让 `Session.open` 在建好会话后失败），不要为了测试降低产品代码的日志级别。
- 2026-11-15 `zig build test` 输出里出现 `failed command: …/test …` 不一定是失败：测试往 stderr 打了内容时也会这样显示（汇总里是 `run test stderr`）。以退出码和 `--summary all` 的 `Build Summary: X/Y steps succeeded` 为准。
- 2026-11-15 测试间歇性卡死（完整测试二进制直接循环跑，约 7/10 超时）→ 用 `sample <pid>` 抓到主线程停在 `Session.close` → `Io.Future.cancel`，信令读任务停在 `netReadPosix` 的阻塞 read 上：任务刚启动就被 cancel 时，`std.Io.Threaded`（macOS）的取消没能打断它（根因在标准库，未深究，待验证）→ 关闭时先 `shutdown` 读方向让 read 返回，再 cancel；修后 30/30 通过。排查卡死别信 `zig build test` 的重跑结果（通过后会被缓存，不会真的再跑），要直接循环跑 `.zig-cache/o/*/test`；循环前用 `pgrep -fl '.zig-cache/o/.*/test'` 确认没有残留的卡死进程。
- 2026-11-15 Zig 0.17 的 `@hasDecl` 看不到非 `pub` 的声明 → 用 `@hasDecl(Tool, "hook")` 探测的可选钩子必须写成 `pub fn`，否则静默不调用（`TerminalCmd.interrupted` 曾因此从未生效）。回归测试：`src/main.zig` 的 "tool hooks are visible to runToolSession"。
