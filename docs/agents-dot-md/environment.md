# 开发环境 / 推送 / 发布

> 工具链要求、凭据存放、推送与发布步骤。

## 开发环境

- Zig 必须是 **0.17.1**。本机 PATH 上可能是更旧的 zig（例如 Homebrew 的 0.15 / 0.16），它们构建本项目会在 `build.zig` 里报 `no field or member function named 'addPassthruArgs'` 一类的错误。先 `zig version` 确认；不对就换用 0.17.1 的二进制，不要为了旧版本改 `build.zig`。
- 首次 `zig build` 会下载 `build.zig.zon` 里的依赖到 Zig 全局缓存，之后离线可用。
- 实机验证需要先 `uucli login` 扫码登录。登录配置默认在用户配置目录，权限 0600，**不入库**；多账号用 `UUCLI_CONFIG` 指向不同文件。

> ⚠️ 服务器、账号、被控端系统密码等凭据**不入库**：放在本地未入库文件（如 `dev-env.local.md`，并加入 `.gitignore`），或只在命令的环境变量里临时使用。不要写进代码、spec、记忆文件或提交信息。

## Git 推送

- 远端：GitHub，`origin`。默认分支 `main`。
- 提交走 conventional commits，英文 subject + body，带 `Signed-off-by`（见 `tech-stack.md`《约定》）。
- 推送失败报 `Failed to connect to 127.0.0.1 port …` 时，是本机 git 配了代理但代理没开：先开代理再推，或让用户决定是否临时去掉代理设置。

## 发布

```bash
zig build release        # 产物：zig-out/release/uucli-VERSION-ARCH-OS.tar.gz（Linux musl 静态、macOS）
```

每个包含 `uucli`、README、LICENSE、NOTICE 和 systemd 单元（spec §11.3）。版本号在 `build.zig.zon` 的 `.version`。目前没有自动发布流水线，打 tag 和上传 release 由维护者手工做。
