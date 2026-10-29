# Computer use

OMPChat does not implement computer use itself. It runs an open-source MCP
server that does the seeing and clicking. 设置 → 电脑控制 adds one of two
vetted servers, each pinned to an exact release, to `AppSettings.mcpServers`
with `risk: .control`. Code: `Packages/OMPKit/Sources/OMPCore/Agent/ComputerUse.swift`
(`ComputerUseCatalog`, `ComputerUseClassifier`, `ComputerUsePermissions`) and
`Packages/OMPKit/Sources/OMPChatUI/ComputerUsePane.swift`.

Reviewed 2026-10-26. The review read source, README, LICENSE, release assets
and issues, and checked signatures with `codesign`/`spctl`. No server was run,
and nothing captured or controlled the screen during the review.

## Decision

| Role | Server | Pin | Licence |
| --- | --- | --- | --- |
| Primary | [opensymph/open-computer-use](https://github.com/opensymph/open-computer-use) | npm `@opensymph/open-computer-use@1.3.0`, tag `v1.3.0` = commit `e551c13e7082ce4c097234137582fbf4a1bc647a` | MIT |
| Fallback | [munimtechnologies/munim-computer-use](https://github.com/munimtechnologies/munim-computer-use) | npm `munim-computer-use@0.7.3`, tag `v0.7.3` = commit `160509b9747db3f90d741eb5367574c942d2351b` | Apache-2.0 |

Catalog configs:

```json
{ "mcpServers": {
  "open-computer-use":  { "command": "npx", "args": ["-y", "@opensymph/open-computer-use@1.3.0", "mcp"] },
  "munim-computer-use": { "command": "npx", "args": ["-y", "munim-computer-use@0.7.3"],
                          "env": { "COMPUTER_USE_BROWSER": "0" } }
} }
```

Candidates were ranked by these criteria, in order: permissive licence;
runnable without compiling; accessibility-first and able to work in the
background; a commit within about six months; no telemetry or unexplained
network access; small enough to skim.

**Why open-computer-use is the primary.**

- It is MIT-licensed and runs through `npx` with no build step.
- The npm tarball contains the native macOS runtime, `Open Computer Use.app`.
  npm's integrity hash therefore covers the native code, and nothing is
  downloaded at run time. The tarball's SHA-256 (`e800b756…dc1c`) matches the
  `opensymph-open-computer-use-1.3.0.tgz` asset of the GitHub release, and its
  SHA-512 matches the npm `dist.integrity`.
- The app is signed with Developer ID (Lewang Information Technology (Fuzhou)
  Co., Ltd., team `DSA846ZFPA`), uses the hardened runtime and is notarized
  (`spctl`: accepted, "Notarized Developer ID").
- It works through the accessibility API first. Clicks go through
  AX / app-posted events / SkyLight background click. Input that moves the
  global pointer or keyboard sits behind an environment flag
  (`OPEN_COMPUTER_USE_MACOS_ALLOW_FOREGROUND_INPUT=1` or
  `…_ALLOW_GLOBAL_POINTER_FALLBACKS=1`), and OMPChat does not set it.
- It always refuses password managers. `launch_app` refuses terminal,
  password-manager and security apps.
- The last commit was 2026-10-17.
- No HTTP client, analytics or updater is in the Swift sources: a grep for
  `URLSession`/`NWConnection`/`http` found only documentation links. The npm
  `postinstall` only prints help text (checked in the 1.3.0 tarball).
- The macOS core is about 18.6k lines of Swift.

**Why munim-computer-use is the fallback, not the primary.**

- It meets the first criteria just as well: Apache-2.0, `npx`, AX-first
  with background input through `CGEvent.postToPid`, last commit 2026-10-20,
  npm provenance attestation, about 9.7k lines of Swift on macOS, and no
  telemetry found.
- Its npm package is only a launcher, though. On first run it downloads
  `munim-computer-use-macos-universal.zip` from the GitHub release `v0.7.3`
  into `~/.cache/munim-computer-use/0.7.3/` and does **not** verify a
  checksum, even though the release publishes `SHA256SUMS.txt`. Today's asset
  matches `SHA256SUMS.txt` (`91c435f8…d978`).
- The binary is Developer ID signed (Sheehan Munim, `6T5J6U2UVT`) but **not
  notarized**: `spctl` rejects it. It still runs, because files written by
  Node's `fetch` carry no quarantine flag.
- It also has a larger surface: Chrome control through an extension and
  native-messaging host, `browser_request_credentials`, and clipboard
  read/write. OMPChat hides the browser tools with `COMPUTER_USE_BROWSER=0`.

## Candidates

| Repository | Licence | Last commit | How it runs | Input path | Network / telemetry | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| [opensymph/open-computer-use](https://github.com/opensymph/open-computer-use) | MIT | 2026-10-17 | `npx @opensymph/open-computer-use@1.3.0 mcp`; signed, notarized app inside the npm tarball | AX first; background `sky_click`/app-posted events; global input gated off | none found | **Primary** |
| [munimtechnologies/munim-computer-use](https://github.com/munimtechnologies/munim-computer-use) | Apache-2.0 | 2026-10-20 | `npx munim-computer-use@0.7.3`; launcher downloads the release binary on first run, unverified | AX first; `postToPid` background input; real pointer only with `COMPUTER_USE_REMOTE_CONTROL=1` | GitHub release download only | **Fallback** |
| [trycua/cua](https://github.com/trycua/cua) (Cua Driver) | MIT (driver; optional perception extension is AGPL-3.0) | 2026-10-26 | installer / Rust build | AX | **PostHog telemetry on by default** (`libs/cua-driver/rust/crates/cua-driver/src/telemetry.rs`, `eu.i.posthog.com`, opt-out via `CUA_DRIVER_RS_TELEMETRY_ENABLED`) | Rejected: telemetry; repo too large to skim (≈670 MB, ~1,300 open issues) |
| [sstraus/McpMacControl](https://github.com/sstraus/McpMacControl) | MIT | 2026-09-26 | prebuilt `MCPMacControl.app.zip` (no npm/uvx), or Go build | `CGEventPost(kCGHIDEventTap)`: takes over the real mouse and keyboard | none found | Rejected: foreground-only input; also ships a `shell` tool (command execution beyond computer use) |
| [joexu22/macos-computer-use-mcp](https://github.com/joexu22/macos-computer-use-mcp) | MIT | 2026-07-20 | Python script plus `mac_input.c` that has to be compiled | `screencapture` + CGEvent: real pointer | optional HTTP server mode | Rejected: compile step, foreground input, no AX tree |
| [d-wwei/macos-desktop-control](https://github.com/d-wwei/macos-desktop-control) | MIT | 2026-04-01 | Node, needs `cliclick` from Homebrew | `cliclick`/`osascript`: real pointer | none found | Rejected: stale (>6 months), foreground input, external dependency |
| [godigi/mac-computer-use-mcp](https://github.com/godigi/mac-computer-use-mcp) | none | 2026-05-27 | Python | — | — | Rejected: no licence |
| [Zooeyii/macos-computer-use-mcp](https://github.com/Zooeyii/macos-computer-use-mcp) | none | 2026-03-31 | TypeScript | — | — | Rejected: no licence; "reimplemented from public runtime analysis" of a proprietary product |
| [virajshoor/opencode-computer-use](https://github.com/virajshoor/opencode-computer-use) | none | 2026-09-07 | Swift, build from source | — | — | Rejected: no licence |

### Tool names of the pinned releases

open-computer-use 1.3.0 (`ToolDefinitions.swift`):

- observe: `list_apps`, `get_app_state`, `list_windows`, `get_window`,
  `get_window_state`, `capture_display`
- act: `click`, `drag`, `perform_secondary_action`, `press_key`, `scroll`,
  `set_value`, `type_text`, `launch_app`, `activate_window`

Common arguments: `app` (name or bundle id), `window` (CGWindowID),
`element_index` (from `get_app_state`), `x`/`y` in screenshot pixels with
`screenshotId`, `text`, `key` (xdotool syntax), and `click_method`
(`auto`/`accessibility`/`app_post`/`sky_click`/`global`; `global` is refused
without the env flag).

munim-computer-use 0.7.3 (`macos/Sources/main.swift`, 32 tools):

- observe: `list_apps`, `get_app_state`, `screenshot`, `list_displays`,
  `zoom`, `clipboard_read`
- act: `click`, `right_click`, `hover`, `drag`, `scroll`, `type_text`,
  `press_key`, `set_value`, `select_text`, `activate_app`, `clipboard_write`
- neither: `wait`
- 14 `browser_*` tools, hidden by `COMPUTER_USE_BROWSER=0`

Both servers mark their observe tools `readOnlyHint: true`. OMPChat ignores
that for computer use: `MCPToolProvider` keeps `.control` for every tool of a
`.control` server. `ComputerUseClassifier` is used only to choose wording
("查看" vs "操作").

## Permissions on macOS

Both servers need **Accessibility** and **Screen Recording**. Who holds those
grants differs:

- **munim-computer-use is a bare executable.** macOS attributes its TCC use to
  the *responsible* app, which is OMPChat. The 电脑控制 pane shows OMPChat's
  own `AXIsProcessTrusted()` and `CGPreflightScreenCaptureAccess()`, and those
  are the grants munim uses. Its own `request-permissions` command, run from a
  terminal, would grant the terminal instead, so the pane does not offer it.
- **open-computer-use relaunches itself.** Its CLI proxies `mcp` to
  `Open Computer Use.app` (bundle id `com.ifuryst.opencomputeruse`), started
  through Launch Services (`NSWorkspace.openApplication`). The grants belong to
  that app. In `mcp` mode it never prompts; the pane shows the pinned command
  `npx -y @opensymph/open-computer-use@1.3.0 doctor`, which opens its
  onboarding window.

**Measured on the installed, sandboxed build (2026-10-27)**, with
`tools/ompshot/scenario_computer_use.py --allow-handshake` (adds the pinned
server, waits for `initialize` + `tools/list`, removes it; no tool is called and
no macOS permission is granted):

1. **open-computer-use cannot start from the sandboxed app.** Its npm launcher
   (a node script) runs, then `spawn`s the native `Open Computer Use.app` and
   gets `Error: spawn EPERM`. The cause is not this package: every file a
   sandboxed process creates carries `com.apple.quarantine`, and a sandboxed
   process cannot `exec` such a file. Checked in the app with a copy of
   `/bin/echo` made by the sandboxed shell: `operation not permitted`, with no
   signature involved. The package is extracted by the app's own `npm`, so its
   native binary is quarantined too. An interpreter can still *read* quarantined
   files, which is why npm and uv servers (scripts) work and a native binary
   does not.
2. **Because it never starts, the other two questions are still open:** whether
   a child of the sandboxed OMPChat could use the AX API on other apps at all
   (children inherit the sandbox), and whether OMPChat's own Screen Recording /
   Accessibility rows match what the server would experience.
3. The upstream issue
   [#5](https://github.com/opensymph/open-computer-use/issues/5) (several app
   copies fighting over one socket) was not reached either.

What would change this, each a decision for the owner of the build:

- **Run the app without the App Sandbox.** Then nothing it or its children
  create is quarantined, children are not sandboxed, and the permissions belong
  to the app itself. It costs the Mac App Store (already given up by the
  `absolute-path` exception) and moves the data out of
  `~/Library/Containers/com.ace.ompchat`; the store folder must be pinned to
  the old location so nothing is lost. The same switch removes every limit that
  comes from the sandbox: crontab, terminal Claude sessions in 「CLI 会话」, and
  scripts the agent writes.
- **Install the package outside the app** (in Terminal, so its files are not
  quarantined) and point a custom server at that copy. It would start, but it
  would still be a child of the sandboxed app, so question 2 above remains.
- **A separate unsandboxed helper** that owns the grants and talks to OMPChat
  over a local socket. The most work, and the only one that keeps the sandbox.

Where this stands in the app: the 电脑控制 pane still lists the two vetted
servers and the permissions, and 添加 works, but the server then shows
「连接失败」. Nothing in the pane claims it runs. What does work from the
sandboxed app is everything script-based: the seven catalog servers install
from nothing and connect (`scenario_mcp_catalog.py`), because the app installs
each package itself and runs it through `node` / `python` instead of `npx` /
`uvx`.

## The chosen path: a Docker sandbox on the VPS (working)

The sandboxed app cannot run the native package (above), so the desktop the
model controls is not this Mac: it is a throwaway Linux desktop in a Docker
container on the netcup VPS, and OMPChat talks to it over an SSH tunnel. The
model can see and click only what is inside the container — nothing on this
Mac — which is a strictly smaller blast radius than either native option.

`tools/computer-use-docker/` holds the image: debian-slim + Xvfb (1280×800),
openbox, two xterms, a GTK app (only GTK/Qt apps register over AT-SPI, which
is what the server drives), dbus + at-spi2-core, and the pinned
`@opensymph/open-computer-use@1.3.0` native Linux binary bridged to TCP by
socat. Resource-capped at 2 cores / 2 GB / 256 MB shm; idles at ~35 MB, and
the container port is published on the host bound to 127.0.0.1 only.

Measured end to end (2026-10-28), Mac → SSH tunnel → container:
`initialize` answers, `tools/list` returns the 14 desktop tools (click, drag,
type_text, press_key, scroll, set_value, list_apps, get_app_state, …),
`list_apps` shows the GTK app, `get_app_state` returns the accessibility
tree with element indexes, and `click` accepts them.

Operation:

    # on the VPS (already deployed to /opt/omp-computer-use, restart unless-stopped)
    docker build -t omp-computer-use:1.3.0 . && docker run -d --name omp-computer-use \
      --restart unless-stopped --memory 2g --cpus 2 --shm-size 256m \
      -p 127.0.0.1:8766:8766 omp-computer-use:1.3.0

    # on the Mac: self-healing tunnel (primary path)
    #
    # tools/computer-use-docker/tunnel.sh re-dials whenever 127.0.0.1:8766
    # stops answering (dead ControlMaster socket after ~30 min idle, Mac
    # waking from sleep, …), by resolving the raw IP for `Host netcup` from
    # ~/.ssh/config itself — dialing the hostname directly gets hijacked by
    # this machine's fake-ip DNS (198.18.x.x). Install once as a LaunchAgent
    # and it keeps the forward up without anyone re-running the ssh command
    # by hand:

    bash tools/computer-use-docker/tunnel.sh install
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ompchat.tunnel.plist
    launchctl enable gui/$(id -u)/com.ompchat.tunnel
    launchctl kickstart -k gui/$(id -u)/com.ompchat.tunnel

    # logs: ~/Library/Logs/ompchat-tunnel.log (rotated at 1 MB, one backup kept)
    # status: launchctl print gui/$(id -u)/com.ompchat.tunnel
    # restart: launchctl kickstart -k gui/$(id -u)/com.ompchat.tunnel
    # uninstall: bash tools/computer-use-docker/tunnel.sh uninstall

    # fallback: one-shot manual tunnel (no auto-recovery; the ssh config's
    # fake-ip DNS breaks direct dials, so the raw IP must be resolved by hand,
    # and the netcup ControlMaster connection may be gone after 30 min idle)
    IP=$(awk '/^Host netcup/{f=1} f&&/HostName/{print $2; exit}' ~/.ssh/config)
    ssh -o ControlMaster=no -f -N -L 127.0.0.1:8766:127.0.0.1:8766 root@$IP

    # probe: python3 tools/computer-use-docker/probe.py 127.0.0.1 8766

Once the LaunchAgent is installed, the 电脑控制 pane's sandbox badge recovers
on its own after a VPS reboot, a dead ControlMaster socket, or the Mac
waking from sleep — no one needs to re-run the tunnel command. If the badge
still shows 未连接, its footnote offers the one-line install command with a
复制命令 button.

Then point OMPChat's MCP client at `http://127.0.0.1:8766` (Streamable HTTP)
or keep using the probe while the stdio dialect is wired up. Gotchas baked
into the image, in case they regress: Xvfb needs a stale `/tmp/.X99-lock`
removed at start; the Linux binary wants newline-delimited JSON (not
Content-Length framing); every X client needs
`DBUS_SESSION_BUS_ADDRESS`/`XDG_RUNTIME_DIR` and the at-spi registry running
before they start; only GTK/Qt apps are visible to the server; and the
container's socat must bind 0.0.0.0 because docker-proxy connects from the
container gateway address.

Still true: every server action goes through OMPChat's approval flow —
电脑控制-class tools are always 逐次询问, and the phone can never auto-allow
them.

## Supply-chain risks

A computer-use server holds the strongest grants a Mac app can have. With
Accessibility and Screen Recording it can:

- read every window, including mail, chats, documents and anything typed;
- click, type and press shortcuts in any app;
- read and write the clipboard (munim).

Because it runs as a child of OMPChat, it also has whatever OMPChat's sandbox
allows. For this build that is read-write access to the whole file system
(`temporary-exception.files.absolute-path.read-write = /`) and the network.

A malicious or compromised release could, without any tool call from the
model:

- record the screen continuously and send it anywhere;
- log keystrokes through the AX tree;
- act in signed-in apps (bank, email, password-protected sessions);
- read and send any file.

OMPChat's approval cards gate the *tool calls the model makes*. They cannot
constrain what the server process does on its own.

That is why pinning matters:

- `npx pkg` / `@latest` would run whatever the maintainer, or anyone who
  steals their npm token, publishes next, with these grants and without any
  review. An exact version runs one immutable npm tarball: npm does not allow
  republishing a version.
- For open-computer-use the native code is inside that tarball, so the pin
  covers everything that runs.
- For munim the pin covers only the launcher. The binary comes from a GitHub
  release asset, and a maintainer can replace an asset under the same tag.
  OMPChat does not verify it, and neither does the launcher. It is the
  fallback for this reason. Before relying on it, compare
  `~/.cache/munim-computer-use/0.7.3/munim-computer-use` with the release's
  `SHA256SUMS.txt` and check `codesign -dvv` (team `6T5J6U2UVT`).
- Transitive npm dependencies: neither pinned package declares any
  (open-computer-use bundles its runtime; munim's launcher uses only Node
  built-ins).
- Developer ID grants survive upgrades of the same signed app. Upgrading
  open-computer-use therefore silently hands the existing grants to the new
  code. Re-vet before changing a pin.

To change a pin: read the diff between the pinned tag and the new tag; repeat
the network/telemetry grep; check the npm tarball against the release
checksums and `codesign`/`spctl`; update `ComputerUseCatalog`, the date and
this document.

## What OMPChat does today

- Every computer-use tool is `ToolRisk.control`. `ApprovalPolicy` asks for
  `.control` in every mode except 只读, where it denies. 始终允许 is not
  recorded for `.control` calls.
- 停止 (`ChatAppModel.stop()`) cancels the reply and the running tool call and
  refuses every approval card still waiting. A step the server has already
  started may still finish.
- Screenshots and accessibility trees that a server returns become tool
  results, which are sent to the user's model provider.
- Catalog entries start disabled. The pane adds and enables one only after
  the user confirms a warning that states the above.
