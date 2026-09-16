#!/bin/bash
# Read-only, redacted workstation checks for the CC Switch + Codex + Clash setup.
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/../.." && pwd)"
user_home="${HOME}"
cc_dir="$user_home/.cc-switch"
codex_dir="$user_home/.codex"
db_path="$cc_dir/cc-switch.db"
settings_path="$cc_dir/settings.json"
codex_config="$codex_dir/config.toml"
codex_auth="$codex_dir/auth.json"
managed_auth="$cc_dir/codex_oauth_auth.json"
installed_binary="$user_home/.local/bin/cc-switch-fixed-3.20.3"
built_binary="$repo_dir/src-tauri/target/release/cc-switch"
failures=0
warnings=0

pass() { printf 'PASS  %s\n' "$*"; }
warn() { warnings=$((warnings + 1)); printf 'WARN  %s\n' "$*"; }
fail() { failures=$((failures + 1)); printf 'FAIL  %s\n' "$*"; }

require_file() {
  if [ -f "$1" ]; then
    pass "file exists: $1"
  else
    fail "missing file: $1"
  fi
}

port_open() {
  python3 - "$1" <<'PY'
import socket, sys
try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2):
        pass
except OSError:
    raise SystemExit(1)
PY
}

printf 'CC Switch / Codex / Clash acceptance check\n'
printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"

for path in "$db_path" "$settings_path" "$codex_config" "$managed_auth"; do
  require_file "$path"
done
if [ -f "$codex_auth" ]; then
  pass "optional dormant native auth cache exists: $codex_auth"
else
  pass "no dormant native auth cache is present"
fi

if [ -x "$built_binary" ] && [ -x "$installed_binary" ] \
  && [ "$(sha256sum "$built_binary" | awk '{print $1}')" = "$(sha256sum "$installed_binary" | awk '{print $1}')" ]; then
  pass "installed CC Switch binary matches the release build"
else
  fail "installed CC Switch binary does not match the release build"
fi
if cmp -s "$script_dir/cc-switch-launcher" "$user_home/.local/bin/cc-switch" \
  && cmp -s "$script_dir/clash-verge-guarded" /usr/local/bin/clash-verge-guarded \
  && cmp -s "$script_dir/clash-verge-service-override.conf" /etc/systemd/system/clash-verge-service.service.d/exit-with-ui.conf; then
  pass "installed launchers and systemd override match repository sources"
else
  fail "an installed launcher or systemd override differs from repository sources"
fi

if port_open 15721; then pass "CC Switch route 127.0.0.1:15721 is reachable"; else fail "CC Switch route 15721 is unavailable"; fi
if port_open 7897; then pass "Clash mixed port 127.0.0.1:7897 is reachable"; else fail "Clash mixed port 7897 is unavailable"; fi
if ss -H -ltn 'sport = :15721' 2>/dev/null | awk '{print $4}' | grep -Eq '^(127\.0\.0\.1|\[::1\]):15721$' \
  && ! ss -H -ltn 'sport = :15721' 2>/dev/null | awk '{print $4}' | grep -Eq '^(0\.0\.0\.0|\*|\[::\]):15721$'; then
  pass "CC Switch proxy is bound only to loopback"
else
  fail "CC Switch proxy is missing or exposed beyond loopback"
fi

if systemctl is-active --quiet clash-verge-service.service; then
  pass "clash-verge-service is active"
else
  fail "clash-verge-service is not active"
fi
if [ "$(systemctl show clash-verge-service.service -p Restart --value 2>/dev/null)" = "on-failure" ]; then
  pass "Clash helper restarts on crashes but not explicit stops"
else
  fail "Clash helper restart policy is not on-failure"
fi

proxy_mode="$(gsettings get org.gnome.system.proxy mode 2>/dev/null || true)"
case "$proxy_mode" in
  "'manual'")
    if port_open 7897; then pass "manual system proxy has a live Clash listener"; else fail "system proxy points at a dead Clash listener"; fi
    ;;
  "'none'") pass "system proxy is disabled" ;;
  *) warn "unrecognized GNOME proxy mode: $proxy_mode" ;;
