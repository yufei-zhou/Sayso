# Testing Sayso without the keyboard, the clipboard or the real API

Everything here runs in the background (`open -g`), never touches the clipboard, and never calls OpenAI.

## Set up
1. Back up the user's state first, and restore it afterwards:
   `defaults export local.nano.Sayso backup.plist` and a copy of `~/Library/Application Support/Sayso/history.json`
   (restore with `defaults delete local.nano.Sayso; defaults import local.nano.Sayso backup.plist`).
2. `python3 Scripts/test/mock_api.py &` — a local stand-in for the OpenAI Responses API on port 8765.
   Put a tag in the text to pick a scenario: `#401 #429 #500 #empty #failed #halffail #drop #slow #lag #long`.
   "I goes" in Polish mode returns one grammar issue.
3. `Scripts/test/launch.sh` — runs the installed app with `SAYSO_DEBUG_HOOKS=1` (and `SAYSO_TEST_PASTEBOARD` if set), the mock API and a fake key.
   `Scripts/test/launch.sh ""` simulates having no key; a second argument such as `http://127.0.0.1:9` simulates
   being offline.
4. When done: `pkill -x Sayso; open -g /Applications/Sayso.app` (a normal launch ignores every `sayso://` link).

## Hooks (`open -g "sayso://…"`, only with SAYSO_DEBUG_HOOKS=1)
- `show?text=…&mode=polish|reply|zh&note=…` shows the panel without taking the keyboard and runs.
- `type?text=…` edits the input as if typed; `run`; `hide`; `key?k=n` (⌘N, ⌘1…);
  `keydown?code=36&mods=shift&focus=1` (a key press into the panel's focused view: 36 Return, 53 Esc, 48 Tab).
- `state?path=…` writes the model and panel state as JSON; `snapshot?path=…` renders the panel to a PNG.
- `settings?tab=general|prompts`, `history`, `window-snapshot?name=settings|history&path=…`, `close-windows`.
- `appearance?name=dark|light|auto` for Sayso's own windows.
- `ax-probe?path=…` lists what each running app exposes about its selection (codes and lengths, never text).
- `ax-read?pid=…&path=…[&web=1][&replace=…]` reads (and optionally replaces) one app's selection;
  `Scripts/test/axhost.swift` is a small window with a web page and native text views to point it at
  (`swiftc -O axhost.swift -o axhost`; commands on stdin: page, textarea, editable, native, readonly, value, quit).
- `modtap-test?path=…` feeds made-up key sequences (on their own clock) to the double-tap-a-modifier logic and writes
  PASS/FAIL per case: ⌘⌘ triggers once; slow taps, ⌘C/⌘V, a held ⌘, ⌘⇧, a click in between and ⇧⇧ don't.
- `menukey?k=q` offers ⌘<key> to the hidden main menu (⌘Q quits from Settings/History; in the panel `key?k=q` only hides it).
- Clipboard fallback (apps that expose nothing about selections): start both Sayso and the test window with the same
  `SAYSO_TEST_PASTEBOARD=<name>` so they use a pasteboard of their own instead of the real clipboard.
  `ax-copy?pid=…&path=…` asks the app to copy and reports what came back; `select?pid=…` runs the whole shortcut
  path for that app without taking the keyboard; `replace?voice=sharp|chill` does what the Replace button does.
  Test-window commands: `seed` (fills the test pasteboard with two items in several formats), `digest` (fingerprint
  of everything on it — must be identical before and after), `secret` (a password-manager-style item), `opaque`,
  `opaquenone`, `opaquereadonly`, `opaquevalue`. `state` reports `clipboardChangeCount` of the real clipboard, which
  must not move.
- `trigger` runs the real shortcut path: it reads the frontmost app's selection and **takes the keyboard**.

Offscreen snapshots draw a few things differently from the screen (e.g. stray lines at the ends of the Update
pill). For the real look: `state` gives window numbers, then `screencapture -x -o -l <number> out.png`.
