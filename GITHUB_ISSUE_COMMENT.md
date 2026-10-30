# Optional comment for a related GitHub Issue

You can paste the following **English text** into a relevant existing Codex networking Issue. Adjust the version and results if your actual environment is different. After publishing the repository, you may add its URL; none is hard-coded here.

---

Adding another macOS data point for the `Reconnecting… waiting for network` symptom. In my case, ChatGPT web/ordinary chat worked, while desktop Codex (and initially Work) kept reconnecting.

**Environment:** macOS 15.6.1, Apple Silicon, ChatGPT Desktop 26.1027.30824, Codex CLI 0.146.0, local mihomo/Clash-family proxy with system proxy + TUN.

**Confirmed findings from my troubleshooting notes:**

- macOS system HTTP/HTTPS proxy was set to `127.0.0.1:9674`. A real HTTPS request through that proxy succeeded (`HTTP 200`).
- A stale shell setting still exported `https_proxy=http://127.0.0.1:7890`; nothing was listening on port 7890.
- A Codex CLI request with the stale proxy environment failed with `Connection refused (os error 61)` and repeated reconnection attempts, including the Responses WebSocket URL `wss://chatgpt.com/backend-api/codex/responses`.
- Running the same CLI request with HTTP(S)/ALL_PROXY variables unset allowed it to complete. This A/B test isolated the stale proxy environment as the direct cause of the CLI connection failure.
- I corrected the shell proxy setup, enabled the supported `respect_system_proxy` feature, and fully relaunched the desktop client. Follow-up logs included `successfully connected to Responses WebSocket status=101`, and CLI requests returned `OK`.

**Important caveat:** Both shell configuration and the proxy feature were changed before the final desktop verification, so I cannot attribute the desktop recovery to the feature flag alone. Also, observing proxy variables in a child process does not by itself prove that all Codex versions source `.zshrc`. I have not documented a multi-day or post-reboot stability test.

For others seeing this error, I'd suggest checking the effective local proxy target in environment variables, `$CODEX_HOME/.env`, and custom `config.toml` settings **before** reinstalling Codex or changing VPN nodes. A `Connection refused` shown against the remote WebSocket URL may actually describe a dead local proxy hop. Please redact any credentials before sharing diagnostics.
