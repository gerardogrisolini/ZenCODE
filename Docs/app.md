# ZenCODE for macOS

A native SwiftUI app that replicates the terminal chat of `zen` in windows,
with Liquid Glass and the colors of the terminal UI. It runs the same chat
sessions as `zen`: the same models, agents, tools, skills, plans, goals, and
tool consent, read from the same settings. It is a host app of the public Chat
API (see [embedding.md](embedding.md)), kept in this repository as the
standalone SwiftPM package `Sources/ZenApp`.

## Requirements

- macOS 26 and the Swift 6.4 toolchain that the project requires (see the
  [project README](../README.md)).
- ZenCODE configured by `zen`. The app reads the settings, the provider keys,
  and the saved sessions from the support directory that `zen` writes
  (`~/.zencode`, or the directory in `ZENCODE_SUPPORT_DIRECTORY`; see
  [zen.md](zen.md)). It has no setup of its own: run `zen` once in a terminal
  to configure ZenCODE (`zen --ui` runs the setup first when ZenCODE is not
  configured). Without a configuration the window says that ZenCODE is not
  configured and asks you to run `zen` in a terminal, then to start the app
  again.
- The app is not sandboxed. It has the access of the user who starts it, as
  `zen` does, so the workspace access of the Chat API is granted without
  asking.

## Run and build

On macOS, `zen --ui` opens the app on the current folder, which is the
workspace of the first window:

```bash
cd /path/to/your/project
zen --ui
```

The first `zen --ui`, and the first one after each ZenCODE update, builds the
package in release mode from the checkout that `zen` was built from, or from
the installer copy in `~/.zencode/source/`, into `~/.zencode/app/`: the
SwiftPM scratch path `app/build` keeps the next builds incremental, and the
app is installed in `app/current`. The build needs the Swift toolchain and can
take a few minutes, and the first one needs network access to fetch the
package dependencies. Then `zen` starts the app as a separate process and exits:
the terminal returns at once, closing it does not close the app, and each
`zen --ui` starts another instance. The output of the app goes to
`~/.zencode/app/ZenCODE.log`; an app that exits within about 1.5 seconds of
starting is reported in the terminal with the end of that log. When ZenCODE is
not configured, `zen --ui` runs the setup in the terminal first.

