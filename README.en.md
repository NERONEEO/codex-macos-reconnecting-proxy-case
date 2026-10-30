# ChatGPT worked, but Codex kept reconnecting: a stale proxy environment variable on macOS

[中文](README.zh-CN.md) · [Repository home](README.md)

> **Bottom line:** In this case, an old `https_proxy=http://127.0.0.1:7890` setting pointed to a local port with no listener, while the macOS system proxy pointed to a working proxy at `127.0.0.1:9674`. A Codex CLI request failed with `Connection refused (os error 61)` when the stale variables were present, and worked when they were removed for a controlled test. After fixing shell proxy settings, enabling the system-proxy feature in the supported Codex build, and relaunching the app, the troubleshooting notes recorded a successful WebSocket upgrade (`status=101`).

**This is a personal case study, not a universal fix or an official OpenAI statement.** App versions, port numbers, logs, and test outcomes are from the author's troubleshooting record, not independent reproduction on other devices.

## 1. Symptoms and environment

| Item | Recorded environment |
| --- | --- |
| Computer | Apple Silicon MacBook Air, macOS `15.6.1` |
| Application | ChatGPT Desktop `26.1027.30824` |
| Codex CLI | `0.146.0` |
| Proxy | A mihomo/Clash-family local client, system proxy + TUN enabled |
| ChatGPT chats and website | Working |
| Codex desktop | Repeatedly showed `Reconnecting…` |
| Work mode | Showed similar connection issues before recovery |
| Explicit error | `Connection refused (os error 61)` |

A working browser tab proves that **one** network path works. It does not establish that the Codex runtime, another subprocess, or a WebSocket is using that same route.

## 2. Map local proxies before changing anything

In the recorded setup:

| Endpoint | What it was | Observed result |
| --- | --- | --- |
| `127.0.0.1:9674` | Active mihomo-family mixed proxy; macOS HTTP/HTTPS/SOCKS proxy used it | Accepted requests; OpenAI authentication endpoint returned HTTP 200 |
| `127.0.0.1:7897` | Leftover Clash Verge service after its GUI app was removed | Listener existed, but its upstream connectivity failed |
| `127.0.0.1:7890` | An old ClashX-era proxy URL still exported from `.zshrc` | No listener; connection refused |

Start with read-only checks. **These ports are examples from the case; do not assume they are universal defaults.**

```bash
scutil --proxy
netstat -anv -p tcp | grep LISTEN
nc -G 3 -vz 127.0.0.1 9674
nc -G 3 -vz 127.0.0.1 7890

# Review this repository's script first; it does not edit files.
bash scripts/check-proxy.sh
```

The initial `lsof` command did not list the service bound to 9674, but subsequent `netstat`, `nc`, and HTTPS checks established that the port was live. An empty `lsof` result by itself is **not** sufficient evidence that a proxy port is dead: permissions, process visibility, and command filtering can affect results.

Test upstream proxy functionality separately:

```bash
curl --proxy http://127.0.0.1:9674 --noproxy '' \
  --connect-timeout 5 --max-time 15 \
  -sS -o /dev/null -w 'HTTP=%{http_code}\n' \
  https://auth.openai.com/.well-known/openid-configuration
# Recorded in this case: HTTP=200
```

`nc` tests local TCP acceptance, **not** whether the proxy can actually reach OpenAI. A successful HTTPS request is also **not** a full Codex/WebSocket test. And when TUN is active, `curl --noproxy '*'` does not necessarily bypass the VPN at the IP routing layer.

## 3. The error was visible in Codex logs

The record included messages such as:

```text
codex_api::endpoint::responses_websocket
failed to connect to Responses WebSocket stage=Unknown

error sending request for url (.../backend-api/ps/plugins/installed...)

IO error: Connection refused (os error 61)
url: wss://chatgpt.com/backend-api/codex/responses
```

For the installed version in this case, relevant entries were found in `~/.codex/logs_2.sqlite` (table `logs`, columns `ts`, `level`, `target`, `feedback_log_body`). **The location and schema may differ in other versions.**

```bash
# Read-only SQLite query. First verify that the file exists.
sqlite3 "file:$HOME/.codex/logs_2.sqlite?mode=ro" \
  "SELECT datetime(ts,'unixepoch','localtime'),level,target,
          substr(feedback_log_body,1,180)
   FROM logs WHERE level='ERROR' ORDER BY id DESC LIMIT 10;"
```

