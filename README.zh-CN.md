# ChatGPT 聊天正常，Codex 却一直「正在重新连接」：一次 macOS 代理环境变量故障的排查记录

[English](README.en.md) · [项目首页](README.md)

> **结论先行：** 本案的关键故障点是旧的代理环境变量 `https_proxy=http://127.0.0.1:7890`。这个本地端口已经没有服务监听；而 macOS 系统代理指向仍可用的 `127.0.0.1:9674`。Codex CLI 在带着旧变量运行时出现 `Connection refused (os error 61)`；移除相关变量后，同一环境下的请求恢复。修正 shell 配置、启用已安装版本支持的系统代理选项并重启客户端后，排障记录中出现 WebSocket `101` 成功连接。

**这是一份个人真实排障记录，不是 OpenAI 官方通用修复方案。** 以下版本、端口、日志内容与测试结果来自当时保存的排障笔记，未经在其他机器上独立复现。不同版本的 Codex、ChatGPT 客户端及代理软件可能使用不同的网络路径。

## 1. 故障表现和环境

- macOS **15.6.1**，Apple Silicon MacBook Air。
- 当时记录的客户端版本：ChatGPT Desktop **26.1027.30824**、Codex CLI **0.146.0**。
- 本地运行 mihomo/Clash 系代理，启用了**系统代理 + TUN**；代理软件曾多次更换。
- ChatGPT 网页端和桌面端普通聊天均正常。
- 进入 Codex 后持续显示 `Reconnecting… / 正在重新连接`；Work 也出现相似现象。
- 同一网络、同一代理节点下，不同功能的表现明显不同。

**需要避免的误判：**「ChatGPT 能用」并不代表 Codex 的网络请求一定经过了同一个代理。`Reconnecting` 只是现象，不能仅凭它判断是 WebSocket、账号、DNS 还是 VPN 节点的问题。

## 2. 先画清网络拓扑

当时核实到的主要本地端口（**仅为本案实例，其他用户请以自己的实际配置为准**）：

| 地址 / 端口 | 当时的用途 | 排查结果 |
| --- | --- | --- |
| `127.0.0.1:9674` | 正在运行的 mihomo 系客户端混合代理；macOS HTTP/HTTPS/SOCKS 系统代理指向这里 | 可达；访问 OpenAI 授权端点返回 HTTP 200 |
| `127.0.0.1:7897` | 已移除的 Clash Verge 对应的残留服务 | 本地监听仍存在，但上游请求未正常工作 |
| `127.0.0.1:7890` | `.zshrc` 中遗留的旧 ClashX 代理地址 | 无服务监听；导致连接被拒绝 |

最初执行 `lsof` 时没有显示 `9674` 对应的监听进程，一度被怀疑是系统代理坏了。后来结合 `netstat`、`nc` 和 HTTPS 实测，发现 **9674 可用**。`lsof` 输出为空可能与权限、过滤方式或进程状态有关，不能单独当成端口失效的证据。

只读检查：

```bash
scutil --proxy
netstat -anv -p tcp | grep LISTEN
nc -G 3 -vz 127.0.0.1 9674
nc -G 3 -vz 127.0.0.1 7890

# 在本仓库根目录执行；默认不发起外部网络请求
bash scripts/check-proxy.sh
```

接着核实实际的代理端到端转发能力：

```bash
curl --proxy http://127.0.0.1:9674 --noproxy '' \
  --connect-timeout 5 --max-time 15 \
  -sS -o /dev/null -w 'HTTP=%{http_code}\n' \
  https://auth.openai.com/.well-known/openid-configuration
# 本案记录：HTTP=200
```

`nc` 成功只表示本地 TCP 端口接受连接，**不表示上游代理节点可用**。而 HTTPS 端点返回 200 只证明这一条 HTTPS 路径可用，并不能单独证明 WebSocket 或所有 Codex 操作一定正常。在 TUN 模式下，`curl --noproxy '*'` 也**不等于物理直连**，因为 TUN 仍可能接管路由。

