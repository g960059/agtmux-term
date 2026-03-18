#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd -- "${0:A:h}" && pwd -P)"
GATE_L_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
source "$SCRIPT_DIR/gate_l_common.sh"

duration=10
interval=1
settle_timeout=15
native_app_path=""
keep_running=0
allow_existing=0

while (( $# > 0 )); do
  case "$1" in
    --duration)
      duration="$2"
      shift 2
      ;;
    --interval)
      interval="$2"
      shift 2
      ;;
    --timeout)
      settle_timeout="$2"
      shift 2
      ;;
    --app)
      native_app_path="$2"
      shift 2
      ;;
    --keep-running)
      keep_running=1
      shift
      ;;
    --allow-existing)
      allow_existing=1
      shift
      ;;
    *)
      echo "Usage: $0 [--duration SECONDS] [--interval SECONDS] [--timeout SECONDS] [--app /path/to/Ghostty.app] [--keep-running] [--allow-existing]" >&2
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

function launch_native_ghostty_idle() {
  if [[ -z "$native_app_path" ]]; then
    if ! native_app_path="$(gate_l_resolve_native_ghostty_app_path)"; then
      echo "Could not locate Ghostty.app in /Applications, Spotlight, or vendor/ghostty/zig-out" >&2
      return 1
    fi
  fi

  if [[ ! -d "$native_app_path" ]]; then
    echo "Ghostty.app does not exist: $native_app_path" >&2
    return 1
  fi

  local plist_path="$native_app_path/Contents/Info.plist"
  native_bundle_id="$(gate_l_read_plist_value "$plist_path" "CFBundleIdentifier")"
  native_display_name="$(gate_l_read_plist_value "$plist_path" "CFBundleDisplayName")"
  local executable_name
  executable_name="$(gate_l_read_plist_value "$plist_path" "CFBundleExecutable")"

  if [[ -z "$native_bundle_id" || -z "$executable_name" ]]; then
    echo "Failed to read Ghostty bundle metadata from $plist_path" >&2
    return 1
  fi

  native_app_bin="$native_app_path/Contents/MacOS/$executable_name"
  if [[ ! -x "$native_app_bin" ]]; then
    echo "Ghostty executable is not runnable: $native_app_bin" >&2
    return 1
  fi

  typeset -gA native_existing_pids
  native_prelaunch_pids=("${(@f)$(pgrep -f -- "$native_app_bin" || true)}")
  native_prelaunch_pids=(${native_prelaunch_pids:#})
  for pid in "${native_prelaunch_pids[@]}"; do
    [[ -n "$pid" ]] && native_existing_pids[$pid]=1
  done

  if (( allow_existing != 1 && ${#native_prelaunch_pids[@]} > 0 )); then
    echo "Existing native Ghostty processes would make idle baseline attribution ambiguous; rerun after closing them or pass --allow-existing: ${native_prelaunch_pids[*]}" >&2
    return 1
  fi

  native_socket_name="gate-l-native-idle-${token}"
  native_session_name="gate-l-native-idle-${token}"
  tmux -L "$native_socket_name" start-server
  tmux -L "$native_socket_name" new-session -d -s "$native_session_name" -n main /bin/sleep 600

  open -na "$native_app_path" --args -e tmux -L "$native_socket_name" attach-session -t "$native_session_name" >/dev/null 2>&1
  sleep 2

  native_postlaunch_pids=("${(@f)$(pgrep -f -- "$native_app_bin" || true)}")
  native_postlaunch_pids=(${native_postlaunch_pids:#})
  native_pid=""
  native_launch_reused_existing=0
  for pid in "${native_postlaunch_pids[@]}"; do
    [[ -z "$pid" ]] && continue
    if [[ -z "${native_existing_pids[$pid]-}" ]]; then
      native_pid="$pid"
      break
    fi
  done

  if [[ -z "$native_pid" && ${#native_postlaunch_pids[@]} -gt 0 ]]; then
    native_pid="${native_postlaunch_pids[-1]}"
    native_launch_reused_existing=1
  fi

  if [[ -z "$native_pid" ]]; then
    echo "Failed to resolve a native Ghostty pid after launch" >&2
    return 1
  fi

  perl -e 'alarm 5; exec @ARGV' osascript -e "tell application id \"$native_bundle_id\" to activate" >/dev/null 2>"$native_tmpdir/activate.stderr"
  sleep 1
}

function launch_agtmux_idle() {
  gate_l_require_app_bin

  agtmux_socket_name="agtmux-gate-l-idle-${token}"
  agtmux_session_name="agtmux-gate-l-idle-${token}"
  gate_l_setup_paths "$token"
  gate_l_launch_app "$agtmux_socket_name" "$agtmux_session_name" 1 "/bin/sleep 600"
  gate_l_activate_app

  local bootstrap_json
  bootstrap_json="$(gate_l_wait_for_bootstrap "$settle_timeout")"
  if [[ "$(jq -r '.ok' <<<"$bootstrap_json")" != "true" ]]; then
    echo "App-side bootstrap failed: $(jq -r '.error // \"unknown error\"' <<<"$bootstrap_json")" >&2
    return 1
  fi

  local bootstrap_first_pane_id
  bootstrap_first_pane_id="$(jq -r '.paneIDs[0]' <<<"$bootstrap_json")"
  gate_l_send_bridge_command false 10 "__agtmux_open_terminal_for_pane__" "local" "$agtmux_session_name" "$bootstrap_first_pane_id" >/dev/null
  gate_l_activate_app
  gate_l_wait_for_active_snapshot "$agtmux_session_name" "$settle_timeout" >/dev/null
  sleep 1
}

token="$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
native_tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/gate-l-native-idle.XXXXXX")"
typeset -a native_prelaunch_pids native_postlaunch_pids
typeset -a agtmux_cleanup_notes
native_pid=""
native_bundle_id=""
native_display_name=""
native_app_bin=""
native_socket_name=""
native_session_name=""
native_launch_reused_existing=0

cleanup() {
  local exit_status=$?
  if [[ "$keep_running" != "1" ]]; then
    if [[ -n "${native_pid:-}" ]]; then
      kill "$native_pid" 2>/dev/null || true
    fi
    if [[ -n "${native_socket_name:-}" ]]; then
      tmux -L "$native_socket_name" kill-server >/dev/null 2>&1 || true
    fi
    gate_l_terminate_app
    gate_l_cleanup_tmux
  fi
  rm -rf "$native_tmpdir"
  if (( exit_status == 0 )) && [[ "${AGTMUX_PERF_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "${gate_l_tmpdir:-}"
  elif [[ -n "${gate_l_tmpdir:-}" ]]; then
    echo "Gate-L idle parity temp dir: $gate_l_tmpdir" >&2
  fi
  exit "$exit_status"
}
trap cleanup EXIT INT TERM

launch_native_ghostty_idle
launch_agtmux_idle

native_idle_json="$("$SCRIPT_DIR/gate_l_idle_sample.sh" --pid "$native_pid" --duration "$duration" --interval "$interval")"
agtmux_idle_json="$("$SCRIPT_DIR/gate_l_idle_sample.sh" --pid "$gate_l_app_pid" --duration "$duration" --interval "$interval")"

jq -n \
  --arg native_app_path "$native_app_path" \
  --arg native_bundle_id "$native_bundle_id" \
  --arg native_display_name "$native_display_name" \
  --arg native_app_bin "$native_app_bin" \
  --arg agtmux_app_bin "$GATE_L_APP_BIN" \
  --arg native_session_name "$native_session_name" \
  --arg native_socket_name "$native_socket_name" \
  --arg agtmux_session_name "$agtmux_session_name" \
  --arg agtmux_socket_name "$agtmux_socket_name" \
  --argjson native_launch_reused_existing "$native_launch_reused_existing" \
  --argjson native_prelaunch_pids "$(join_json_array "${native_prelaunch_pids[@]}")" \
  --argjson native_postlaunch_pids "$(join_json_array "${native_postlaunch_pids[@]}")" \
  --argjson native "$native_idle_json" \
  --argjson agtmux "$agtmux_idle_json" '
  def round3:
    ((. * 1000.0) | round) / 1000.0;

  {
    duration_s: $native.duration_s,
    interval_s: $native.interval_s,
    native_ghostty: {
      app_path: $native_app_path,
      bundle_id: $native_bundle_id,
      display_name: $native_display_name,
      executable: $native_app_bin,
      tmux: {
        session_name: $native_session_name,
        socket_name: $native_socket_name
      },
      launch: {
        reused_existing_process: ($native_launch_reused_existing == 1),
        prelaunch_pids: ($native_prelaunch_pids | map(tonumber)),
        postlaunch_pids: ($native_postlaunch_pids | map(tonumber))
      },
      idle: $native
    },
    agtmux_term: {
      app_bin: $agtmux_app_bin,
      tmux: {
        session_name: $agtmux_session_name,
        socket_name: $agtmux_socket_name
      },
      idle: $agtmux
    },
    comparison: {
      avg_cpu_delta_pct_points: (($agtmux.avg_cpu_pct - $native.avg_cpu_pct) | round3),
      max_cpu_delta_pct_points: (($agtmux.max_cpu_pct - $native.max_cpu_pct) | round3),
      avg_mem_delta_mib: (($agtmux.avg_mem_mib - $native.avg_mem_mib) | round3),
      max_mem_delta_mib: (($agtmux.max_mem_mib - $native.max_mem_mib) | round3),
      avg_cpu_ratio: (
        if $native.avg_cpu_pct == 0 then
          null
        else
          (($agtmux.avg_cpu_pct / $native.avg_cpu_pct) | round3)
        end
      ),
      max_cpu_ratio: (
        if $native.max_cpu_pct == 0 then
          null
        else
          (($agtmux.max_cpu_pct / $native.max_cpu_pct) | round3)
        end
      ),
      idle_cpu_within_plus_3pt: ((($agtmux.avg_cpu_pct - $native.avg_cpu_pct) <= 3.0))
    }
  }'