esac

if rg -q '^# cc-switch-managed-official-proxy-v2$' "$codex_config" \
  && rg -q '^model_provider[[:space:]]*=[[:space:]]*"custom"' "$codex_config" \
  && rg -q '^requires_openai_auth[[:space:]]*=[[:space:]]*false' "$codex_config" \
  && rg -q '^base_url[[:space:]]*=[[:space:]]*"http://127\.0\.0\.1:15721/v1"' "$codex_config" \
  && rg -q '^experimental_bearer_token[[:space:]]*=[[:space:]]*"PROXY_MANAGED"' "$codex_config"; then
  pass "Codex live route is CC-managed and cannot consume auth.json"
else
  fail "Codex live route is not the complete managed placeholder shape"
fi

if jq -e '.preserveCodexOfficialAuthOnSwitch == true and .unifyCodexSessionHistory == true and .unifyCodexMigrateExisting == true' "$settings_path" >/dev/null; then
  pass "official-auth preservation and unified history settings are enabled"
else
  fail "required Codex preservation/history settings are not all enabled"
fi

if python3 - "$db_path" <<'PY'
import json, sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
rows = con.execute("select id,is_current,settings_config,meta from providers where app_type='codex'").fetchall()
managed = 0
leaked = 0
current = 0
for _, is_current, settings_raw, meta_raw in rows:
    settings = json.loads(settings_raw)
    meta = json.loads(meta_raw or "{}")
    binding = meta.get("authBinding") or meta.get("auth_binding") or {}
    is_managed = binding.get("source") == "managed_account" and binding.get("authProvider") == "codex_oauth"
    if is_managed:
        managed += 1
        auth = settings.get("auth")
        leaked += int(isinstance(auth, dict) and bool(auth))
    current += int(bool(is_current))
proxy_cols = [row[1] for row in con.execute("pragma table_info(proxy_config)")]
proxy_row = con.execute("select * from proxy_config where app_type='codex'").fetchone()
proxy = dict(zip(proxy_cols, proxy_row)) if proxy_row else {}
ok = managed > 0 and leaked == 0 and current == 1 and proxy.get("proxy_enabled") == 1 and proxy.get("enabled") == 1 and proxy.get("listen_address") == "127.0.0.1" and proxy.get("listen_port") == 15721
print(f"managed_rows={managed} token_snapshots={leaked} current_rows={current} proxy_enabled={proxy.get('proxy_enabled')} takeover={proxy.get('enabled')}")
raise SystemExit(0 if ok else 1)
PY
then
  pass "database has one current route, persistent takeover, and no managed-card token snapshots"
else
  fail "database Codex ownership/routing invariant failed"
fi

if [ ! -f "$codex_auth" ]; then
  pass "Codex has no native refresh token that could duplicate managed credentials"
elif python3 - "$codex_auth" "$managed_auth" <<'PY'
import hashlib, json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    native = json.load(handle)
with open(sys.argv[2], encoding="utf-8") as handle:
    managed = json.load(handle)
native_refresh = (native.get("tokens") or {}).get("refresh_token")
digest = lambda value: hashlib.sha256(value.encode()).digest() if isinstance(value, str) and value else None
native_digest = digest(native_refresh)
matches = [row for row in (managed.get("accounts") or {}).values() if native_digest is not None and digest(row.get("refresh_token")) == native_digest]
print(f"native_refresh_present={native_digest is not None} matches_managed_store={bool(matches)} managed_accounts={len(managed.get('accounts') or {})}")
raise SystemExit(0 if not matches and len(managed.get("accounts") or {}) > 0 else 1)
PY
then
  pass "dormant native auth.json is distinct from CC Switch managed refresh tokens"
