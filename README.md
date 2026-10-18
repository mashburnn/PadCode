# PadCode

A native iPad editor that looks like VS Code and works on your desktops (macOS,
Windows, Linux) through **VS Code Remote Tunnels**. Files, editing, search and
terminals all run on the desktop; the iPad only renders.

- `core/`: Rust. GitHub sign-in, tunnel discovery/connection (Microsoft's
  dev-tunnels SDK), and the VS Code CLI control-server protocol (files,
  processes, ptys). Exposed to Swift via UniFFI.
- `ios/`: SwiftUI app. Runestone editor, SwiftTerm terminal, VS Code themes,
  Seti file icons and Codicons.

## Add a desktop

Do this once per machine. Use the **same GitHub account** on every machine and
give each one a unique name (letters, digits and `-`, up to 20 characters).

### macOS
```sh
CODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"
"$CODE" tunnel user login --provider github        # once, if not signed in
"$CODE" tunnel service install --name <name> --accept-server-license-terms
# The CLI writes its launchd plist to ~/ and loads it for this login only.
# Move it into LaunchAgents so it also starts after reboots/logins:
cp ~/com.visualstudio.code.tunnel.plist ~/Library/LaunchAgents/
launchctl bootout gui/$(id -u)/com.visualstudio.code.tunnel 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.visualstudio.code.tunnel.plist
"$CODE" tunnel status                              # "tunnel":"Connected"
```
To keep it reachable, go to System Settings → Battery → Options and turn on
*Prevent automatic sleeping on power adapter when the display is off*.
To remove it, run `"$CODE" tunnel service uninstall` and then
`rm ~/Library/LaunchAgents/com.visualstudio.code.tunnel.plist`.

### Windows (PowerShell)
```powershell
code tunnel user login --provider github
code tunnel service install --name <name> --accept-server-license-terms
code tunnel status
```
The service starts when you sign in to Windows, so stay signed in (locking the
screen is fine). Set Settings → System → Power → Sleep to *Never* while
plugged in. Terminals need Windows 10 1809 or later.

### Linux
```sh
# VS Code installed: `code` is on PATH. Headless: use the standalone CLI:
curl -L 'https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-x64' | tar xz   # or cli-alpine-arm64
./code tunnel user login --provider github
./code tunnel service install --name <name> --accept-server-license-terms
sudo loginctl enable-linger "$USER"     # keep running while logged out
systemctl --user status code-tunnel
```
Disable suspend on the machine. If `python3` is installed, terminals can be
resized; without it they still work through `script`, but at a fixed size.

Keep VS Code or the CLI up to date on every desktop. PadCode needs tunnel
protocol v6 and was tested with VS Code 1.142.

## Using it

- **Connect:** tap a running desktop. You land on an empty window, like VS Code.
  Pick a folder or file in the **Open Folder or File** box (⌘O any time). Type a
  path or tap through folders; the text after the last `/` filters the list, Tab
  completes it, and the eye button shows dotfiles. Recent folders are listed first.
- **Explorer:** long-press a file or folder and drag it onto a folder to move it.
  Dropping on a file moves into that file's folder; dropping on the folder header
  or the empty space below moves into the root. Open tabs follow moved files.
- **IntelliSense:** errors and warnings (tinted in the editor, listed under
  PROBLEMS, counted in the status bar), autocomplete as you type or with ⌃Space /
  ⌘I, hover info with ⌘K ⌘I (or tap the message bar under the editor), and go to
  definition with F12. These come from the language's own server running on the
  desktop: rust-analyzer, clangd, sourcekit-lsp, pyright, typescript-language-server,
  gopls, lua-language-server or ruby-lsp, whichever is on the desktop's PATH. If
  one is missing, the status bar says "No … server". Tap it to type the install
  command into a terminal.
- **More IntelliSense:** F2 renames a symbol across files, ⇧F12 lists references,
  ⌘. (or the 💡 Quick Fix button on the problem bar) offers quick fixes and
  refactors, and parameter hints appear while typing a call. ⇧⌥F formats the
  document, and Format on Save is available in Settings.
- **Run and tasks:** the ▶ button (or ⌃F5) saves and runs the current file in a
  terminal (Python, Node, Go, Rust, C/C++, Swift, shell…). ⇧⌘B lists tasks
  detected from `package.json`, `Cargo.toml`, `go.mod`, `Package.swift`,
  `Makefile` and `.vscode/tasks.json`.
- **Ports:** the PORTS panel lists what's listening on the desktop. Preview opens
  it in a browser tab inside PadCode, reached through the tunnel (nothing is
  exposed publicly).
- **Editor:** ⌘\\ split editor, ⌃G go to line, ⇧⌘O go to symbol, the Outline
  view, ⇧⌘H find and replace in files (match case, whole word, regex), Markdown
  preview, and image and PDF viewing. Matching brackets are highlighted.
