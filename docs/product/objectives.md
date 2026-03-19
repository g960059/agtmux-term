# Objectives

Primary objectives:

- provide a fast session-centric sidebar for local and remote tmux sessions
- keep daemon-backed sidebar rows legible at a glance: provider icon on the
  leading edge, activity ring only for active/attention states, and trailing
  freshness only for non-running managed panes
- open, focus, and reveal existing sessions without obvious duplicates
- surface daemon, host, binding, and automation failures clearly
- preserve normal Ghostty / tmux / shell behavior
- keep remote support no-install by default
- maintain a lightweight companion model rather than an IDE-style workspace
