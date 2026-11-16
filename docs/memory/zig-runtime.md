# Zig 运行时踩坑

> Zig 0.17 程序在不同平台上跑起来才暴露的问题：线程、TLS、信号。

- 2026-11-16 Linux 上 `uucli term` 一启动就 panic `reached unreachable code`（ReleaseSafe 栈指向 `Thread.zig` 的 `pthread_detach`，Debug 下实为 `pthread_create` 返回 `EINVAL`）→ Zig 0.17.1 默认 `std.options.signal_stack_size = 1 << 18`，每个线程带一块 256 KiB 的 threadlocal 备用信号栈，glibc 把静态 TLS 放在线程栈里，`interrupts.zig` 用 `.stack_size = 64 * 1024` spawn 时装不下；macOS 的 TLS 不占线程栈所以从没出过问题 → 不要给 `std.Thread.spawn` 指定小于 TLS 的栈大小，用默认值（16 MiB 只是虚拟预留）。实测：最小复现程序 256 KiB 失败、512 KiB 通过；`readelf -lW <bin> | grep TLS` 看 TLS 大小。回归测试：`src/interrupts.zig` 的 "install starts the reader thread and delivers SIGTERM to the bus"。