- **Line editing:** ⌘/ toggle comment, ⌥↑/⌥↓ move lines, ⇧⌥↑/⇧⌥↓ copy lines,
  ⇧⌘K delete line, ⌘] / ⌘[ indent, ⌘↩ / ⇧⌘↩ insert a line below or above. Each
  is one undo step. ⌃- / ⌃⇧- go back and forward after a jump, and ⇧⌘T reopens
  the last closed editor. All of these are in the menu bar (hold ⌘ to see them).
- **Files app:** drag files or folders in from Files (or use the cloud button),
  and long-press a file and choose Download to iPad. ⌘, opens Settings.
- **Reconnects:** after the iPad sleeps or the network changes, PadCode notices
  within about 15 seconds and reconnects. Terminals restart and language servers
  come back.
- **Windows:** each window is one desktop. ⇧⌘N opens a new home window to pick
  any desktop. Long-press a folder in the Explorer or a recent folder on the home
  page and choose Open in New Window. Arrange windows with Split View or Stage
  Manager. iPadOS reopens each window on the folder it last had open.
- **Big files:** files over 50 MB, and binaries, aren't opened (use the terminal).
  Files over 2 MB, or with a line over 20,000 characters (minified code), open as
  plain text, like VS Code's tokenization limit, so typing stays instant.
- **Keys:** ⌘N new file, ⌘P go to file, ⇧⌘P commands, ⇧⌘F search, ⌘S save, ⌘B sidebar,
  ⌘J panel, ⇧⌘M problems, ⌃\` terminal, ⌘W close tab, F12 definition.

## Build

Requirements: Rust (`rustup target add aarch64-apple-ios aarch64-apple-ios-sim`),
Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
./build-ios.sh                 # Rust core -> ios/Generated (xcframework + Swift bindings)
cd ios && xcodegen generate    # -> PadCode.xcodeproj
open PadCode.xcodeproj         # pick your team under Signing, run on the iPad
```
SwiftTerm ships a build plugin. Approve it in Xcode the first time, or pass
`-skipPackagePluginValidation` to `xcodebuild`.

### Free Apple ID: automatic re-signing

A free Apple ID's signing lasts 7 days. `./install-refresh.sh` installs a
LaunchAgent that runs `refresh-ipad.sh` daily at 4:30 and at login. When the
profile has fewer than 4 days left, it gets a fresh one, rebuilds, and reinstalls
over USB or Wi-Fi. Sign-in and recent folders survive. The Mac shows a
notification on success or failure; the log is `~/Library/Logs/padcode-refresh.log`.
For Wi-Fi installs, pair the iPad once over USB and turn on "Connect via network"
in Xcode's Devices window. `./refresh-ipad.sh --force` refreshes now, and
`./install-refresh.sh --remove` stops it. A paid developer account ($99/yr)
lasts a year instead.

### End-to-end test on the iPad

`./run-scenario.sh [all|lsp,split,…]` launches PadCode on the paired iPad (USB or
Wi-Fi) in test mode. It drives the real app against `~/Desktop/padcode-test`
on the connected desktop, prints PASS/FAIL per check, and saves a screenshot per
step to `~/Library/Caches/padcode-scenario`. The steps are in
`ios/Sources/Scenario.swift`.

To test the core against real tunnels from a Mac:
```sh
cargo run -p padcore --example probe -- login
cargo run -p padcore --example probe -- list
cargo run -p padcore --example probe -- <machine> env|ls|walk|shell
cargo test -p padcore && python3 core/helpers/pty_unix.py --selftest
```

## How it works

1. **Sign-in.** GitHub's OAuth device flow, using the same client id and scopes as
   the open-source VS Code CLI. The token is stored in the iPad Keychain.
2. **Discovery.** The dev-tunnels management API lists every tunnel labelled
   `vscode-server-launcher` for that account, one per desktop, along with its
   online status.
3. **Connect.** WebSocket to the tunnel relay → SSH → `direct-tcpip` to the CLI
   control server on port 31545, which speaks msgpack RPC.
4. **Use.** `fs_*` for files, `spawn` for processes and search (`rg`, then `grep`, then
   `findstr`), and `get_env` to detect the OS. `spawn` has no pty, so terminals run
   a small helper sent along with the request (`core/helpers/`). macOS and Linux
   use Python's `pty`; Windows uses PowerShell with ConPTY. Window resizes are
   sent in-band as `ESC ] 7777 ; cols ; rows BEL`. The CLI never kills spawned
   processes, even after the connection drops. So each connection also runs a
   small "lease" process that the iPad pings every 30 seconds. Language servers
   and terminal relays are started next to a watcher that ends them once the
   lease has gone 2 minutes without a ping. (Not done yet on Windows.)

5. **IntelliSense.** Language servers run through the same `spawn`, speaking LSP
   over stdio (`core/src/lsp.rs`). PadCode finds them through the desktop's
   login shell, since the tunnel service runs with a minimal PATH. It uses
   full-text document sync, debounced, so editor edits never need mapping to
   LSP ranges.

Not supported: VS Code extensions themselves (themes and settings are still
read). Running them would need the VS Code Server's extension-host protocol.

## Credits

- VS Code CLI protocol and themes: MIT, © Microsoft (`ios/Resources/LICENSE-vscode.txt`).
- Codicons: CC BY 4.0, © Microsoft (`ios/Resources/LICENSE-codicons`).
- Seti icons: MIT (vscode `extensions/theme-seti`).
- GitHub VS Code Theme: MIT (`ios/Resources/themes/LICENSE-github-theme.txt`).
- Runestone, TreeSitterLanguages: MIT, Simon B. Støvring. SwiftTerm: MIT, Miguel de Icaza.
  Runestone and dev-tunnels are vendored with small fixes (`vendor/*/PADCODE.md`).
- PadCode isn't affiliated with Microsoft or GitHub. It uses VS Code's public CLI
  OAuth client for personal sideloaded use.
