#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

app_path=""
keep_running=0
settle_timeout=10

while (( $# > 0 )); do
  case "$1" in
    --app)
      app_path="$2"
      shift 2
      ;;
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    *)
      echo "Usage: $0 [--app /path/to/Ghostty.app] [--timeout SECONDS] [--keep-running]" >&2
      exit 1
      ;;
  esac
done

function join_json_array() {
  local values=("$@")
  if (( ${#values[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${values[@]}" | jq -Rsc 'split("\n")[:-1] | map(select(length > 0))'
}

function wait_for_pane_text() {
  local socket_name="$1"
  local target="$2"
  local expected="$3"
  local timeout="$4"
  local output_var_name="$5"
  local deadline=$(( EPOCHSECONDS + timeout ))
  local captured=""

  while (( EPOCHSECONDS < deadline )); do
    captured="$(tmux -L "$socket_name" capture-pane -p -t "$target" -S -50 2>/dev/null || true)"
    if [[ "$captured" == *"$expected"* ]]; then
      typeset -g "$output_var_name=$captured"
      return 0
    fi
    sleep 0.2
  done

  typeset -g "$output_var_name=$captured"
  return 1
}

function wait_for_pane_regex() {
  local socket_name="$1"
  local target="$2"
  local pattern="$3"
  local timeout="$4"
  local output_var_name="$5"
  local deadline=$(( EPOCHSECONDS + timeout ))
  local captured=""

  while (( EPOCHSECONDS < deadline )); do
    captured="$(tmux -L "$socket_name" capture-pane -p -t "$target" -S -50 2>/dev/null || true)"
    if perl -0ne "exit((/${pattern}/s) ? 0 : 1)" <<<"$captured"; then
      typeset -g "$output_var_name=$captured"
      return 0
    fi
    sleep 0.2
  done

  typeset -g "$output_var_name=$captured"
  return 1
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

helper_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --dry-run)"
helper_trusted="$(jq -r '.trusted' <<<"$helper_json")"
if [[ "$helper_trusted" != "true" ]]; then
  echo "AX helper is not trusted: $helper_json" >&2
  exit 2
fi

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
socket_name="gate-l-native-${token}"
session_name="gate-l-native-${token}"
target="${session_name}:main"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-native-input.XXXXXX")"
pane_driver="$tmpdir/pane-driver.sh"
capture_after_send=""
capture_after_ready=""

cat >"$pane_driver" <<'EOF'
#!/bin/sh
printf '__GATE_L_READY__\n'
while IFS= read -r line; do
  printf '__GATE_L_RECV__:%s\n' "$line"
done
EOF
chmod +x "$pane_driver"

typeset -A existing_pids
prelaunch_pids=("${(@f)$(pgrep -f -- "$app_bin" || true)}")
for pid in "${prelaunch_pids[@]}"; do
  [[ -n "$pid" ]] && existing_pids[$pid]=1
done

launched_pid=""
launch_reused_existing=0
activate_exit_code=0
activate_ok=0
smoke_ok=0
send_a_json=""
send_return_json=""

cleanup() {
  local exit_status=$?
  if [[ -n "$launched_pid" && "$keep_running" != "1" ]]; then
    kill "$launched_pid" 2>/dev/null || true
  fi
  tmux -L "$socket_name" kill-server >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

tmux -L "$socket_name" start-server
tmux -L "$socket_name" new-session -d -s "$session_name" -n main "$pane_driver"

pane_id="$(tmux -L "$socket_name" display-message -p -t "$target" '#{pane_id}')"

if ! wait_for_pane_text "$socket_name" "$target" "__GATE_L_READY__" "$settle_timeout" capture_after_ready; then
  echo "Timed out waiting for pane readiness banner" >&2
  exit 1
fi

open -na "$app_path" --args --window-inherit-working-directory=never -e tmux -L "$socket_name" attach-session -t "$session_name" >/dev/null 2>&1
sleep 2

postlaunch_pids=("${(@f)$(pgrep -f -- "$app_bin" || true)}")
for pid in "${postlaunch_pids[@]}"; do
  [[ -z "$pid" ]] && continue
  if [[ -z "${existing_pids[$pid]-}" ]]; then
    launched_pid="$pid"
    break
  fi
done

if [[ -z "$launched_pid" && ${#postlaunch_pids[@]} -gt 0 ]]; then
  launched_pid="${postlaunch_pids[-1]}"
  launch_reused_existing=1
fi

set +e
perl -e 'alarm 5; exec @ARGV' osascript -e "tell application id \"$bundle_id\" to activate" >/dev/null 2>"$tmpdir/activate.stderr"
activate_exit_code=$?
set -e
if (( activate_exit_code == 0 )); then
  activate_ok=1
fi

if (( activate_ok != 1 )); then
  echo "Failed to activate Ghostty bundle id $bundle_id" >&2
  exit 1
fi

sleep 1
send_a_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --key-code 0)"
send_return_json="$("$SCRIPT_DIR/gate_l_ax_key_sender.sh" --key-code 36)"

if wait_for_pane_regex "$socket_name" "$target" '__GATE_L_RECV__:\s*a' "$settle_timeout" capture_after_send; then
  smoke_ok=1
fi

jq -n \
  --arg app_path "$app_path" \
  --arg display_name "$display_name" \
  --arg bundle_id "$bundle_id" \
  --arg executable "$app_bin" \
  --arg session_name "$session_name" \
  --arg socket_name "$socket_name" \
  --arg target "$target" \
  --arg pane_id "$pane_id" \
  --arg capture_after_ready "$capture_after_ready" \
  --arg capture_after_send "$capture_after_send" \
  --argjson helper "$helper_json" \
  --argjson send_a "$send_a_json" \
  --argjson send_return "$send_return_json" \
  --argjson prelaunch_pids "$(join_json_array "${prelaunch_pids[@]}")" \
  --argjson postlaunch_pids "$(join_json_array "${postlaunch_pids[@]}")" \
  --arg launched_pid "${launched_pid:-}" \
  --argjson launch_reused_existing "$launch_reused_existing" \
  --argjson activate_exit_code "$activate_exit_code" \
  --arg activate_stderr "$(cat "$tmpdir/activate.stderr" 2>/dev/null || true)" \
  --argjson smoke_ok "$smoke_ok" \
  '{
    app_path: $app_path,
    display_name: $display_name,
    bundle_id: $bundle_id,
    executable: $executable,
    tmux: {
      session_name: $session_name,
      socket_name: $socket_name,
      target: $target,
      pane_id: $pane_id,
      ready_capture: $capture_after_ready,
      final_capture: $capture_after_send
    },
    helper: $helper,
    launch: {
      launched_pid: (if $launched_pid == "" then null else ($launched_pid | tonumber) end),
      reused_existing_process: ($launch_reused_existing == 1),
      prelaunch_pids: ($prelaunch_pids | map(tonumber)),
      postlaunch_pids: ($postlaunch_pids | map(tonumber))
    },
    activation: {
      ok: ($activate_exit_code == 0),
      exit_code: $activate_exit_code,
      stderr: $activate_stderr
    },
    sends: {
      key_a: $send_a,
      return: $send_return
    },
    input_delivery: {
      ok: ($smoke_ok == 1),
      expected_pattern: "__GATE_L_RECV__:\\s*a"
    }
  }'

if (( smoke_ok != 1 )); then
  exit 1
fi