A reported `wss://chatgpt.com/...` URL tells you what the client wanted to reach. It **does not identify which hop refused the TCP connection**. A failed localhost HTTP proxy can cause an error framed in terms of the remote destination.

> **Privacy warning:** Never upload raw SQLite databases, full logs, proxy subscription URLs, `.env` files, or unredacted environment dumps. They may contain authentication material and personal data.

## 4. The decisive controlled test

The current shell contained a stale setting:

```text
https_proxy=http://127.0.0.1:7890
```

Port 7890 had no listener. With the same computer, account, Codex CLI, and network, two invocations behaved differently.

**A — Keep the stale proxy variables: failure**

```bash
codex exec --skip-git-repo-check \
  -c model_reasoning_effort=low 'Reply with exactly: OK'
```

Observed:

```text
Connection refused (os error 61)
Reconnecting... 1/5 ... 5/5
```

**B — Unset proxy variables for just this invocation: success**

```bash
env -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
  codex exec --skip-git-repo-check \
    -c model_reasoning_effort=low 'Reply with exactly: OK'
```

The record reports that group B reached the OpenAI service and completed the model request; follow-up tests returned `OK`. This isolates the **stale proxy environment** as a direct cause of the CLI failure much more clearly than simply changing VPN nodes.

What it **does not** prove:

- That every Codex release automatically sources `~/.zshrc`.
- That all ChatGPT chat networking is handled exclusively by the macOS system proxy.
- That a stale `.zshrc` is the only way a bad proxy value can reach a desktop subprocess.
- That all reconnect loops share this cause.

The original notes also observed stale proxy variables in a Codex child process but not in the ChatGPT parent process. That is useful evidence of a configuration mismatch; it does **not**, on its own, establish the exact mechanism by which the child obtained those variables.

For other cases, investigate startup scripts (`.zshrc`, `.zprofile`), `$CODEX_HOME/.env` (typically `~/.codex/.env`), the environment of the launch context, and deliberate custom URLs in `config.toml`. You can inspect a process locally using `ps eww -p <PID>`, **but never paste the unredacted output in a public report**.

## 5. Repair, with the important caveats

### 5.1 Remove or correct the obsolete shell export

In the original remediation, the hard-coded `7890` export in `.zshrc` was replaced by a startup check over candidate local ports (`9674`, `7897`, `7890`), exporting a proxy only if a local listener was found.

**That describes what was done on the author's machine; it is not a recommended copy-paste solution for arbitrary Macs.** A port may accept TCP connections while its upstream proxies are unusable (port 7897 in this very case). Automatically using the first listening service can select the wrong proxy.

**Safer general approach:**

1. Identify which file or launcher actually supplies the proxy variable.
2. Back up that file before editing.
3. Remove the outdated localhost proxy exports, or change them to a **specific currently working proxy endpoint** verified with an actual HTTPS request.
4. Avoid duplicate proxy settings across multiple startup files or tools.

Example backups:

```bash
stamp=$(date +%Y%m%d-%H%M%S)
cp -p ~/.zshrc "$HOME/.zshrc.bak.$stamp"
[ ! -f "$HOME/.codex/config.toml" ] || \
  cp -p "$HOME/.codex/config.toml" "$HOME/.codex/config.toml.bak.$stamp"
```

### 5.2 Optionally enable native system-proxy support

In the documented environment, Codex CLI `0.146.0` exposed the `respect_system_proxy` feature. Check whether **your installed build** has it:

```bash
codex features list | grep -i respect_system_proxy
# If supported, optionally enable it:
codex features enable respect_system_proxy
```

Equivalent `config.toml` option:

```toml
[features]
respect_system_proxy = true
```

Add it to the **existing** `[features]` section rather than creating a duplicate table. The supported key uses the **singular** `proxy` (not `respect_system_proxies`).