## 3. 从日志缩小失败范围

本案在 `~/.codex/logs_2.sqlite` 中找到了与连接失败相关的记录，包括：

```text
codex_api::endpoint::responses_websocket
failed to connect to Responses WebSocket stage=Unknown

error sending request for url (.../backend-api/ps/plugins/installed...)

IO error: Connection refused (os error 61)
url: wss://chatgpt.com/backend-api/codex/responses
```

本案使用的日志数据库和字段如下，**其他版本不保证路径及表结构相同**：

```bash
# 只读打开 SQLite；请先确认文件存在
sqlite3 "file:$HOME/.codex/logs_2.sqlite?mode=ro" \
  "SELECT datetime(ts,'unixepoch','localtime'),level,target,
          substr(feedback_log_body,1,180)
   FROM logs WHERE level='ERROR' ORDER BY id DESC LIMIT 10;"
```

日志中出现最终目标 `chatgpt.com`，**不代表 TCP 连接被远端服务器拒绝**；真正被拒绝的也可能是 HTTP 代理这一中间跳。不要因为错误 URL 指向 OpenAI，就直接认定 OpenAI 服务宕机。

> **公开日志注意：** SQLite、应用日志、`config.toml` 和进程环境变量可能包含用户资料、会话标识、Token 或代理凭据。请只在本机查看，分享时人工删改敏感值；不要上传整个数据库。

## 4. 决定性的 A/B 测试

在当前 shell 中，发现残留了代理变量（值取自当时的本地排障记录）：

```text
https_proxy=http://127.0.0.1:7890
```

而端口 `7890` 已经不监听。随后用同一个 Codex CLI、账号与当前网络进行对照测试：

**A 组：保留旧变量（失败）**

```bash
codex exec --skip-git-repo-check \
  -c model_reasoning_effort=low 'Reply with exactly: OK'
```

观察到：

```text
Connection refused (os error 61)
Reconnecting... 1/5 ... 5/5
```

**B 组：只在这一条命令中移除代理变量（恢复）**

```bash
env -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  codex exec --skip-git-repo-check \
    -c model_reasoning_effort=low 'Reply with exactly: OK'
```

本案记录显示，B 组请求能抵达 OpenAI 并完成模型响应；后续回归测试得到 `OK`。这比反复换节点更有解释力：**旧的代理环境变量是故障的直接触发因素**。

这里需要分清三个层次：

1. **已被 A/B 测试支持：** 带旧代理变量的 Codex CLI 失败；去掉后恢复。
2. **排障记录还观察到：** 当时的 Codex 子进程环境中有旧代理变量，父应用进程中未观察到相同变量。
3. **不能据此普遍断言：** 所有版本的 Codex 都会主动 `source ~/.zshrc`、所有 ChatGPT 普通聊天都只用系统代理，或者此现象只能通过改 `.zshrc` 修复。变量的实际注入来源仍应逐机确认。

如果怀疑进程环境，可在**自己的 Mac 上**用 `ps eww -p <PID>` 观察，但**不要把原始输出粘到 GitHub**，它可能包含密钥。另请检查 `$CODEX_HOME/.env`（默认 `~/.codex/.env`）、`.zprofile`、`launchctl` 和其他代理注入位置；这些也可能覆盖 shell 的设置。

## 5. 实际采取的修复与推荐的更安全做法

### 5.1 修正旧 shell 代理设置

本案最初在 `~/.zshrc` 中写死了 `7890`。当时的修复将其改为启动时依次探测 `9674`、`7897`、`7890`，在找到监听端口时才导出代理变量；如果没有找到，则不导出。

**这是本案当时实施的措施，不建议其他用户直接照搬三个端口的自动探测顺序。** 原因是 `nc` 只验证“端口在监听”，无法识别**残留服务虽然监听、但无法代理外网**。在本案中，`7897` 就出现过这样的情况。

对其他读者，更安全、可移植的修法是：

