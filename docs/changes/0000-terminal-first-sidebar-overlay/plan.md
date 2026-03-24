# Plan

1. Rewrite durable product and decision docs around the terminal-first sidebar
   overlay model.
2. Define the minimal main-terminal model for the main panel.
3. Implement plain-shell startup and `New Shell` reset behavior.
4. Implement sidebar activation as in-place retarget when possible, else
   single-terminal reattach.
5. Add diagnostics for attach, restore, and terminal/sidebar drift failures.
6. Retire or quarantine generic workbench flows from the mainline UX once the
   thinner terminal-first host is working.
