Status icons from [Lucide](https://lucide.dev/icons/), revision `a79b2d131dab2bf20cb224bd0937b439a9c4fa99`.

- `idle.svg`: `check`, 14px, stroke 4
- `busy.svg`: `activity`, 16px, stroke 4
- `blocked.svg`: `message-circle-question-mark`, 16px, stroke 3
- `dead.svg`: `x`, 12px, stroke 3

Adaptations: HQ status colors, per-state sizes and strokes, and tighter
viewBoxes matching the mockup. Icons are vertically centered with text.
Horizontal image margins reserve a shared 16px column, so session names
align regardless of icon size. Automatic image scaling is disabled.
Keep `agent-shell-hq-peek--icon-sizes` in sync with the SVG sizes.
Busy animation uses a 30% opacity base trace and a traveling highlight
covering 22% of the path, looping every 3 seconds (60 cached frames at 20fps).
Dash lengths are in SVG user units for compatibility with Emacs SVG renderers. Inline copies in `agent-shell-hq-peek.el` must stay in sync.
See [LICENSE](LICENSE) for Lucide and Feather license notices.