1. 先定位环境变量来自 `.zshrc`、`.zprofile`、`.env`，还是其他启动配置。
2. 备份对应文件，只删除或改正已经失效的 `export http_proxy=...` / `https_proxy=...` / `all_proxy=...`；不要一键清空全部 shell 配置。
3. 如果确实需要为终端设置显式代理，使用**当前正在运行且经过 HTTPS 测试**的代理地址，而不是随机选择第一个监听端口。
4. 避免把同一代理的旧地址同时写进多个文件；每次更换代理客户端后核对配置。

示例备份（修改前执行）：

```bash
stamp=$(date +%Y%m%d-%H%M%S)
cp -p ~/.zshrc "$HOME/.zshrc.bak.$stamp"
[ ! -f "$HOME/.codex/config.toml" ] || \
  cp -p "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.bak.$stamp"
```

### 5.2 视版本支持情况启用 Codex 系统代理选项

本案记录的 Codex CLI `0.146.0` 提供了 `respect_system_proxy` 功能；在当时的安装环境中启用：

```bash
codex features list | grep -i respect_system_proxy
# 确认列表中确实存在，再选择性执行：
codex features enable respect_system_proxy
```

对应配置为：

```toml
[features]
respect_system_proxy = true
```

如果 `config.toml` 已有 `[features]`，**只在现有节中增加一行**，不要创建重复的 `[features]`。注意单数 `proxy`，不是 `respect_system_proxies`。

