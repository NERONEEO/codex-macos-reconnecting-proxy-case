#!/usr/bin/env bash
# Read-only macOS localhost proxy diagnostics.
# No config files are modified, and no proxy URLs or credentials are printed.
# --network: optionally perform one HTTPS request through the macOS HTTP(S) proxy.
set -u

if [ "$(uname -s)" != "Darwin" ]; then
  echo 'This script is intended for macOS (Darwin).' >&2
  exit 2
fi

network_check=0
case "${1:-}" in
  '') ;;
  --network) network_check=1 ;;
  -h|--help) echo 'Usage: bash scripts/check-proxy.sh [--network]'; exit 0 ;;
  *) echo 'Unknown option. Usage: bash scripts/check-proxy.sh [--network]' >&2; exit 2 ;;
esac

has_cmd() { command -v "$1" >/dev/null 2>&1; }
label() { printf '\n=== %s ===\n' "$1"; }

# Avoid collecting arbitrary proxy targets, which can include usernames or passwords.
proxy_data="$(scutil --proxy 2>/dev/null || true)"
proxy_field() {
  printf '%s\n' "$proxy_data" | awk -v key="$1" '$1==key && $2==":" {print $3; exit}'
}

proxy_port_candidates=''
add_port() {
  case "$1" in
    ''|*[!0-9]*) return ;;
  esac
  case " $proxy_port_candidates " in
    *" $1 "*) ;;
    *) proxy_port_candidates="${proxy_port_candidates}${proxy_port_candidates:+ }$1" ;;
  esac
}

label 'System proxy (enabled status and port; host redacted if non-loopback)'
for kind in HTTP HTTPS SOCKS; do
  enabled="$(proxy_field "${kind}Enable")"
  host="$(proxy_field "${kind}Proxy")"
  port="$(proxy_field "${kind}Port")"
  if [ "$enabled" = '1' ]; then
    if [ "$host" = '127.0.0.1' ] || [ "$host" = 'localhost' ] || [ "$host" = '::1' ]; then
      printf '%-6s enabled localhost:%s\n' "$kind" "${port:-unknown}"
      add_port "$port"
    else
      printf '%-6s enabled (non-local target redacted)\n' "$kind"
    fi
  else
    printf '%-6s disabled or not reported\n' "$kind"
  fi
done

label 'Proxy variable names set in the current process'
for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
  # Bash 3.2 supports ${!name}; never print the full variable value.
  value="${!name-}"
  if [ -n "$value" ]; then
    printf '%s is set' "$name"
    # If the value is a simple localhost URL with no embedded credentials,
    # also show its loopback port (never disclose remote URLs).
    case "$value" in
      http://127.0.0.1:*|https://127.0.0.1:*|socks5://127.0.0.1:*)
        target="${value#*://}"
        target="${target%%/*}"
        port="${target#127.0.0.1:}"
        case "$port" in
          ''|*[!0-9]*) ;;
          *) printf ' -> localhost:%s' "$port"; add_port "$port" ;;
        esac
        ;;
    esac
    printf '\n'
  fi
done

label 'Files to inspect locally (contents are NOT printed)'
for file in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.profile"; do
  if [ -f "$file" ]; then
    case "$file" in
      "$HOME/.zshrc") friendly='~/.zshrc' ;;
      "$HOME/.zprofile") friendly='~/.zprofile' ;;
      *) friendly='~/.profile' ;;
    esac
    if grep -Eq '(^|[[:space:]])(export[[:space:]]+)?(http_proxy|https_proxy|all_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY)[[:space:]]*=' "$file"; then
      printf '%s: contains proxy variable assignments (review locally)\n' "$friendly"
    else
      printf '%s: no obvious proxy variable assignments\n' "$friendly"
    fi
  fi
done

codex_home="${CODEX_HOME:-$HOME/.codex}"
if [ -f "$codex_home/.env" ]; then
  echo 'Codex .env: exists (check proxy-related keys locally; do not publish the file)'
else
  echo 'Codex .env: not found at the active CODEX_HOME'
fi
if [ -f "$codex_home/config.toml" ]; then
  echo 'Codex config.toml: exists (check [features], proxy settings and custom base URLs locally)'
else
  echo 'Codex config.toml: not found at the active CODEX_HOME'
fi

label 'Local TCP port checks (listener only; not an upstream test)'
# Also probe 7890, a common stale proxy port in related reports.
add_port 7890
for port in $proxy_port_candidates; do
  if nc -G 3 -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    printf '127.0.0.1:%s : LISTENING\n' "$port"
  else
    printf '127.0.0.1:%s : NO TCP LISTENER REACHED\n' "$port"
  fi
done

if [ "$network_check" -eq 1 ]; then
  label 'Optional outbound HTTPS test'
  chosen_host="$(proxy_field HTTPSProxy)"
  chosen_port="$(proxy_field HTTPSPort)"
  chosen_enabled="$(proxy_field HTTPSEnable)"
  if [ "$chosen_enabled" = '1' ] && { [ "$chosen_host" = '127.0.0.1' ] || [ "$chosen_host" = 'localhost' ]; } &&
    [ -n "$chosen_port" ] && [ "${chosen_port//[0-9]/}" = '' ]; then
    if has_cmd curl; then
      printf 'Testing via macOS HTTPS localhost proxy on port %s ...\n' "$chosen_port"
      http_code="$(curl --silent --show-error \
        --proxy "http://127.0.0.1:$chosen_port" --noproxy '' \
        --connect-timeout 5 --max-time 15 --output /dev/null \
        --write-out '%{http_code}' \
        'https://auth.openai.com/.well-known/openid-configuration' 2>/dev/null)"
      ret=$?
      if [ "$ret" -eq 0 ]; then
        printf 'curl completed, HTTP status: %s\n' "$http_code"
      else
        printf 'curl failed with exit code %s (no secrets printed)\n' "$ret"
      fi
    else
      echo 'curl is not available; skipped.'
    fi
  else
    echo 'HTTPS system proxy is not an enabled localhost HTTP proxy; skipped.'
  fi
else
  printf '\nNo external network request was sent. Use --network to opt in.\n'
fi

printf '\nReminder: a working listener or HTTPS response does not guarantee WebSocket success.\n'
