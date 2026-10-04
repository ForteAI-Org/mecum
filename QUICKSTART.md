# Quickstart

Build Mecum and inspect a disposable TextEdit document from Terminal. You do not
need a model provider for this first result.

- **Setup:** Xcode 27, Swift 6.4, macOS 26.6 or later, Git and repository access.
- **Steps:** build the CLI, grant capture access, open TextEdit and run `scene`.
- **Success:** Mecum prints the window's interface as text and stores observations.
- **Optional:** try overlays, Xcode, a background Seat or provider chat below.

A Seat moves a window to a virtual display. It requires additional permissions
and validation for your exact macOS build and hardware. Chat uses a Seat and
sends prompts and textual tool results to your chosen provider; use test content.

## 1. Check your tools

```sh
xcodebuild -version
swift --version
sw_vers
```

This walkthrough uses Xcode 27 and Swift 6.4. Xcode requires macOS 26.6 or later;
the package's deployment minimum is macOS 26. See [Apple's requirements](https://developer.apple.com/xcode/system-requirements/).
Open Xcode once to finish installation, then select it under **Settings → Locations
→ Command Line Tools**. For a custom compiler, follow [Swift toolchain selection](https://www.swift.org/install/macos/package_installer/).

## 2. Clone and build Mecum

Run each command after the previous one succeeds. If cloning is denied, check
repository access. Keep subsequent Terminal commands inside `mecum`.

```sh
git clone https://github.com/ForteAI-Org/mecum.git
cd mecum
swift build --product mecum
.build/debug/mecum help
```

The build should complete and `help` should list the commands. Neither needs
macOS control permissions or a provider account.

## 3. Enable macOS permissions

In **System Settings → Privacy & Security**, grant the identity macOS associates
with your launcher **Screen Recording** (also called **Screen & System Audio
Recording**). **Accessibility** adds native control facts and is required for Seat
operation. Fully quit and reopen the launcher after changing access.

Terminal and Xcode may need separate grants. If access is still missing, check
the identity shown by macOS for that launch.

## 4. Inspect a TextEdit document

Open one empty TextEdit document, close other TextEdit documents and dismiss dialogs.
Keep the document open, then run:

```sh
.build/debug/mecum windows com.apple.TextEdit
mkdir -p .scratch/onboarding/knowledge
.build/debug/mecum scene com.apple.TextEdit \
  --knowledge "$PWD/.scratch/onboarding/knowledge"
```

`windows` should list the document. `scene` should print its interface, starting
with `app: TextEdit (com.apple.TextEdit)`, followed by viewport and element data.
Labels and counts vary. Timing diagnostics appear on standard error.

Observations are saved under `.scratch/onboarding/knowledge`, which Git ignores.
This keeps walkthrough data separate from your default Mecum memory.

## Optional checks

```sh
.build/debug/mecum peek --timings --duration 20
.build/debug/mecum memory com.apple.TextEdit --knowledge "$PWD/.scratch/onboarding/knowledge"
```

For `peek`, bring TextEdit to the front; the overlay follows it and closes after
20 seconds. **Ctrl+C** stops it early. Peek does not write memory or call a provider.
The `memory` command reads observations saved by `scene`.

To change Mecum, follow the [contribution workflow](CONTRIBUTING.md) and its
[required checks](CONTRIBUTING.md#run-the-appropriate-checks).

**Xcode:** open `Package.swift`, select the **mecum** scheme and **My Mac**, then add
`help` under **Product → Scheme → Edit Scheme → Run → Arguments** and press **⌘R**.
For overlays, replace it with `peek`, `--duration`, `20`, one argument per row.
Select your intended toolchain and configure permissions for this launch separately.

## Try a background Seat

Keep the physical display awake and run one Seat operation at a time:

```sh
.build/debug/mecum scene com.apple.TextEdit --seat \
  --knowledge "$PWD/.scratch/onboarding/knowledge"
```

After the scene, expect `seat: window returned, display down`. Also check that
the window returns, the virtual display disappears and foreground focus is restored.
Record any change in the window's position or size.

If the Driver reports `unvalidated`, open a [Seat compatibility issue](https://github.com/ForteAI-Org/mecum/issues/new?template=seat_validation.yml).
Build and hardware qualification do not block a run. The Driver keeps the
`unvalidatedBuild` mark and still requires permissions and passing runtime checks.
`--allow-unvalidated-build` remains accepted for existing scripts. One successful
run is not full Driver validation.

## Start a chat

Install and sign in to [Codex CLI](https://developers.openai.com/codex/cli/) or
[Claude Code](https://code.claude.com/docs/en/quickstart); its command must be on `PATH`.
Use `claude` instead of `codex` below to select Claude:

```sh
.build/debug/mecum --chat --provider codex \
  --history-dir "$PWD/.scratch/onboarding/conversations" \
  --knowledge "$PWD/.scratch/onboarding/knowledge"
```

Choose a conversation and model. First ask: “Reply with READY. Do not call any tools.”
Once the Seat check succeeds, ask: “Inspect the open TextEdit document. Do not edit it.”

Use `/status` to inspect, `/release` to return the windows and `/quit` to exit.
These directory overrides do not change the provider's own history storage.
See [CLI chat](Documentation/Engine/Chat.md) for tools, limits and resuming conversations.

## Troubleshooting

- **Build fails:** check the active Swift version and Xcode installation.
- **Missing permissions:** check the launcher identity and restart that launcher.
- **No TextEdit window:** open a document and dismiss dialogs.
- **`noPhysicalDisplays`:** wake the physical display before retrying setup.
- **Provider missing or chat already open:** check `PATH` or exit the other Mecum chat.

For other failures, submit a [bug report](https://github.com/ForteAI-Org/mecum/issues/new?template=bug_report.yml)
with the exact command and test data. Do not include suspected vulnerabilities
in public issues or pull requests.
