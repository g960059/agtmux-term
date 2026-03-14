#!/bin/zsh
set -euo pipefail

session_name="${1:-agtmux-perf-scroll}"
line_count="${AGTMUX_PERF_LINES:-40000}"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not found" >&2
  exit 1
fi

if tmux has-session -t "${session_name}" 2>/dev/null; then
  pane_target="$(tmux list-panes -t "${session_name}" -F '#S:#I.#P' | head -n 1)"
  tmux send-keys -t "${pane_target}" C-c
  tmux send-keys -t "${pane_target}" "clear" C-m
else
  tmux new-session -d -s "${session_name}" -x 160 -y 48
  pane_target="$(tmux list-panes -t "${session_name}" -F '#S:#I.#P' | head -n 1)"
fi

tmux send-keys -t "${pane_target}" \
  "awk 'BEGIN { for (i = 1; i <= ${line_count}; i++) printf \"%06d agtmux local perf scroll baseline 0123456789abcdefghijklmnopqrstuvwxyz\\n\", i }'" \
  C-m

echo "Prepared tmux session: ${session_name}"
echo "Pane target: ${pane_target}"
echo "Output lines: ${line_count}"
echo "Open or focus this session in agtmux-term, then profile scroll/input latency."