`zen --ui` accepts only the options that the app reads, and forwards them to
it: `--agent NAME`, `--model MODEL_ID`, `--skills LIST`, and
`--working-directory PATH` (see [zen.md](zen.md#command-line-options)). For
example, `zen --ui --agent Reviewer --working-directory ~/Projects/site` opens
the first window on `~/Projects/site` with the Reviewer agent. An unknown
agent is reported in the terminal, and the options of the other modes (`-p`,
`-f`, `--jsonl`, `--acp`, and the limits of a turn) are refused. The app reads
the same four options from its own command line and ignores the others, such
as the ones AppKit and Xcode add; a wrong one (an unknown agent, a missing
value) is shown in the window, without the setup hint.

For development, run the package with `swift run`. It is outside the root
package: root commands such as `swift build` and `swift test` do not build it.
Run it from the workspace folder, with the same options after the product
name:

```bash
cd /path/to/your/project
swift run --package-path /path/to/ZenCODE/Sources/ZenApp ZenCODE
```

From a checkout of ZenCODE, `swift run --package-path Sources/ZenApp ZenCODE`
opens the checkout itself as the workspace. A release build:

```bash
swift build -c release --package-path Sources/ZenApp --product ZenCODE
```

The product is the `ZenCODE` executable. There is no `.app` bundle: the app
delegate gives the bare executable a regular activation policy, which is what
gives it a menu bar and a key window. It also sets the ZenCODE icon at launch
(the symbol on a rounded dark tile, drawn from the `icon.svg` in the resource
bundle next to the executable, which is why `zen --ui` installs the resource
bundles with it), so the icon shows in the Dock and in ⌘Tab while the app
runs, while the Finder shows the bare executable with the generic icon.

## Windows and workspaces

Each window is a workspace with its own session, and the title bar shows the
session title and the workspace path. **File > Open Folder…** (⌘O) opens a
window on another folder, or brings forward the window already open on it.
`/exit` closes a window (it is refused while a turn runs, as in the terminal),
closing the last window quits the app, and quitting waits for the sessions to
shut down, for about 5 seconds at most.

## Conversation

The transcript shows what the terminal shows:

- Your prompts, with their attachments, and the slash commands you ran. An
  attached image shows small in the prompt (at most 320 × 200 points) and a
  click opens it in its default application; a video shows as its name and a
  click plays it in Quick Look. The
  prompts a command builds (`/plan`, `/goal`, `/review`, an approved plan, a
  Planner continuation) are hidden, as in the terminal; a reply you type to
  one of them shows as your prompt.
- Assistant text as Markdown: headings, lists, quotes, tables, task lists,
  links, and fenced code with syntax highlighting. Fences marked `diff` or
  `patch` show the added and removed lines in color.
- The model's reasoning, as a `Thinking` block that is open while it streams
  and collapses to a one-line preview when it ends.
- Tool calls, one line each with the tool, its target, and, for the calls
  that ran while the window was watching, the duration, between a disclosure
  chevron at the start, as in the `Thinking` block, and a status glyph at the
  end. Click a line for the details the tool declares (parameters, code, diff,
  list) and the bounded output of the result.
- The file-change summary at the end of a turn, with the patch of each file
  behind a disclosure, its lines numbered like the artifacts' diffs, and the
  `/undo` hint. The file artifacts of the turns show in the artifacts sidebar
  instead.
- The notices of the commands and of the session operations.
- The task-graph card (`🫧 Tasks`), in the conversation like the terminal's
  section: while a turn runs, each change of a significant graph moves the
  turn's card after the latest rows, with the graph as it is now; once the turn
  ends the card stays where it is, and a change outside a turn shows nothing
  until the next turn adds a card of its own. `/tasks` adds a card where it
  runs, significant or not. The cards are never saved, and a new or loaded
  session starts without one.
- The sub-agent card (`👥 Sub-Agents`), after the conversation while
  sub-agents are in progress (queued or running). Click a sub-agent in it to
  open its tab (see [Sub-agent tabs](#sub-agent-tabs)).

The list follows the bottom while a response streams, and its end stays above
the composer and the bars under it. Scroll up to stop following; once more
than a screenful of chat (the height shown between the bars) is left under
the view, a button scrolls back to the latest message. Scroll back to the
bottom to follow it again. An empty session shows the workspace and the model.

The artifacts sidebar, on the right of the window, shows the file artifacts
of the session: the files each turn created, modified, or deleted, the ones
of the sub-agents included, grouped by turn (`Turn N · K files`), oldest
first, one card per file operation with the status icon, the file name and
its folder, the line counts, and the sub-agent that made the change, if any.
A card starts collapsed; its disclosure reveals the explanation and the
diff. As in the terminal, the diff, a captured patch included, numbers its
lines in one column (the old line of a removed line, the new line of the
others) and colors the source of each line in the language of the file,
chosen from its extension (Swift, Python, TypeScript, and the other
languages the terminal colors); text, documentation, and unknown files keep
the diff colors. The sidebar updates
live while a turn runs. The **Artifacts** button at
the end of the toolbar and `/artifacts` show and hide it; it never opens by
itself. Whether it shows is a state of the window: it is not saved, and a new
or loaded session keeps it. Artifacts are runtime-only, so a loaded session
shows none.

### Sub-agent tabs

Click a sub-agent in the `👥 Sub-Agents` card to open a tab with its
transcript, or to select its tab when it is open already. While a sub-agent
tab is open, a tab bar shows under the toolbar: **Chat**, the conversation,
always first and never closed, then one tab per sub-agent you opened, in the
order you opened them, each with the agent's status color, its name, and a
close button. The bar scrolls sideways when the tabs do not fit. Tabs open
only when you click: a sub-agent never opens one by itself, and closing the
selected tab selects the tab after it, else the one before it.

A sub-agent tab is read-only. A card at its top shows the agent: its status,
name, role, profile, task and attempt, model and token counts, the elapsed
time (live while it works, else its duration), and its latest error. Under it
is the agent's conversation, with the rows of the chat: the brief and the
messages it received, as prompts, its reasoning, its text, and its tool calls
with their results. While the agent works, the last row is its reasoning in
progress, else `🤔 thinking…`, so it is never empty; only a running tool
call, which has its own row, replaces it. The tab follows the bottom as the
chat does.

The selected tab updates live, at most twice a second, and at once when the
agent starts, ends, or begins a new run. A tab that is not selected keeps the
agent's card up to date, and reads the conversation only when the agent
starts, ends, or begins a new run; the rest is read as soon as you select the
tab. The tab keeps the conversation it read for as long as it stays open:
ZenCODE keeps nothing once a sub-agent ends, so a finished agent's tab shows
the last conversation it read, the end of the last run included, and a tab
whose agent ZenCODE no longer tracks keeps what it showed last. A tab that
never read a conversation (an agent that ended before you opened its tab)
says that it is not available.

The chat panel (see [Shared chat](#shared-chat)), the composer, and the
status bar are in the Chat tab only, which keeps its scroll position and your
draft while another tab shows. When the session waits for an answer while
another tab shows, the Chat tab shows a dot, and the window never switches to
it by itself: the tool consents, the menus, and the requests for a line of
text are sheets of the window, over any tab. The commands you launch (the
toolbar buttons, the menu items, New and
Save Session, loading or deleting a saved session) select the Chat tab before
they start, so you see their result; **Show Chat Reader** (⌃Y) selects it and
opens the reader. Esc works in the Chat tab only: in a sub-agent tab it does
nothing. ⌘. (**Stop** in the **Session** menu) stops the turn from any tab,
without changing tab. The toolbar and
the artifacts sidebar belong to the window. The tabs are a state of the
window: they are not saved, a new or loaded session closes the sub-agent tabs
and shows the Chat tab, and closing the window stops them.

## Composer

The composer is at the bottom of the window.

- Typing `/` suggests the slash commands you can run, and after a command
  and a space its arguments, as in the terminal.
- Typing `@` at the start of the draft suggests the live mentions of the
  shared chat (`@coordinator`, `@all`, and one `@agent-name` for each active
  agent). A line that starts with a mention is a message to the chat, not a
  prompt: see [Shared chat](#shared-chat).
- ↑ and ↓ walk the prompts you sent in the window. While the chat reader is
  open, ↑ and ↓ scroll its message instead, and ←, →, Home, and End change
  message, even in the composer.
- A prompt sent while a turn runs waits as a `queued` chip above the field,
  which you can remove, and runs when the turn ends. At most 32 prompts wait:
  a full queue refuses the prompt with the terminal's message, keeping your
  draft. A command sent during a turn is never queued: `/help`, `/artifacts`,
  and `/tasks` (alone, or with `status`, `list`, or `ls`) run at once, beside
  the turn, and any other command, `/exit` included, is refused with the
  terminal's message, keeping your draft. A message to the chat is never
  queued either: it is sent at once.
- The paperclip opens the attachment picker (images and movies), and files
  dropped on the composer are attached, one `/attach` each. `/attach list` and
  `/attach delete` work as in the terminal.
- **Stop** (Esc in the Chat tab, ⌘., or the stop button) cancels the turn and
  refuses the open requests. The queue is kept. While a consent sheet shows,
  Esc denies the call instead.

The response language is locked on the first prompt you type in a session, as
in the terminal: the configured language, else the system one. It is decided
again after a new or loaded session and after an agent switch.

## Shared chat

While sub-agents work, the coordinator and the active agents share a live chat
room (see [agents.md](agents.md#messages)), the same one that the terminal
shows in its `Chat` reader. Each window follows the room of its own session:
it shows the room's messages in a panel, sends your messages to it, and runs
the coordinator turns that the messages for the coordinator ask for. The room
is transient, as in the terminal: nothing of it is saved with the session, and
a new or loaded session starts with an empty reader. For a reused session id
the Core keeps the messages it has not delivered yet, and the reader gets them
when it attaches. The window keeps the latest 512 messages.
Telegram is not available in the app, so the relay of the room to a Telegram
chat does not apply.

### Writing to the chat

A line that starts with `@coordinator`, `@all`, or `@agent-name`, followed by
a message, goes to the room as the operator instead of to the model. The
handle of an agent is the readable one that the terminal offers, derived from
its display name. A mention elsewhere in the line is ordinary text.

- The composer completes the leading mention, as the terminal editor does.
  The list shows `@coordinator`, `@all`, and the active agents, read again
  while the draft starts with `@`; ↑ and ↓ move the highlight, Esc hides the
  list until the next edit, and Tab, Return, or a click completes the whole
  word to `@handle` and a space. Accepting a mention only completes it, with
  Return too: a mention needs a message, so a suggestion never sends the
  draft. Only the first word of a single-line draft is completed.
- Return sends the message at once, also while a turn runs. It is never
  queued, and it is not a prompt of the turn.
- A mention without a message is refused with `ZenCODE message: add a message
  after the live mention.`, and the draft stays.
- A mention that the room does not take shows the failure and puts the line
  back in the field, if it is empty by then: `ZenCODE message: selected agent
  is no longer active.` for an agent that left the room, and `ZenCODE
  message:` followed by the reason for any other failure (for example, the
  room is not ready yet).

### Coordinator turns

When a message for the coordinator arrives (from an agent, or yours with
`@coordinator` or `@all`), the Core offers one coordinator turn on it, as it
does in the terminal. The window takes the turn only while it is idle: no line
runs and no prompt waits in the queue. The turn runs as a hidden coordinator
turn. Its prompt, built by the Core, is hidden like the prompts a command
builds, and the turn shows as any other: the response, the tool calls, the
file-change summary, the status bar. Stop and Esc end it like any turn, and a
prompt you send meanwhile waits in the queue. While the window is busy the
messages wait, and the Core offers them again when it is idle; the same
happens when the turn does not start, for example when you stop it first.

### The chat panel

The panel is titled `Chat` and sits in the Chat tab, above the composer. It
has four states:

- Hidden, while the reader is closed and every message is read, as the
  terminal's compact reader disappears once every message is read.
- One row, while the reader is closed and messages are unread:
  `Chat · N messages · U new` and `⌃Y read`. A click on the row, or ⌃Y, opens
  the reader.
- One row, `Chat · 0 messages`, while the reader is open on an empty history,
  with a close button.
- Expanded, while the reader is open on messages. It shows one message at a
  time: the header `Chat · i/N · U new` with the ‹ and › buttons and a close
  button, then `Author: <route>`, for example `Worker [18:05:09] →
  Coordinator`, the label of the terminal reader (the recipient reads
  `Coordinator`, `All`, `Operator`, the name of the agent, or `Agent`), and
  the text. The text is plain, never Markdown, and selectable; it grows to 12
  lines and then scrolls.

Opening the reader selects the first unread message, else the newest, and
reads it. Moving onto an unread message marks it and the messages before it
as read, and moving back never makes one unread again. A message that arrives
while the reader is open leaves the selection where it is and counts as new.
Your own messages stay in the history and never count as new.

While the reader is open in the Chat tab, the keys without modifiers belong to
it, even when the composer has the focus: ← and → show the previous and the
next message, Home and End the first and the last, ↑ and ↓ scroll the text by
a line. They do not move the cursor, recall the history, or move the highlight
of the suggestions. With Shift, Option, Command, or Control a key keeps its
editing meaning, an input method that is composing keeps priority, and Esc is
unchanged. **Show Chat Reader** (**Hide Chat Reader** while the reader is open
in the Chat tab) in the Session menu, and ⌃Y, open and close the reader; ⌃Y
works with the focus in the composer. From a sub-agent tab the item selects the
Chat tab and opens the reader.

## Tool consent, menus, and requests

A tool that needs consent opens a sheet over the window, whichever tab shows,
with the tool, the command or title, the working directory, and the scope of
**Always allow**. The command is in a code box, whole and selectable; past
eight lines it scrolls inside the box. While the sheet shows, the window waits
for your answer: the composer takes your typing again once you answer.
**Allow once** is the default (Return); **Always allow** remembers the choice
(across sessions for `local.exec`, for the session for the other tools);
**Deny** (Esc) refuses the call. ← and → move the focus; Space does not
choose, as in the terminal. Return and clicks are ignored for half a second
after the sheet appears and after any other key it receives, so you pause
before Return answers, and key repeats always are, so a keystroke meant for
the composer cannot approve a call.

The menus of the commands (`/models`, `/think`, `/agents`, `/tools`,
`/skills`, `/sessions`, `/open`, and the others) open as sheets: ↑ and ↓ move
the highlight, typing filters the list, Return confirms, and Esc cancels. In a
menu with checkboxes, Space toggles the highlighted row. A request for a line
of text is a sheet with a text field. `/open` lists the files, URLs, and
attachments of the conversation and opens the one you choose with its default
application.

## Status bar

The line under the composer has the fragments of the terminal status bar, in
its order and separated by ` · `:

- the model and the thinking level, with a spinner while a turn runs;
- the context window, `used/max`, with a small gauge;
- the elapsed time of the turn, live, then the duration of the last response;
- the token counts (`c:` cached, `p:` prompt, `g:` generated);
- the throughput, in `tok/s`;
- the subscription usage (`d:` daily, `w:` weekly), when the provider reports
  it;
- the git changes of the workspace (`N files +A -D`), refreshed after each
  command and after a tool that changed files.

## Sessions

The sidebar lists the current session and the saved sessions of the
workspace, the newest first, with the age, the number of messages, and the
model. Click a saved session to load it, or use its context menu to load or
delete it (a confirmation asks first). While a saved session loads from the
sidebar, a large spinner takes the place of the conversation, centered in
the chat, with the session's name and the step the load is at (reading the
saved session, closing the current session, loading the model and tools,
restoring the conversation), until the restored conversation, or the
failure of the load, appears. **New Session** (⇧⌘N) and **Save**
(⌘S) run `/sessions new` and `/sessions save`, and are refused while a line
runs. They, and loading or deleting a saved session, select the Chat tab
first. The rest of `/sessions` (a named snapshot, `compact`, `restore`) is
typed in the composer.

## Toolbar and menus

The toolbar starts with the agent button, which shows the agent's name, then,
apart, one group: the model and thinking-level buttons, as icons only (the
status bar shows the model and the level), the buttons for the tools, the
skills, and the task graph, and a **Changes** menu (show changes, show changes
with the diff, undo changes, review changes). Always last comes the
**Artifacts** button, which shows and hides the artifacts sidebar.
The **Session** menu has Stop (⌘.), then **Show Chat Reader** (**Hide Chat
Reader**, ⌃Y) in a section of its own, and repeats the agent, model, thinking,
tools, skills, tasks, changes, undo, and help items, in the order of the
toolbar. Each of those items runs
the slash command it names, so everything is also available from the
composer. An item that runs a command selects the Chat tab first, so its
result shows; Stop and the **Artifacts** button leave the tab as it is, and
the chat reader item selects it only to open the reader (see
[Shared chat](#shared-chat)).

## Keyboard shortcuts

| Keys | Where | What it does |
| --- | --- | --- |
| Return | Composer | Sends the prompt, or queues it while a turn runs; a line that starts with a mention goes to the shared chat at once |
| Shift+Return, Option+Return | Composer | Inserts a new line |
| ↑, ↓ | Composer | Recalls the previous or next prompt, from the first or last line of the field, unless the chat reader is open |
| ↑, ↓, Tab | Command and mention suggestions | Moves the highlight, completes the highlighted command or mention |
| Return | Command suggestions | Completes the highlighted command and sends it, unless it takes an argument |
| Return | Mention suggestions | Completes the highlighted mention, never sends |
| Esc | Command and mention suggestions | Hides the list until the next edit |
| ←, →, Home, End | Chat tab, reader open | Shows the previous, next, first, or last chat message, also from the composer |
| ↑, ↓ | Chat tab, reader open | Scrolls the chat message shown, also from the composer, ahead of the history and the suggestions |
| ⌃Y | Menu bar | Shows or hides the chat reader |
| Esc | Chat tab | Denies the tool call while a tool consent waits, otherwise stops the turn |
| Esc | Sub-agent tab | Does nothing |
| ⌘. | Window | Stops the turn, from any tab |
| ←, →, Return, Esc | Consent sheet | Moves the focus, chooses the focused button, denies |
| ↑, ↓, Space, Return, Esc | Menu sheet | Moves, toggles or chooses, confirms, cancels |
| ⌘O | Menu bar | Opens a folder in a window |
| ⇧⌘N | Menu bar | Starts a new session |
| ⌘S | Menu bar | Saves the session |

## Commands

The app runs the shared slash commands of the Chat API, with a `/artifacts`
of its own, and `/exit`:

| Commands | Notes |
| --- | --- |
| `/help` | Lists the commands the window runs |
| `/models`, `/think`, `/agents` | Selection sheets |
| `/tools`, `/skills` | Selection sheets; `/skills` also installs and uninstalls |
| `/sessions` | List, save, new, compact, delete, restore |
| `/attach`, `/open` | Attachment picker and files, default application |
| `/artifacts` | Shows or hides the artifacts sidebar; runs while a turn runs |
| `/changes`, `/undo`, `/review` | Changes (`/changes diff`), undo, review |
| `/tasks`, `/plan`, `/goal` | Task graph, planning, and goals |
| `/exit` | Closes the window; refused while a turn runs |

## Limits

Some features of the terminal chat are not in the app. They stay in the
terminal:

- `/setup`, `/voice` and dictation, `/telegram`, `/feature`, `/cron`, and
  `/ds4` are not offered, and answer as unknown commands. `/tools logs`
  answers that it is not available in the app.
- The full-access toggle (Ctrl+G) does not exist in the app.
- The shared chat is not relayed to Telegram, which the app does not offer.
- There is no `.app` bundle: the app runs as the bare executable that
  `zen --ui` installs in `~/.zencode/app/current`, from `swift run`, or from a
  release build.
- Files are attached while no turn runs: the picker and a drop are refused
  during one.

## Package layout and tests

`Sources/ZenApp` is a standalone SwiftPM package (`ZenApp`, product
`ZenCODE`, plus one library product per library target, for the Xcode
schemes of the previews). It depends on the root package through `path: "../.."`, only on
its public products `ZenCODECore` and `ToolCore`, and on swift-markdown, which
the root graph already resolves. The root graph never depends on it.

| Target | Responsibility |
| --- | --- |
| `ZenAppTheme` | The palette of the terminal UI as SwiftUI colors, in dark and light, and the glass helpers |
| `ZenAppMarkdown` | The Markdown renderer on swift-markdown: blocks, tables, diffs, and the syntax highlighter |
| `ZenAppSession` | The composition and the window model, without SwiftUI: one `ChatSessionHost` over the production runner, one slot per window, the transcript projection, the line routing, the prompt history, the window's tabs with the model of each sub-agent tab, and the window's shared chat (its observation of the room and the reader) |
| `ZenAppTranscript` | The conversation views: prompts, tool calls, thinking, artifacts, summaries, notices, the task-graph and sub-agent cards, and the detail card of a sub-agent tab |
| `ZenAppControls` | The composer (with the completion of slash commands and mentions), the status bar, the consent sheet, and the menu and request sheets |
| `ZenCODEApp` | The app shell: the window group, the menu bar, the sessions sidebar, the artifacts sidebar, the toolbar, the tab bar and the sub-agent tabs, the shared-chat panel, and the launch |

Every target has its tests in `Tests/<Target>Tests` (`ZenCODEAppTests` covers
the pure logic of the shell), and they run on their own:

```bash
swift test --package-path Sources/ZenApp
```

### SwiftUI previews in Xcode

Open `Sources/ZenApp/Package.swift` in Xcode. The `#Preview`s are in the
library targets `ZenAppTranscript` and `ZenAppControls`, and each library
target is also a library product so that Xcode creates a scheme for it.
Select the scheme of the file's target (for example `ZenAppTranscript`)
before you open the canvas: with the `ZenCODE` scheme Xcode tries to run the
previews in the executable and stops with the `ENABLE_DEBUG_DYLIB` error,
because a SwiftPM executable target cannot set that build setting. Keep new
previews in a library target, not in `ZenCODEApp`.

See [embedding.md](embedding.md) for the Chat API the app is built on, and
[architecture.md](architecture.md#target-layout) for its place in the layout.
