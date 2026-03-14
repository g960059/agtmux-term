#!/bin/zsh
set -euo pipefail

REPO_ROOT="$(cd -- "${0:A:h}/../.." && pwd -P)"
SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$REPO_ROOT"
source "$SCRIPT_DIR/gate_l_common.sh"

app_path=""
keep_running=0

while (( $# > 0 )); do
  case "$1" in
    --app)
      app_path="$2"
      shift 2
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    *)
      echo "Usage: $0 [--app /path/to/Ghostty.app] [--keep-running]" >&2
      exit 1
      ;;
  esac
done

function json_escape() {
  jq -Rn --arg value "$1" '$value'
}

function join_json_array() {
  local values=("$@")
  if (( ${#values[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${values[@]}" | jq -Rsc 'split("\n")[:-1] | map(select(length > 0))'
}

if [[ -z "$app_path" ]]; then
  if ! app_path="$(gate_l_resolve_native_ghostty_app_path)"; then
    echo "Could not locate Ghostty.app in /Applications, Spotlight, or vendor/ghostty/zig-out" >&2
    exit 1
  fi
fi

if [[ ! -d "$app_path" ]]; then
  echo "Ghostty.app does not exist: $app_path" >&2
  exit 1
fi

plist_path="$app_path/Contents/Info.plist"
bundle_id="$(gate_l_read_plist_value "$plist_path" "CFBundleIdentifier")"
display_name="$(gate_l_read_plist_value "$plist_path" "CFBundleDisplayName")"
executable_name="$(gate_l_read_plist_value "$plist_path" "CFBundleExecutable")"

if [[ -z "$bundle_id" || -z "$executable_name" ]]; then
  echo "Failed to read Ghostty bundle metadata from $plist_path" >&2
  exit 1
fi

app_bin="$app_path/Contents/MacOS/$executable_name"
if [[ ! -x "$app_bin" ]]; then
  echo "Ghostty executable is not runnable: $app_bin" >&2
  exit 1
fi

app_source="explicit"
if [[ "$app_path" == "/Applications/Ghostty.app" ]]; then
  app_source="applications"
elif [[ "$app_path" == "$REPO_ROOT/vendor/ghostty/zig-out/Ghostty.app" ]]; then
  app_source="vendored"
elif [[ "$app_path" == *"/Ghostty.app" ]]; then
  app_source="spotlight"
fi

version_output="$("$app_bin" +version 2>/dev/null || true)"
version_line="$(print -r -- "$version_output" | head -n 1)"
version="$(print -r -- "$version_output" | awk -F': ' '/- version:/{print $2; exit}')"
if [[ -z "$version" ]]; then
  version="$version_line"
fi

typeset -A existing_pids
prelaunch_pids=("${(@f)$(pgrep -f -- "$app_bin" || true)}")
for pid in "${prelaunch_pids[@]}"; do
  [[ -n "$pid" ]] && existing_pids[$pid]=1
done

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-native-ghostty-probe.XXXXXX")"
activate_stdout="$tmpdir/activate.stdout"
activate_stderr="$tmpdir/activate.stderr"
key_stdout="$tmpdir/key.stdout"
key_stderr="$tmpdir/key.stderr"

launched_pid=""
launch_reused_existing=0
launched_ok=0
activate_ok=0
activate_exit_code=0
key_ok=0
key_exit_code=0

cleanup() {
  if [[ -n "$launched_pid" && "$keep_running" != "1" ]]; then
    kill "$launched_pid" 2>/dev/null || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT INT TERM

open -na "$app_path" --args --window-inherit-working-directory=never -e /bin/sleep 600 >/dev/null 2>&1
sleep 3

postlaunch_pids=("${(@f)$(pgrep -f -- "$app_bin" || true)}")
for pid in "${postlaunch_pids[@]}"; do
  [[ -z "$pid" ]] && continue
  if [[ -z "${existing_pids[$pid]-}" ]]; then
    launched_pid="$pid"
    launched_ok=1
    break
  fi
done

if [[ -z "$launched_pid" && ${#postlaunch_pids[@]} -gt 0 ]]; then
  launched_pid="${postlaunch_pids[-1]}"
  launch_reused_existing=1
  launched_ok=1
fi

set +e
perl -e 'alarm 5; exec @ARGV' osascript -e "tell application id \"$bundle_id\" to activate" >"$activate_stdout" 2>"$activate_stderr"
activate_exit_code=$?
set -e
if (( activate_exit_code == 0 )); then
  activate_ok=1
fi

set +e
perl -e 'alarm 5; exec @ARGV' osascript \
  -e "tell application id \"$bundle_id\" to activate" \
  -e 'tell application "System Events" to key code 125' \
  >"$key_stdout" 2>"$key_stderr"
key_exit_code=$?
set -e
if (( key_exit_code == 0 )); then
  key_ok=1
fi

jq -n \
  --arg app_path "$app_path" \
  --arg app_source "$app_source" \
  --arg display_name "$display_name" \
  --arg bundle_id "$bundle_id" \
  --arg executable "$app_bin" \
  --arg version "$version" \
  --arg version_line "$version_line" \
  --argjson prelaunch_pids "$(join_json_array "${prelaunch_pids[@]}")" \
  --argjson postlaunch_pids "$(join_json_array "${postlaunch_pids[@]}")" \
  --arg launched_pid "${launched_pid:-}" \
  --argjson launched_ok "$launched_ok" \
  --argjson launch_reused_existing "$launch_reused_existing" \
  --argjson activate_ok "$activate_ok" \
  --argjson activate_exit_code "$activate_exit_code" \
  --arg activate_stdout "$(cat "$activate_stdout" 2>/dev/null || true)" \
  --arg activate_stderr "$(cat "$activate_stderr" 2>/dev/null || true)" \
  --argjson key_ok "$key_ok" \
  --argjson key_exit_code "$key_exit_code" \
  --arg key_stdout "$(cat "$key_stdout" 2>/dev/null || true)" \
  --arg key_stderr "$(cat "$key_stderr" 2>/dev/null || true)" \
  '{
    app_path: $app_path,
    app_source: $app_source,
    display_name: $display_name,
    bundle_id: $bundle_id,
    executable: $executable,
    version: $version,
    version_line: $version_line,
    launch: {
      ok: ($launched_ok == 1),
      launched_pid: (if $launched_pid == "" then null else ($launched_pid | tonumber) end),
      reused_existing_process: ($launch_reused_existing == 1),
      prelaunch_pids: ($prelaunch_pids | map(tonumber)),
      postlaunch_pids: ($postlaunch_pids | map(tonumber))
    },
    activation: {
      ok: ($activate_ok == 1),
      exit_code: $activate_exit_code,
      stdout: $activate_stdout,
      stderr: $activate_stderr
    },
    key_injection: {
      ok: ($key_ok == 1),
      exit_code: $key_exit_code,
      stdout: $key_stdout,
      stderr: $key_stderr
    }
  }'
