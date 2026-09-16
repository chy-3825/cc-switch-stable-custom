# CC Switch Stable Custom

这是基于上游 [CC Switch](https://github.com/farion1231/cc-switch) `3.20.3` 的个人稳定分支，不是从零重写的 CC Switch。仓库保留上游 MIT 许可证和完整提交历史，并针对 Codex、VS Code 与 Linux/Clash 联动场景增加修复。

## 主要改动

- 由 CC Switch 独占托管 Codex 官方认证，避免 Codex 与 CC Switch 同时刷新 OAuth 凭据。
- 官方与第三方 Provider 共用历史分组，修复切换后历史暂时不可见的问题。
- 为外接模型生成真实模型目录，并按模型能力限制推理等级、保存 Provider 偏好。
- 加强 Provider 切换、代理启动、失败回滚和敏感日志脱敏。
- 提供 Linux 启动器、Clash 生命周期守卫和只读验收脚本。

详细状态见 [工作清单](工作清单.md) 与 [验收清单](验收清单.md)。Clash 守卫也作为独立项目发布在 [clash-verge-linux-guard](https://github.com/chy-3825/clash-verge-linux-guard)。

## 构建与检查

```bash
pnpm install
pnpm typecheck
pnpm test -- --run
cargo test --manifest-path src-tauri/Cargo.toml --all-targets
pnpm tauri build --no-bundle
./scripts/linux/test-launchers.sh
./scripts/linux/acceptance-check.sh
```

`acceptance-check.sh` 是只读检查：不会切换 Provider、退出 CC Switch/Clash、修改配置或输出 token。真实 Provider 往返、主动退出、冷重启和 token 到期仍需按验收清单人工执行。

## 安装策略

本分支建议固定版本使用，不自动覆盖安装上游新版。需要升级时先创建迁移分支，合并上游、运行完整测试和人工 P0 验收，再替换当前二进制。运行数据与凭据不应提交到 Git：

- `~/.cc-switch/`
- `~/.codex/`
- Clash 配置、订阅、日志和数据库
- `.env`、API Key、OAuth token

## 许可证与免责声明

上游及本分支源码遵循仓库中的 MIT License。第三方服务、Codex、Clash Verge Rev 和模型供应商各自遵循其服务条款。本项目不包含任何个人 token、API Key、订阅配置或账户数据库。
