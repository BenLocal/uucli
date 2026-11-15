# Zig 测试踩坑

> Zig 0.17 测试运行器的非显然行为：error 级日志算失败、输出里的 failed command 怎么读。

- 2026-11-15 Zig 0.17 的测试运行器把测试期间任何 `log.err` 都算失败（`run test N pass; 1 error logs`，构建步骤失败），而且没有放行预期错误日志的机制（查过 `lib/compiler/test_runner.zig` 的 `log_err_count`）→ 测失败路径时，选一条不走 `log.err` 的路径触发同一段代码（例如往 bus 放 `.interrupt` 让 `Session.open` 在建好会话后失败），不要为了测试降低产品代码的日志级别。
- 2026-11-15 `zig build test` 输出里出现 `failed command: …/test …` 不一定是失败：测试往 stderr 打了内容时也会这样显示（汇总里是 `run test stderr`）。以退出码和 `--summary all` 的 `Build Summary: X/Y steps succeeded` 为准。