else
  fail "a CC Switch managed refresh token is duplicated into Codex auth.json"
fi

for sensitive_file in "$managed_auth" "$codex_auth"; do
  [ -f "$sensitive_file" ] || continue
  mode="$(stat -c '%a' "$sensitive_file" 2>/dev/null || true)"
  if [ "$mode" = "600" ]; then pass "credential file mode is 600: $sensitive_file"; else fail "unsafe credential mode $mode: $sensitive_file"; fi
done

if python3 - "$codex_dir" <<'PY'
import collections, json, pathlib, sqlite3, sys
root = pathlib.Path(sys.argv[1])
bad = []
counts = {}
for folder in ("sessions", "archived_sessions"):
    providers = collections.Counter()
    files = list((root / folder).rglob("*.jsonl")) if (root / folder).exists() else []
    for path in files:
        try:
            meta = None
            with path.open(encoding="utf-8") as handle:
                for line in handle:
                    row = json.loads(line)
                    if row.get("type") == "session_meta":
                        meta = row.get("payload") or {}
                        break
            providers[str(meta.get("model_provider")) if meta else "<missing>"] += 1
        except Exception:
            bad.append(str(path))
    counts[folder] = {"total": len(files), "providers": dict(providers)}
con = sqlite3.connect(f"file:{root / 'state_5.sqlite'}?mode=ro", uri=True)
thread_counts = dict(con.execute("select model_provider,count(*) from threads group by model_provider"))
print(json.dumps({"rollouts": counts, "threads": thread_counts, "unreadable": len(bad)}, ensure_ascii=False))
ok = not bad and all(set(item["providers"]) <= {"custom"} for item in counts.values()) and set(thread_counts) <= {"custom"}
raise SystemExit(0 if ok else 1)
PY
then
  pass "active, archived, and SQLite Codex history all use the shared custom bucket"
else
  fail "Codex history still contains split/invalid provider buckets"
fi

if codex debug models -c "model_catalog_json=\"$repo_dir/src-tauri/src/resources/codex_deepseek_catalog_template.json\"" \
  | jq -e '.models | length == 2 and all(.[]; (.display_name | length) > 0 and ([.supported_reasoning_levels[].effort] == ["low","high","max"]))' >/dev/null; then
  pass "Codex CLI parses real DeepSeek names with only low/high/max reasoning levels"
else
  fail "Codex CLI rejected or misread the DeepSeek model catalog"
fi

if bash -n "$script_dir/cc-switch-launcher" \
  && bash -n "$script_dir/clash-verge-guarded" \
  && "$script_dir/test-launchers.sh" >/dev/null 2>&1; then
  pass "launcher syntax, stale-lease cleanup, multi-launch ownership, and signal forwarding"
else
  fail "launcher integration checks failed"
fi

clash_scheme_default="$(xdg-mime query default x-scheme-handler/clash 2>/dev/null || true)"
clash_verge_scheme_default="$(xdg-mime query default x-scheme-handler/clash-verge 2>/dev/null || true)"
if rg -q '^Exec=/usr/local/bin/clash-verge-guarded' "$user_home/.local/share/applications/Clash Verge.desktop" \
  && rg -q '^Exec=/usr/local/bin/clash-verge-guarded' "$user_home/.local/share/applications/clash-verge-handler.desktop" \
  && rg -q '^Exec=/usr/local/bin/clash-verge-guarded' "$user_home/.config/autostart/Clash Verge.desktop" \
  && [ "$clash_scheme_default" = "clash-verge-handler.desktop" ] \
  && [ "$clash_verge_scheme_default" = "clash-verge-handler.desktop" ]; then
  pass "all user Clash launch/protocol/autostart entries use the guarded launcher"
else
  fail "one or more user Clash launch entries or protocol defaults bypass the guarded launcher"
fi

printf 'summary: failures=%d warnings=%d\n' "$failures" "$warnings"
[ "$failures" -eq 0 ]
