# ChatGPT works, but Codex keeps reconnecting on macOS

**A real-world case study: a stale localhost proxy environment variable caused `Connection refused (os error 61)` while normal ChatGPT conversations still worked.**

[**中文完整案例**](README.zh-CN.md) · [**Full case study in English**](README.en.md)

> **Scope:** This is a community troubleshooting case, not an official OpenAI fix. Similar `Reconnecting…` symptoms can have different causes. The successful recovery and log observations described here come from the author's troubleshooting notes; they have not been independently reproduced on other machines.

## At a glance

| | Observed in this case |
| --- | --- |
| Platform | macOS 15.6.1, Apple Silicon |
| Desktop build / CLI | ChatGPT Desktop `26.1027.30824` / Codex CLI `0.146.0` (as recorded) |
| Symptom | ChatGPT conversations and browser worked; Codex and Work showed repeated reconnection attempts |
| Working macOS proxy | `127.0.0.1:9674` |
| Stale shell proxy | `http://127.0.0.1:7890` (nothing listening) |
| Error | `Connection refused (os error 61)` on the Codex Responses WebSocket path |
| Isolation | The Codex CLI failed with stale proxy variables and succeeded when they were unset |
| Recovery | Corrected shell startup proxy configuration; enabled `respect_system_proxy` on a supported Codex version; relaunched the desktop app |
| Post-fix evidence | CLI returned `OK`; log contained `successfully connected to Responses WebSocket status=101` |

## Start here (read-only)

```bash
# 1. See which proxy macOS is configured to use
scutil --proxy

# 2. See whether the suspected stale port is listening
nc -G 3 -vz 127.0.0.1 7890

# 3. Run the bundled, read-only checker (after reviewing its source)
bash scripts/check-proxy.sh

# 4. Optional: check HTTPS reachability via candidate local proxies
bash scripts/check-proxy.sh --network
```

**Do not paste unredacted `env`, `ps eww`, `.env`, `config.toml`, logs, or proxy subscriptions into public issues.** They can contain credentials, tokens, URLs, and local paths.

## Why this case is useful

A successful `curl` or working ChatGPT chat only establishes that **some** network path is available. It does not establish that every subprocess, Codex runtime request, or WebSocket uses the same proxy. A refused connection to a **local proxy port** can be reported against the remote `wss://chatgpt.com/...` URL, obscuring the actual failing hop.

This case demonstrates how to **compare the effective proxy used by the failing process** with the macOS proxy and run a controlled CLI A/B test before reinstalling apps or changing VPN nodes.

## Further reading

- [English investigation, evidence, changes, verification, rollback](README.en.md)
- [中文：完整排查过程、修复与风险说明](README.zh-CN.md)
- [OpenAI: Network recommendations and WebSocket requirements](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps)
- [Codex source: `respect_system_proxy` feature](https://github.com/openai/codex/blob/main/codex-rs/features/src/lib.rs)
- [Related issue #38885: stale `$CODEX_HOME/.env` proxy](https://github.com/openai/codex/issues/38885)
- [Related issue #51399: macOS desktop reconnection loop](https://github.com/openai/codex/issues/51399)

## Privacy, safety, and reuse

The repository contains **no account credentials, real logs, proxy subscription URLs, or machine-specific configuration files**. The diagnostic script reads local configuration, does not modify it, and only makes an outbound HTTPS request when `--network` is given. If you adapt this case to your setup, confirm the active proxy and preserve backups before changing any config.

Contributions and corrections are welcome. See [LICENSE](LICENSE) for reuse terms.
