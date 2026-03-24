# Plan

1. Rewrite durable product and decision docs around the session-first embedded
   Ghostty cockpit model.
2. Define the minimal session-viewport model for the main panel.
3. Implement session-row activation as "reveal existing viewport first, else
   open or retarget one in the main panel".
4. Add diagnostics for attach, restore, and session/viewport drift failures.
5. Retire or quarantine generic workbench flows from the mainline UX once the
   thinner session-first host is working.
