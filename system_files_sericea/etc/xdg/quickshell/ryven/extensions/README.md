# Bar extensions

Drop any `*.qml` file into this directory and it appears in the bar (sorted
by filename; system extensions in `/etc/xdg/quickshell/ryven/extensions/
load first). Saving reloads the bar automatically.

- Contract: root `Item`, height ≤ 22 px, self-contained — full details in
  `../../AGENTS.md`.
- `example-hello.qml.off` is a ready-made example: rename it to
  `example-hello.qml` to see it in the bar.
- AI-assisted: `ujust customize-bar` opens the pi coding agent in
  `~/.config/quickshell` with all of this pre-loaded as context.