根据 [Codex 源码](https://github.com/openai/codex/blob/main/codex-rs/features/src/lib.rs) 和 [OpenAI 的配置说明](https://learn.chatgpt.com/docs/enterprise/managed-configuration)，这一选项用于让 **Codex 自身管理的网络客户端**考虑宿主系统代理设置；它不是“所有 ChatGPT、插件、Shell 命令都强制走系统代理”的保证。不同版本的实现及环境变量优先级可能不同，应以安装版本实际测试为准。

**因本案同时调整了 shell 配置和系统代理功能，无法从最终修复结果单独推断 `respect_system_proxy` 必不可少。** 可以确定的是，前面的 CLI A/B 测试已单独支持“失效代理变量造成连接问题”。

### 5.3 完全退出并重启客户端

已有进程的环境变量通常不会因修改 `.zshrc` 而自动刷新。请保存工作，正常退出应用（`Command + Q`）后重开，再测试全新 Codex 会话。

不要为了排障直接对所有匹配到的进程使用 `kill -9`，更不要删除 `~/.codex`。如果应用无法退出，先确定具体进程与未保存工作，再考虑有针对性的终止。

## 6. 修复后的实际验证

以下是**原始排障笔记报告的测试结果**，不是本仓库在每台机器上自动完成的测试：

| 测试 | 记录中的结果 | 说明 |
| --- | --- | --- |
| 新 shell 环境变量 | 由旧 `7890` 改为工作中的 `9674` | 不再引用失效代理端口 |
| Codex CLI 正常调用 | 返回 `OK` | 至少一条模型请求成功 |
| 移除代理变量的 CLI 测试 | 返回 `OK` | 对照组成功 |
| 重启客户端后子进程环境 | 不再有旧 `7890` | 进程重新获得更新后的配置 |
| Codex 日志 | `successfully connected to Responses WebSocket status=101` | WebSocket 握手成功 |
| 基础 HTTPS 访问 | 经 `9674` 返回 HTTP 200 | 代理路径可用 |

`101 Switching Protocols` 是 WebSocket 升级握手成功的证据，但不代表之后所有长时间会话都永不掉线。**原始材料没有提供完整的重启 macOS 后、长期多日稳定性测试，本文不声称“永久修复已验证”。** Work 在修复前也受影响，但原始最终测试表没有单独记录 Work 的完整端到端验收结果。

## 7. 回滚和其他可能原因

如果修改后出现新问题，关闭客户端并将备份恢复（把下面的 `<时间戳>` 换成自己的实际备份名）：

```bash
cp -p "$HOME/.zshrc.bak.<时间戳>" "$HOME/.zshrc"
cp -p "$HOME/.codex/config.toml.bak.<时间戳>" "$HOME/.codex/config.toml"
```

如果仅使用 `codex features enable` 修改功能开关，也可在当前版本支持的情况下运行 `codex features disable respect_system_proxy`，但如果存在其他配置来源，请先确认实际生效位置。

如果排除环境变量后仍然重连，请依次检查：

- `$CODEX_HOME/.env` 是否存在旧代理变量；`~/.codex/config.toml` 是否有无效的 `openai_base_url` 或其他自定义服务地址。
- 系统代理端口是否真实监听且能**完成 HTTPS 请求**。
- TUN 路由、DNS、代理规则，以及不同 Codex 进程的实际网络路径。
- WebSocket 443/Upgrade 是否被中断；OpenAI [网络指南](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps)专门列出了 Codex 的 `wss://chatgpt.com/` 要求。
- 客户端自身的日志、版本变化和其他应用集成。

### 关于已卸载代理软件的残留服务

本案还发现 Clash Verge 应用已被移除，但旧的特权后台服务仍在监听端口。**这是一项伴随发现，不能将它直接等同于 `7890` 故障的根因。**

如果发现此类残留，先在原软件中使用官方卸载/服务管理方法。不要复制网上的 `sudo rm -rf /Library/PrivilegedHelperTools/...` 命令：删除系统级服务可能影响其他网络配置。必要时先核对具体 service label、plist 路径和安装来源，再备份、卸载并验证。

## 8. 给其他遇到相同现象的人的建议

**建议优先检查“失败的进程最终使用了哪个代理地址”，而不是立刻换 VPN 节点、重装客户端或清空账号数据。** 尤其是 `Connection refused (os error 61)` 和 `127.0.0.1:PORT` 同时出现时，先确认该本地端口是不是已经不存在。

可以按以下顺序执行：

```bash
# A. macOS 系统代理指向谁？
scutil --proxy

# B. 可疑 localhost 端口真的在监听吗？
nc -G 3 -vz 127.0.0.1 7890

# C. 查看当前 shell 是否定义了代理变量（不要公开变量值）
for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
  if printenv "$name" >/dev/null 2>&1; then printf '%s is set\n' "$name"; fi
done
# 上面一段使用 zsh 语法；bash 用户可使用仓库中的检查脚本

# D. 保留原 shell 与移除代理变量的 Codex CLI A/B 测试
codex exec --skip-git-repo-check 'Reply with exactly: OK'
env -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  codex exec --skip-git-repo-check 'Reply with exactly: OK'
```

**注意：** A/B 测试需要 Codex CLI 已登录且具备请求权限；不会绕过 Codex 自己的 `.env` 或其他持久配置。如果第二组仍失败，不能据此排除代理配置问题。

## 参考资料和相似案例

- [OpenAI：ChatGPT 和 Codex WebSocket 网络要求](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps)
- [OpenAI：`features.respect_system_proxy` 适用范围及限制](https://learn.chatgpt.com/docs/enterprise/managed-configuration)
- [Codex 源码：功能标志定义](https://github.com/openai/codex/blob/main/codex-rs/features/src/lib.rs)
- [GitHub #38885：旧 `$CODEX_HOME/.env` 指向无效本地代理](https://github.com/openai/codex/issues/38885)
- [GitHub #39237：`respect_system_proxy` 与错误复数拼写](https://github.com/openai/codex/issues/39237)
- [GitHub #51399：macOS Codex Desktop 重连与 WebSocket 1006](https://github.com/openai/codex/issues/51399)

这些 Issue 展示的是**相似症状及其他用户的诊断**，并不意味着每个案例与本文存在相同根因。

---

*整理依据：作者提供的 2026 年 10 月 macOS 排障记录。端口和版本是当时的环境快照，不能当作通用默认配置。欢迎补充可复现的证据、勘误与不同版本的反馈。*
