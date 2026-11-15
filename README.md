# claude-toast

Windows toast notifications whenever Claude Code needs you — so you can work on something else
and come back only when needed. Questions and permission prompts can be **answered straight
from the toast**.

```
┌──────────────────────────────────────────────────────┐
│ Windows PowerShell                              ✕    │
│ cache-db-decision                                    │  ← chat name
│ Which database should back the local cache?          │  ← the question (wraps, not cut)
│ Question 1 of 2 - Database                           │  ← position + question header
│                                                      │
│ 1. Postgres                                          │  ← every option on its own line
│ 2. SQLite                                            │
│ 3. Skip                                              │
│ Pick a number - or Terminal to answer there         │
│ ┌─────┐ ┌─────┐ ┌─────┐ ┌──────────┐                 │
│ │  1  │ │  2  │ │  3  │ │ Terminal │                 │  ← click to answer
│ └─────┘ └─────┘ └─────┘ └──────────┘                 │
└──────────────────────────────────────────────────────┘
```

Pure Windows PowerShell 5.1 + the built-in WinRT toast API. No modules, no Node, no app
registration (it uses PowerShell's own AppUserModelID).

## What you get

| When | Hook | Toast | Buttons |
|---|---|---|---|
| Claude asks a question (AskUserQuestion) | `PreToolUse` `AskUserQuestion` | chat name · question · numbered options. Several questions: one toast each, one after another | **1 2 3 …** / checkboxes **☐ 1 ☐ 2 … Done** · **Terminal** |
| Claude needs permission for a tool | `PermissionRequest` | chat name · "Run this command?" + the command (or file, URL…) | **Allow · Deny · Terminal** |
| Claude finished its reply | `Stop` (async) | chat name · "Claude finished - response ready" + the start of the reply. **Once per reply** — no repeated "waiting for input" reminders | **Show terminal · Dismiss** |
| You reply in a chat | `UserPromptSubmit` (async) | that chat's toasts are removed | — |
| Fallback: a permission prompt nobody answered from a toast | `Notification` `permission_prompt` | chat name · Claude's message | **Show terminal · Dismiss** |

* **Toasts stay on screen until you click them** (Windows "reminder" toasts).
* **Not while you're watching:** if Windows Terminal is in front with that chat's tab selected,
  there is no toast and nothing waits — you just answer in the terminal as usual.
  (`interactive.skipWhenWatching`; it matches the tab title Claude Code sets, which contains the
  chat name.)
* Claude Code's "Claude is waiting for your input" reminders (`idle_prompt`) are ignored — you
  get one "Response ready" toast per reply instead.

**Chat name**, first match wins:
1. the `/rename` title — transcript entry `{"type":"custom-title","customTitle":…}` (latest)
2. the auto title — `{"type":"ai-title","aiTitle":…}` (latest)
3. the first prompt you typed, trimmed to ~50 chars
4. the project folder name

**No double toasts:** questions and permission prompts also make Claude Code send a generic
"Claude needs your permission" notification. claude-toast writes `state\<session_id>.question`
while it handles one, and the notification hook stays quiet while that is less than 60 seconds
old (`dedupeSeconds`).

## Answering from a toast

* **Single choice** — click the option's number.
* **Multiple choice** — the buttons are checkboxes: click **☐ 1** to tick it (**☑ 1**), again to
  untick, then **Done**. Windows closes a toast on every button click (asking it to stay open is
  ignored for this kind of button), so the toast pops straight back with the boxes re-drawn and
  "Selected: …". Toasts have no real checkbox control, and their inputs can't reach a script, so
  the buttons themselves are the checkboxes.
  A toast holds at most 5 buttons:
  * 2–3 options: `[☐ 1] [☐ 2] [☐ 3] [Done] [Terminal]`
  * 4 options: `[☐ 1] [☐ 2] [☐ 3] [☐ 4] [Terminal]` until you tick something, then the last
    button becomes **Done**. Clicking the toast text still takes you to the terminal.
* **Click the toast itself** (not a button) — same as **Terminal**: takes you to the chat.
* **Toast hidden?** Windows never pops up toasts on the lock screen (or with Do Not Disturb).
  If the PC was locked while a prompt waited, the toast pops up again when you unlock; and as
  soon as you switch to that chat's terminal tab, the prompt moves to the terminal by itself.
* **Several questions** — one toast per question; the next slides in after you answer. When all
  are answered, Claude Code gets the answers and the terminal question never appears.
  **Terminal** on any of them sends the whole set to the terminal (Claude Code takes the answers
  as one batch).
* **Permissions** — **Allow** or **Deny** (Claude is told you denied it from the notification).
* **Terminal** / **Show terminal** — brings your *existing* terminal to the front: the Windows
  Terminal tab whose title contains the chat name, or else the terminal window Claude runs in.
  It never opens a new window. Multi-select questions with 4 options have no room for this
  button (toasts allow 5) — wait for the timeout or press Esc in Claude Code.
* **Free-text answers ("Other")** can't be typed into a toast — use Terminal.

How it works: the hook shows the toast and **waits** (up to `interactive.timeoutSeconds`, default
5 minutes) for your click. Buttons open a `claude-toast:` link, which Windows hands to
`answer.ps1` (registered per user by `install.ps1`, started through `conhost.exe --headless` so no
window appears). `answer.ps1` records the click, and the waiting hook returns Claude Code's
documented decision:

* questions — `PreToolUse` `permissionDecision: "allow"` + `updatedInput` = the original
  questions + `answers` (`{question text: option label}`, multi-select labels joined with `", "`)
* permissions — `PermissionRequest` `decision: {behavior: "allow" | "deny"}`

While a hook waits, that prompt is **not** shown in the terminal. It appears as soon as you
click **Terminal**, when the wait times out (you then also get a "Permission needed - answer in
the terminal" toast), or if anything goes wrong — the hook returns nothing and Claude Code carries
on normally. Each prompt gets a random 128-bit token; clicks on old toasts or `claude-toast:`
links from anywhere else are ignored.

Why buttons and not a dropdown or text box: Windows only passes dropdown/text input back to a
running app through WinRT events, which Windows PowerShell 5.1 can't subscribe to without a
compiled helper DLL — and Smart App Control (on by default on new Windows 11 PCs) blocks
unsigned DLLs. Buttons work everywhere.

Set `"interactive": { "enabled": false }` in `config.json` for notify-only toasts that never wait.

## Install

Requires Windows 10/11 and Claude Code. From this folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

* merges five hooks into your **global** `~/.claude/settings.json` (or `$env:CLAUDE_CONFIG_DIR`),
  so it works in every project — after backing it up (`settings.json.claude-toast-backup-<timestamp>`);
  your existing settings and hooks are kept as-is
* registers the `claude-toast:` link handler under `HKCU\Software\Classes\claude-toast`
  (current user only, no admin)
* safe to run again — claude-toast's entries are replaced, never duplicated.
  **Re-run it if you move this folder** or change `interactive.timeoutSeconds`
  (the waiting hooks' timeout is set to that + 30 s).

Restart running Claude Code sessions (or open `/hooks`) so they pick the hooks up.

## Test (no Claude needed)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test.ps1
```

It pipes each payload in `test\payloads\` into `notify.ps1` the same way Claude Code does.
Display cases check the hook contract (exit 0, empty stdout, fast) and print each toast.
Interactive cases "click" the toast buttons by opening the same `claude-toast:` links a real
click opens, and check the JSON the hook hands back to Claude Code. Each case uses its own test
config (with `skipWhenWatching` off); your `config.json` is not used.

| Case | Expect |
|---|---|
| `01` single question | notify-only toast; title from a `/rename` title |
| `02` permission duplicate | **no** toast — de-duplicated against 01 |
| `03` multi-select | toast with `(multi-select)`; title from the latest ai-title |
| `04` three questions | all questions and options; `<`, `&`, `"` displayed literally; title from the first prompt |
| `05` permission prompt | toast; no transcript → folder name `my-api` |
| `06` idle reminder | **no** toast ("Response ready" replaces it) |
| `07` malformed JSON | no toast, error logged, still exit 0 |
| `08` answer single | forged link ignored, click **2** → `{"Which database…": "SQLite"}` |
| `09` answer multi | tick 1, tick 3, untick 1, tick 4, **Done** → `"End-to-end, Lint & typecheck"`; buttons `☐ 1…☐ 4, Terminal` → `☑ 1…, Done` |
| `10` answer three | three toasts in a row → three answers; 3-option multi shows `☐ 1 ☐ 2 ☐ 3 Done Terminal` |
| `11` Terminal button | hook returns nothing (terminal question), terminal window brought forward |
| `12` no click | gives up after the (3 s test) timeout, terminal question appears |
| `13` Claude finished | "Response ready" toast with the start of Claude's reply |
| `14` you replied | that chat's toasts are removed |
| `15` / `16` permission | Bash command → **Allow** / **Deny** decision |
| `17` AskUserQuestion permission | left alone (the question hook handles it) |
| `18` screen locked while waiting | toast shown again after unlock, then answered |
| `19` you switch to the chat | question handed to the terminal at once |

Options: `-Only 09` runs one case, `-DelaySeconds 0` skips the pauses between cases.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1          # hooks + link handler
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge   # + logs\ and state\
```

Removes only hooks that run claude-toast's `notify.ps1` (and any matcher group / hook list that
becomes empty because of it) and the `claude-toast:` link handler. Everything else in
`settings.json` is untouched, and a backup is made first. To fully roll back, you can also copy
a `settings.json.claude-toast-backup-*` file over `settings.json`.

## Configuration — `config.json`

```json
{
  "dedupeSeconds": 60,
  "interactive": { "enabled": true, "timeoutSeconds": 300, "skipWhenWatching": true },
  "debug": false,
  "sounds": {
    "question":   "ms-winsoundevent:Notification.Reminder",
    "permission": "ms-winsoundevent:Notification.Default",
    "ready":      "ms-winsoundevent:Notification.IM"
  },
  "ntfy": { "enabled": false, "server": "https://ntfy.sh", "topic": "", "token": "" }
}
```

* **interactive** — answer questions and permissions from the toast; how long to wait for a
  click; skip toasts for the chat you're looking at. Re-run `install.ps1` after changing
  `timeoutSeconds`.
* **sounds** — any `ms-winsoundevent:` value (`Notification.Default`, `.IM`, `.Mail`, `.Reminder`,
  `.SMS`), or `"silent"`. Questions, permissions and "Response ready" each sound different.
* **debug** — `true` logs every toast, click and result to `logs\activity.log`
  (or set the env var `CLAUDE_TOAST_DEBUG=1`).
* **ntfy** — optional phone push via [ntfy](https://ntfy.sh), off by default (notify only —
  answering from the phone is not built yet):
  1. install the ntfy app (Android/iOS) and subscribe to a topic;
  2. set `"enabled": true` and `"topic"` to that name.

  **Topics on ntfy.sh are public** — anyone who knows the name can read them. Use a long random
  name (e.g. `claude-toast-7f3k9q2m`), or your own ntfy server with `"server"` and `"token"`.
  The push has a 3 s timeout, so a dead network can't hang Claude.

## Troubleshooting

**No toasts at all**
* **Focus Assist / Do Not Disturb** hides toasts (they still land in the notification center,
  `Win + N`). Windows 11: *Settings → System → Notifications → Do not disturb* off, or add
  *Windows PowerShell* under *Set priority notifications*. Windows 10: Action Center → Focus assist → Off.
  Also check automatic rules (while gaming, duplicating display, full-screen apps).
* *Settings → System → Notifications*: "Notifications" must be on, and **Windows PowerShell**
  must be allowed in the per-app list (it appears after the first toast).
* You're looking at that chat in Windows Terminal → no toast, by design (`skipWhenWatching`).
* Run `test\test.ps1`. If its cases pass but you see nothing, it's a Windows notification
  setting, not claude-toast.

**Toasts in tests, but not from Claude**
* Restart Claude Code (hooks are read at startup) or check `/hooks` lists the claude-toast hooks.
* Moved the folder? Re-run `install.ps1`.
* Look in `logs\error.log`. Set `"debug": true` and watch `logs\activity.log`.

**Clicking a toast button does nothing / a question toast has no buttons**
* No buttons → the link handler isn't registered (re-run `install.ps1`) or `interactive.enabled`
  is false.
* Buttons do nothing → with `"debug": true`, `logs\activity.log` shows `CLICK` for every click
  that arrived and `STALE` for clicks on toasts that are no longer waiting (answered, timed out).

**The terminal prompt doesn't appear** — the hook is waiting for your toast answer. Click a
button or **Terminal** on the toast (also in `Win + N`), or wait for the timeout.

**A toast shows a generic name instead of the chat title** — the session has no `/rename` title
or AI title yet; the first prompt or folder name is used instead.

**A toast shows up late** — Windows shows popups one after another, and claude-toast's toasts
stay until clicked, so a burst of toasts queues. Everything is also in `Win + N`.

**Two toasts for one prompt** — the generic notification came more than `dedupeSeconds` after
claude-toast's own toast; raise `dedupeSeconds`.

**"running scripts is disabled on this system"** — always launch with
`-ExecutionPolicy Bypass` as shown above (the installed hooks already do).

## Files

```
notify.ps1        the hook handler (-Event question | permission | notification | stop | prompt)
answer.ps1        claude-toast: link handler - records button clicks, focuses the terminal
install.ps1       merge hooks into ~/.claude/settings.json (backup, idempotent) + register links
uninstall.ps1     remove only claude-toast's hooks and link handler
lib/settings.ps1  shared settings.json read/merge/write + link registration helpers
config.json       interactive answering, sounds, de-dup window, debug, ntfy
test/             payloads, sample transcripts, test.ps1
logs/             error.log (+ activity.log when debug is on)        — created at runtime
state/            de-dup markers, pending prompts, clicks, focus info — created at runtime
```