The [Codex feature definition](https://github.com/openai/codex/blob/main/codex-rs/features/src/lib.rs) and [OpenAI's configuration documentation](https://learn.chatgpt.com/docs/enterprise/managed-configuration) describe this as an option for **Codex-owned networking clients** to use the host system proxy. It does **not** force every desktop, browser, plugin, or shell request through that proxy. Validate its behavior on the specific version you run.

**Causal limitation:** The final desktop repair involved both the shell change and enabling this feature. The CLI A/B test separately implicates stale environment variables, but the notes do not independently establish whether the feature flag was necessary to recover the desktop application.

### 5.3 Relaunch the application

Running processes do not usually update their environment when `.zshrc` is edited. Save work, quit the desktop application normally (`Command + Q`), launch it again, and try a new Codex conversation. Avoid broad `kill -9` commands or deleting `~/.codex` just to fix a proxy setting.

## 6. Recorded verification

| Check | Result recorded in original notes |
| --- | --- |
| New shell environment | Old `7890` replaced by working `9674` |
| Codex CLI with corrected environment | `OK` |
| Codex CLI with proxy variables explicitly unset | `OK` |
| Relaunched desktop Codex subprocess | No longer had stale `7890` proxy variables |
| Codex runtime log | `successfully connected to Responses WebSocket status=101` |
| Proxy HTTPS path | HTTP 200 through port `9674` |

WebSocket HTTP `101 Switching Protocols` indicates a successful upgrade, **not a promise of indefinitely stable long-lived sessions**. The provided record does not document a full post-reboot, multi-day stability evaluation; this repository therefore does not claim a proven permanent fix. Work was affected beforehand, but the original final test matrix did not independently document a complete Work end-to-end acceptance test.

## 7. Rollback and other root causes

Restore the timestamped backups after quitting the application (replace `<timestamp>`):

```bash
cp -p "$HOME/.zshrc.bak.<timestamp>" "$HOME/.zshrc"
cp -p "$HOME/.codex/config.toml.bak.<timestamp>" "$HOME/.codex/config.toml"
```

Where supported and appropriate, `codex features disable respect_system_proxy` can revert the feature toggle; verify which configuration source actually enabled it.

If the issue persists after removing stale shell proxy variables, consider:

- A stale `$CODEX_HOME/.env` or unwanted `openai_base_url` override.
- A mismatch between active system-proxy settings and the actual listener.
- A live localhost port with a **dead upstream proxy**.
- Different routing paths through TUN, PAC, DNS, or a per-app rule.
- A failed WebSocket handshake or a proxy timeout; OpenAI's [network guide](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps) describes the Codex `wss://chatgpt.com/` requirement.
- A version-specific runtime or desktop integration bug.

**Additional observation, not the proven root cause:** A privileged helper from a previously removed Clash Verge installation was still running on the machine. Uninstalling a GUI does not always unload system LaunchDaemons. Prefer the vendor's official service uninstall process; **do not blindly run `sudo rm -rf` against `/Library/PrivilegedHelperTools`**.

## 8. A short checklist for other people

1. Check `scutil --proxy`: which port does macOS use?
2. Check `nc -G 3 -vz 127.0.0.1 <port>`: is the local listener alive?
3. Check a real HTTPS request **through that proxy**; a listener alone is not enough.
4. Check proxy environment variable **names and local targets**, without sharing secrets.
5. Compare Codex CLI results **with vs. without** `http_proxy`, `https_proxy`, `all_proxy` and their uppercase equivalents.
6. Check `$CODEX_HOME/.env`, `.zshrc`, `.zprofile`, `config.toml`, and the actual desktop process environment.
7. Back up and change one variable at a time; relaunch and retest.

You can perform the initial read-only checks with:

```bash
bash scripts/check-proxy.sh
# Optional, performs a real HTTPS request to an OpenAI auth endpoint:
bash scripts/check-proxy.sh --network
```

The CLI A/B test requires a working Codex login and request quota. Unsetting shell variables does not necessarily override proxy settings loaded from a persistent `.env` or other configuration source; failure in group B does not rule those out.

## Related references

- [OpenAI: ChatGPT / Codex WebSocket requirements](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps)
- [OpenAI: system proxy feature scope and limitations](https://learn.chatgpt.com/docs/enterprise/managed-configuration)
- [Codex source: feature flag](https://github.com/openai/codex/blob/main/codex-rs/features/src/lib.rs)
- [GitHub #38885: Stale `$CODEX_HOME/.env` proxy](https://github.com/openai/codex/issues/38885)
- [GitHub #39237: proxy feature spelling and behavior](https://github.com/openai/codex/issues/39237)
- [GitHub #51399: macOS desktop reconnecting/WebSocket 1006](https://github.com/openai/codex/issues/51399)

These reports describe **related symptoms and other users' investigations**; they do not prove identical causes.

---

*Prepared from the author's October 2026 troubleshooting notes. Versions and ports describe that one installation. Corrections and reproducible follow-up findings are welcome.*
