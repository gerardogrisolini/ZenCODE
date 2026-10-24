# Changelog

All notable changes to ZenCODE are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Release tags follow the strict `vX.Y.Z` contract described in
[Docs/release.md](Docs/release.md) and must match `ZenPackageMetadata.version`.

## [Unreleased]

### Added

- Voice: while voice mode listens, the speech recognized but not yet sent
  appears live at the end of the prompt draft: word by word on macOS, in both
  Send modes, and one speech segment at a time on Linux with the Send mode
  "On a word". Dictation is appended after typed text; when voice sends, the
  whole draft goes out, typed text included, and typing turns the dictation
  into ordinary text. See [Docs/voice.md](Docs/voice.md#the-prompt-draft).

### Changed

- The recommended `Organizer` agent profile has rewritten instructions. On
  request it gives a daily briefing (today's events, overdue reminders and
  reminders due today, a one-line triage of unread mail, and open project
  items) and plans the day or the week. It writes mail and messages in the
  user's voice and sends a draft only after an explicit yes for that draft:
  one approval covers exactly one operation. It asks for a preference only
  once and records it in memory, points out what it notices without acting on
  it, and reports the result of delegated work as unvalidated. The new
  [Docs/organizer.md](Docs/organizer.md) guide describes the profile. Existing
  `agents.json` manifests are not changed; regenerate the recommended profiles
  in setup to apply the new instructions.
- Voice: voice mode now reads every final answer aloud in full, however long it
  is. The answer length limit in `/setup` > Voice mode is removed, and so is the
  `voice.maximumSpokenCharacters` setting that 2.4.0 saved: a saved value is
  ignored and disappears from `settings.json` on the next save. While voice
  mode listens, each prompt also asks the model for short sentences and brief
  comments on what it does as it works. The comments appear in the terminal,
  and only the final answer is read aloud. The instruction is sent with the
  request and is not saved in the session history.

### Fixed

- Voice: on macOS, a short pause while dictating no longer replaces the words
  said before it with the next ones; after a pause the dictation continues on a
  new line and the whole text is sent.
- Telegram voice messages on Linux: when `opusdec` fails on an audio file, for
  example an `.ogg` file that holds Vorbis rather than Opus, `ffmpeg` now
  decodes the same file if it is installed. The error is reported only when
  both decoders fail, and then it names the reason of each one. Without
  `ffmpeg` the `opusdec` error is reported as before.

## [2.4.0] - 2026-10-24

### Added

- Voice: the interactive terminal has a voice mode that works with any agent
  on macOS and Linux. `/voice on` starts it, `/voice off` stops it,
  `/voice pause` stops listening and reading answers aloud, `/voice resume`
  restarts both, and `/voice` alone toggles pause and resume. Voice mode lasts
  only for the current TUI session and survives agent and session switches.
  Each utterance becomes an ordinary prompt after a pause, and every final
  answer, including results of delegated agents, is read aloud without
  Markdown and with code blocks replaced by a short notice; an answer longer
  than about 600 characters is read from its final sentences after a short
  notice, since the end usually holds the questions on how to continue; Esc
  stops the reading. The language follows the response language, then the
  system language. Dictated prompts are saved with the session like typed
  ones; audio is never written to disk.
  - macOS uses Apple speech recognition (on-device when the language supports
    it) and the best installed system voice, after the system permission
    prompts. Capture and playback share one audio engine with system echo
    cancellation, so the microphone stays open and speaking while the
    assistant talks interrupts it. When the current audio output cannot run
    echo cancellation, voice mode starts without it and names the output,
    suggesting a local output or headphones. The `/setup` > Voice mode
    section, which downloads nothing on macOS, chooses the voice that reads
    answers among the system voices installed for the voice mode language
    (name and quality shown; Siri voices are not available to other apps), or
    keeps "Automatic". Choosing a voice, or "Automatic" while an installed
    voice reads the language, opens a submenu: "▶ Listen" reads a short
    sample that says the voice's name (Italian or English) through the system
    output while the menu stays usable, a new sample or leaving the submenu
    stops the one playing, "Use this voice" applies the choice and "Back"
    returns to the list unchanged; the sample uses no microphone and is never
    saved. The choice is saved as `voice.macOSVoiceIdentifier` in
    `settings.json` and survives re-running Telegram setup; a voice that is no
    longer installed, or that reads another language, falls back to the
    automatic voice.
  - Linux runs the sherpa-onnx programs: Parakeet TDT 0.6B v3 speech
    recognition (25 European languages, recognized automatically) and a Piper
    voice, which reads answers in its own language. The microphone is
    off while an answer is read and turns back on when the reading ends or
    Esc stops it. The files (about 580 MB) are downloaded from the new
    `/setup` > Voice mode section, where you choose the voice from those
    available for your language; every file is checked against a pinned
    SHA-256 checksum and stored in `~/.zencode/voice`. Unpacking needs `tar`
    and `bzip2`; playback and capture use ALSA (`libasound.so.2`). The section
    also removes the files. Data management backups skip this directory.
  - Live chat by voice: while voice mode listens, a new live-chat message
    from the coordinator or an agent addressed to you (`→ Operator` or
    `→ All`) is announced aloud, one at a time ("New message from Reviewer,
    2 more waiting. Do you want me to read it?"). Yes reads the whole message
    as plain text, however long, then asks "Do you want to reply?"; a second
    yes is followed by "Tell me your reply." and the next utterance goes to
    the sender with a spoken "Sent.". No moves on to the next message, any
    other utterance closes the question and is handled as usual, and an
    unanswered question lapses after 60 seconds. One phrase sends a live
    message at any time: "message to the coordinator: stop", "message to
    all, take a break", "message to Reviewer: check the diff"; without a text
    voice mode asks "Tell me the message.". The yes/no words and the
    "message to …" phrases are recognised in English, Italian, Spanish,
    French, German and Portuguese whatever the voice language; announcements
    and questions follow the voice language. Announcements wait for an answer
    being read, while an answer that completes during the dialogue is read
    first: a "Do you want me to read it?" question is then asked again, a
    reading or an unanswered "Do you want to reply?" is dropped, and a reply
    or message already asked for is still awaited. Messages replayed after
    `/resume` or a reconnection are never announced. Reading a message aloud
    marks it as read in the dock; a declined or lapsed question leaves it
    unread. Typed input is never intercepted. `Esc`, `/voice pause`,
    `/voice off`, `/new` and `/resume` drop the pending question and the
    queue.
  - Voice mode options: the first items of `/setup` > Voice mode, on
    macOS and Linux alike, choose the send mode and the spoken answer limit.
    The send mode is "After a pause" (default), which goes on to the pause
    that ends an utterance and sends it (2, 3, 5, 8 or 10 seconds; default 5,
    raised from 2.5), or "On a word": you type one word of your own (no
    default, e.g. "vai" or "done"), and an utterance is then sent only when it
    ends with that word, which is removed from the prompt; silence never
    sends, so no pause is asked, a long pause mid-sentence no longer sends
    half a prompt, and everything said before the word is sent together. The
    word alone sends what was dictated so far, the same word mid-sentence is
    ordinary text, a spoken yes/no word is refused as the keyword, and a bare
    yes or no still answers a live-chat question at once without the word.
    The pause and the spoken answer limit (the length past which an answer is
    read from its final sentences only: 300, 600, 1000 or 2000 characters, or
    the whole answer; default 600) are preset lists with the current value
    preselected and the default marked; Back keeps the current value and the
    Voice mode menu comes back. The
    choices are saved with the other settings as `voice.sendMode`,
    `voice.sendKeyword`, `voice.utteranceSilenceSeconds` and
    `voice.maximumSpokenCharacters` (`0` for the whole answer) in
    `settings.json`, survive re-running Telegram setup and apply the next
    time `/voice on` starts; a value that differs from the default is shown
    next to the Voice mode status in the setup menu.
- Telegram: voice notes are transcribed on Linux as well. Telegram setup now
  turns voice-message transcription on with Telegram on every platform, and the
  setup summary shows it. Linux transcribes on the machine with the files of
  `/setup` > Voice mode (any voice) and Parakeet, which recognizes the spoken
  language by itself; the note is first decoded with `opusdec` (package
  `opus-tools`) or, when it is missing, `ffmpeg` into a private temporary WAV
  file that is deleted afterwards. A missing decoder or missing Voice mode
  files are reported in the terminal and in the chat. On Linux settings saved
  before this version, open the Telegram section of `/setup` again (the
  pairing can be kept) to turn transcription on.
- Docs: the new [voice guide](Docs/voice.md) covers voice mode and Telegram
  voice messages on macOS and Linux; the README, the ZenCODE guide, Why
  ZenCODE and the docs index link to it.

### Changed

- Voice: Telegram voice-message transcription and voice mode use the response
  language, else the system language. Telegram setup no longer saves a fixed
  Italian `voice.language`, which overrode the response language; an existing
  value is ignored and removed from `settings.json` on the next save.

### Fixed

- Jira: `jira.search` now finds issues. Free-text queries went to Jira's
  issue-picker suggestions, which only cover issues in the account's own
  history, so searches almost always came back empty and JQL was never
  understood. Free text now runs a full-text JQL search (`text ~ "…"`, most
  recently updated first) through `/rest/api/3/search/jql`, and the new `jql`
  argument sends a JQL expression as is; pass either `query` or `jql`, not
  both. Issue keys and URLs still open the issue directly, and `jira.read` with
  free text uses the same search.
- Xcode: file-change evidence for `XcodeUpdate`, `XcodeWrite`, `XcodeRM` and
  `XcodeMV` now finds files whose project-navigator path does not map directly
  onto the disk, such as local packages nested under `Modules/`. The project
  folder is searched once, with a bounded walk that skips hidden directories,
  packages, `DerivedData` and `node_modules`, and the discovered location is
  reused for later edits. The terminal no longer prints a spurious "Diff
  unavailable: … no on-disk change was found" entry next to the real diff.

## [2.3.6] - 2026-10-22

### Changed

- Git: for the tools that take no file pathspec (`git.status`, `git.log`,
  `git.branch`, `git.remote`, `git.lsFiles`, `git.commit`, `git.push`,
  `git.fetch`, `git.pull`, `git.stash`, `git.switch`) the `path` argument now
  selects the repository directory, as the schema documents, instead of being
  ignored; `workingDirectory` wins when both are given. A missing or
  non-directory `workingDirectory`/`path` fails with a clear error naming the
  argument instead of an opaque process error.
- Git: `git.grep` `maxResults` is now a total cap on matching lines enforced by
  the tool (it was git's per-file `-m`, which also requires git ≥ 2.38, so the
  tool failed on older Linux distributions); context lines and group
  separators do not consume the budget (`git grep -z --column`, git ≥ 2.19).
  `git.lsFiles` `maxResults` counts only file lines and keeps the exit code and
  stderr. Truncated output carries an explicit note. Git never prompts for
  credentials on the terminal (`GIT_TERMINAL_PROMPT=0` unless already set).
- Desktop: `read_clipboard` truncates `clipboard_text` to 100 000 characters
  on a character boundary and reports the omitted count in `note`; `count`
  still reports the full length.
- Jira: the local browser setup page requires a one-time form token and a
  loopback `Origin`/`Host`, binds explicitly to `127.0.0.1`, caps request size,
  and sends `no-store`/`no-referrer` headers, so another website open in the
  browser cannot plant foreign Jira credentials. REST calls have 30 s/120 s
  timeouts and clearer errors for 403, 404 (issue not found), 429 (with
  `Retry-After`) and refused redirects.
- Web: `web.fetch` WebKit rendering now validates subframe navigations too and
  installs a content blocker that refuses every resource load to loopback,
  private, link-local and `.local` destinations; it fails closed, falling back
  to the raw fetch of the main document when the blocker cannot be compiled. It
  uses a non-persistent data store and an overall render deadline. Response
  bodies of `web.fetch`/`web.search` are streamed and cut at the byte limit
  instead of fully downloaded, redirect chains are capped at 10 hops, and a
  blocked redirect reports the policy reason instead of a bare 3xx status.
- Xcode: `XcodeUpdate` snippet normalization no longer inserts a leading `.`
  after ordinary closures (`Task { }`, `withAnimation { }`,
  `DispatchQueue.main.async { }`, `lock.withLock { }`), which could write a
  compile error into the file; only SwiftUI container and modifier chains
  (`VStack { }`, `Button(...) { }`, `.onAppear { }`) are still repaired. A
  listed Xcode tool the compatibility table does not know is forwarded to Xcode
  instead of failing with "Xcode MCP is not available"; unknown names report
  "Unknown Xcode tool".

### Fixed

- Browser: a request the policy had allowed but Chrome refused to continue is
  no longer reported as "Browser blocked a network request". The URL policy
  fails closed on zone-scoped or unparseable IPv6 literals (such as
  `[fe80::1%25en0]`) and on every numeric IPv4 spelling (`0x7f.1`,
  `2130706433`, `127.1`), while hostnames made only of hexadecimal letters
  (`adac.de`) are no longer rejected before DNS. Browser tools fail fast when
  the CDP connection drops instead of waiting the full command timeout per
  command; hostile numeric values in CDP payloads can no longer crash the
  feature process; `browser.pages` returns titles with HTML entities decoded;
  `browser.open` closes its half-initialised page when cancelled during setup.
- Web: hosts whose last label is all-hex but not numeric (`abc.de`) are no
  longer rejected as IPv4 literals, while octal/hex/short/decimal IPv4 forms,
  IPv6 zone IDs, 6to4/NAT64 embedded IPv4 and reserved IPv6 ranges are. Body
  text decoding honours the response or `<meta>` charset and no longer fails on
  truncated UTF-8; `maxBytes` truncation is byte-accurate and never splits a
  character. `web.search` no longer double-decodes result URLs, decodes HTML
  entities deterministically, and no longer leaks a URLSession per call.
- Jira: search queries containing `+` and other reserved characters are sent
  correctly; `jira.read` with a text query that matches nothing says so instead
  of asking to run `jira.search` first; `jira.signOut` no longer fails when
  Jira was never configured; issue "Additional fields" render in a stable order
  and integral numbers are no longer shown in exponent notation; the setup
  server start is bounded (5 s) instead of hanging when the listener never
  becomes ready.
- Git: `git.blame` honours `startLine` or `endLine` given alone and rejects
  non-positive line numbers.
- Swift: option-like values for `configuration`, `target`, `product`, `filter`
  and `executable` are rejected with a clear error instead of reaching
  SwiftPM as options; `swift.run` forwards program arguments verbatim; a missing
  or non-directory package directory fails with a clear error; `swift.test` no
  longer counts XCTest assertion failures as build errors, and diagnostics whose
  path contains "error" or "warning" are parsed correctly; `swift.outline`
  reports correct line numbers for CRLF files.
- Xcode: the `XcodeUpdate` indentation retry also works for standard MCP error
  results, keeps closest matches whose code starts with a digit intact, and
  never re-sends an identical edit; the `XcodeUpdate` diff panel shows the
  `oldString`/`newString` change (it was empty); file-change evidence follows
  symlinked source files and is suppressed for failed edits reported through
  `structuredContent.success`; cancelled or rejected operations are no longer
  misreported as "consent denied"; `tab_id`/`tab_identifier` aliases are
  honoured for `BuildProject`, `GetTestList`, `RunAllTests` and the other
  pass-through tools.
- Figma: the Figma Desktop reachability probe closes its connection on every
  outcome and answers "not running" immediately when the port refuses
  connections.
- Desktop: `open` with a relative `file:` URL resolves against the session
  working directory (like plain relative paths) and rejects authority-only file
  URLs; `type_text` no longer silently truncates grapheme clusters longer than
  20 UTF-16 units (complex emoji sequences); fixed a possible crash in window
  listing when two running-application records share a pid and a non-strict
  display sort in `system_info`.
- macOS: `macos.messages` no longer crashes the feature process on a damaged
  or truncated `attributedBody` row, and a Full Disk Access denial is reported
  as such (with the fix hint) instead of "history not found"; its `read`
  description now states the chronological order of the results. The JXA tools
  pass caller data to `osascript` on stdin instead of a command-line argument
  (no longer visible to other local users via `ps`, no `ARG_MAX` failure on
  long bodies). Dates accept ISO 8601 with an offset and no seconds
  (`2026-10-21T15:00+02:00`) and wall-clock times inside a DST gap.
  `macos.calendar` `update_event` applies `all_day` before `end` (a plain end
  date is inclusive, as in `create_event`), `recurrence_end` as a plain date
  includes that day, and recurrence arguments without `recurrence` are rejected
  on update too; `macos.reminders` validates `alarm_minutes` before modifying
  alarms and reports an alert request on a reminder without a due time;
  `macos.mail` `list` and `macos.photos` `list` treat a plain-date `until` as
  inclusive and reject `until <= since`.
- Installing or updating the optional `macOS` feature (setup → Features →
  "Update installed", or `zen --install-features macOS`) no longer fails
  validation with "Feature must declare at least one tool". The feature now
  discovers its tools from the executable at runtime, so the update completes
  and stops being offered again.
- The `macOS` feature's Mail reply no longer goes out with an empty body: the
  reply content is assigned without being read first, the send is refused if
  Mail did not accept the body, and an unsent reply is closed without saving.

## [2.3.5] - 2026-10-21

### Added

- A new recommended `Organizer` agent profile acts as a personal assistant: it
  uses the `macOS` feature tools (calendar, reminders, contacts, mail, messages,
  notes, photos, permissions), tracks project state with `memory`, and
  delegates project work to other profiles through `sub-agents`. It has no
  direct file or shell access and carries no model binding. It is recommended
  only on macOS and is not included in the default profiles on Linux. Existing
  `agents.json` manifests are not changed; regenerate the recommended profiles
  in setup to add it.
- A new recommended `Promoter` agent profile runs one daily step of a
  long-running promotion strategy for the user's project: it researches with
  the `browser-tools` feature, prepares drafts in the Browser without ever
  publishing them, and keeps the project, channels, strategy, and lessons in
  `memory`, asking the user when any of them is missing. It carries no model
  binding.
- Delegated sub-agents can ask the coordinator a question and wait for the
  answer: `agent.message` accepts `awaitReply` (sub-agents only, also in a
  standby turn) and `replyTimeoutSeconds` (default 600, range 1-900), keeping
  the call and the task attempt open until a live reply arrives. `agent.wait`
  now returns early when chat messages are waiting for the caller.
- Browser: new `browser.login` tool opens the Browser profile in a normal,
  visible Chrome window with no remote debugging and no injected scripts, so
  the user can sign in manually to sites that block automated browsers
  (Google, X, ...). A running automated instance is closed first; once the
  user quits the login window, the next Browser tool reuses the saved session.
  While the login window is open, Browser tools report that the profile is
  busy instead of timing out. `browser.login` is refused when
  `ZENCODE_BROWSER_HEADLESS` is set.

### Changed

- The "Use OpenRouter embeddings" choice in the "Memory embeddings" setup
  section now opens a model submenu instead of always configuring
  `qwen/qwen3-embedding-8b`. It lists every embedding model in OpenRouter's
  public catalog (including OpenAI `text-embedding-3-small`,
  `text-embedding-3-large`, and `text-embedding-ada-002`), each with its price
  per million input tokens and input limit, and preselects the current model.
  The catalog is loaded without an API key; when it is unreachable, setup
  shows a built-in list instead. Entries embedded with a different model fall
  back to lexical retrieval after a model change.
- The shared chat is now the standard coordination channel between the
  coordinator and delegated agents. A new Collaboration policy in the
  coordinator prompt asks it to answer sub-agent questions immediately, steer
  work in progress, forward relevant information between parallel agents, and
  query standby agents; sub-agents stop and ask instead of proceeding on
  assumptions, without sending progress reports. `/goal`, `/plan`, and
  `/review` follow the same policy, and prompts no longer discourage
  `agent.message`: only new implementation work after a closed attempt still
  requires `tasks.retry` and a new `agent.create` item with `taskID`.
- Memory retrieval with an embedding endpoint: semantic hits are now gated per
  prompt (a hit must exceed the median cosine of the prompt's similarity
  distribution by 2.5 robust standard deviations, on top of the 0.4 floor, with
  at least 8 vectors), and the lexical and semantic rankings are merged by
  max-normalised score fusion instead of reciprocal-rank fusion. Measured on a
  real 197-entry graph with 14 Italian/English queries: MRR 0.86 → 1.00,
  recall@5 0.65 → 0.74, no query left without a relevant entry in the top-5,
  and an exact keyword hit is no longer displaced by a noisy semantic list.
  Without an endpoint nothing changes.
- The default semantic recall bound (`ZENCODE_MEMORY_RECALL_SEMANTIC_TIMEOUT_MS`)
  is now 6000 ms instead of 1500 ms: measured against OpenRouter, the embedding
  request takes 0.5–2 s at the median with multi-second tails, so the shorter
  bound still dropped a third to a half of the recalls onto the lexical
  fallback. An explicit value keeps overriding it.
- The "Memory embeddings" setup now discloses that, with an embedding endpoint
  configured, the full text of every prompt and of every memory entry written
  or updated is sent to that endpoint.
- Browser: the automated Chrome instance looks more like an ordinary browser.
  Sync is no longer disabled and, on macOS, Chrome uses the real Keychain
  instead of a mock keychain and a basic password store (Linux keeps
  `--password-store=basic`). Cookies saved in the Browser profile with the old
  mock keychain can no longer be decrypted, so existing logins in that profile
  must be done once more.
- Browser: `browser.open` and `browser.goto` no longer inject the console
  capture script into every page. `browser.console` installs it on its first
  call for the current document, so messages logged before that call are not
  recorded.

- DS4 setup now selects one or more GGUF files from the DS4 folder (all regular
  `.gguf` files, with the already configured ones preselected), each becoming a
  model of the DS4 provider with its own launch parameters: backend (chosen with
  a menu), context window, SSD streaming, MTP and power are asked for each
  selected model, defaulting to that model's saved values, and the API model
  id of a GGUF outside the catalog is inferred from its file name. The hardware
  probe, the compatibility advisor and the confirmation prompt were removed, and
  the DS4 model catalog was reduced to what setup still uses. A model's own DS4
  runtime now takes precedence over the provider's, so each DS4 model keeps its
  own GGUF and launch parameters after settings are saved.

### Fixed

- DS4 setup now recognizes the GGUF that `download_model.sh ds41f-q2`
  currently downloads (`DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf`)
  and lists it as `DeepSeek V4.1 Flash Q2` instead of the raw file name. The
  earlier `DeepSeek-V4.1-Flash-Q2.gguf` name is still recognized, and models
  already configured keep their id and title.
- Xcode tools that change files (`XcodeUpdate`, `XcodeWrite`, `XcodeRM`,
  `XcodeMV`) now report their edits. The changes appear as diffs in ACP clients
  and in the terminal, as local file tools already did. Before this fix the
  edit happened but no diff was recorded.
  The `xcode-tools` feature reads the affected files from the local disk before
  and after each call, with no extra Xcode tool calls. It finds them through the
  session's working directory and the Xcode window's project folder. When no
  change is found on disk, the path is still shown, but without a diff.
  Reinstall the `xcode-tools` feature to get the fix.
- Optional feature packages now declare their ZenCODE dependency as
  `.package(name: "ZenCODE", path: …)` after the `// zencode:package-path`
  marker, the form `feature.promote` already wrote. Installing an optional
  feature previously rejected that form, so the bundled `macOS` feature failed
  the catalog parity check and could not be installed; packages scaffolded by
  Builder or installed from a checkout whose directory is not named `ZenCODE`
  also failed to resolve their `ZenCODE` products. Installation still accepts
  the legacy unnamed form and normalizes it.

- Adding or reconfiguring a model of the DS4 provider from "Providers & models"
  no longer crashes setup with `Unable to load /models`: DS4 is not running
  during setup, so `/models` is never requested for it.

## [2.3.4] - 2026-10-20

### Added

- Memory tools: `memory.get` (read-only) returns one journal entry by id,
  archived or not; `memory.restore` (mutating) reactivates an archived entry.
  `memory.read` pages the journal with `offset` and reports `hasMore`; both
  `memory.read` and `memory.search` accept `tags` (all required) and
  `category` filters (`MemoryEntryFilter` on `MemoryService`). `memory.write`
  reports up to three active entries that lexically overlap the new one
  (`similar`, BM25 relative to the entry itself, at 0.5 or above) so the
  model can consolidate with `memory.update` instead of keeping two notes on
  one fact; the write itself is never blocked. Read-only profiles gain
  `memory.get` and never `memory.restore`.
- `memory.write` also reports existing tags related to any tag the new entry
  introduced (`tagHints`, e.g. `linux-validation` → `linux`, `validation`),
  so the tag vocabulary converges instead of growing single-use tags.
- Browser: `browser.act` gains a `scroll` action that moves the page, or the
  scroll container of `ref`, by `direction` (`up`/`down`/`left`/`right`) and
  `amount` (CSS pixels, about one viewport by default). It uses a real
  mouse-wheel event, falls back to a programmatic scroll when the wheel had no
  effect, and reports the new position, `moved`, and `reachedEnd`.
- Browser: `press` accepts modifier combinations such as `Control+A`,
  `Meta+Enter`, `Shift+Tab`, or `Control+Shift+ArrowLeft`; letters and digits
  are accepted only with a Control, Meta, or Alt modifier. macOS editing
  shortcuts (Cmd+A/C/X/V/Z, Cmd+Shift+Z) carry their editor command so they
  take effect.
- Desktop: new `zoom` action for `desktop.run` captures a region (`x`, `y`,
  `width`, `height` in desktop points) at the display's native resolution,
  downscaled only when its long edge exceeds 2000 px, and reports the same
  coordinate mapping as screenshots (for example 0.5 points per pixel on a
  Retina display).

### Changed

- Lexical memory retrieval tokenizes with `MemoryTokenizer`: camel-case
  identifiers yield the whole token and their segments
  (`AgentCoreSessionRunner` → `agent core session runner`), and a light
  English/Italian suffix stemmer unifies inflections (`tests`/`testing`,
  `validated`/`validation`/`validazione`/`validata`, `memory`/`memoria`,
  `stabilize`/`stabilizzati`). Applied at retrieval time to stored text and
  queries alike; nothing is persisted. On the reference journal an inflected
  query such as "flaky test stabilize diagnostics" now ranks the matching
  Italian entry first instead of outside the top five, and the top score
  separates more clearly from the runner-up on most queries.
- `memory.update` always stamps `Updated` with the time of the update, also
  replacing a stale `Updated` line copied over from the previous content; an
  entry's title now skips `Timestamp`/`Updated` lines when there is no
  `Summary`.
- ACP: the thinking-level config option now uses the standard
  `thought_level` category instead of `model`, so clients can tell it apart
  from the model selector. After a model change through
  `_zencode/session/set_model` the agent sends a `config_option_update` with
  the refreshed options, including the thinking levels of the new model.
- Internal source tree of `ZenCODECore` reorganized: the redundant `ZenCODE/`
  level was removed, `ZenCODETUI` became `TUI`, `Shared/` and `Clients/` were
  absorbed into `Models/` and `Support/`, and large flat folders were split
  into subfolders. No public API, module, wire, or persistence change.
- Every `ZenCODECore` source file over 900 lines was deduplicated and split
  into cohesive `Type+Topic.swift` extensions; no source file in the target
  now exceeds 900 lines. Behavior, wire formats, and persisted formats are
  unchanged.
- The same cleanup was applied to `ToolCore`, `FeatureKit`,
  `LocalToolsSupport`, `FeatureMCPBridgeKit`, and the optional feature
  packages under `Sources/Features`: their sources are grouped into
  responsibility-based subfolders, the large files are deduplicated and split,
  and no source file exceeds 800 lines. Public APIs, tool names, schemas,
  `--list-tools` output, and manifests are unchanged.
- Memory graph version 3 stores each entry's `embedding` as a base64 string of
  little-endian IEEE-754 binary32 components instead of a JSON number array.
  The encoding is lossless. Versions 1 and 2 still load unchanged; the file is
  rewritten in v3 only by the first mutation. Earlier builds reject a v3 graph
  with `unsupportedGraphVersion(3)` and leave it byte-identical. On the
  reference graph (239 entries, 4096 dimensions) the file shrinks from about
  21 MB to about 6 MB, and encoding drops from about 280 ms to about 11 ms per
  save.
- Automatic memory recall has a separate semantic bound,
  `ZENCODE_MEMORY_RECALL_SEMANTIC_TIMEOUT_MS` (default 1500 ms, clamped to
  [10, 10000]), used when an embedding endpoint is configured.
  `ZENCODE_MEMORY_RECALL_TIMEOUT_MS` (default 150 ms) remains the local bound;
  if it is set explicitly and the semantic variable is not, it governs both
  paths. Effect: the semantic request is no longer cancelled systematically at
  150 ms, while the BM25 fallback remains the upper limit of the wait.
- `memory.search` honours its `limit` (1–50, default 8): every retrieval stage
  is widened to the requested size and the ranked candidates — direct hits plus
  graph neighbours — are returned up to that limit, instead of the recall
  selector's thresholded subset, which capped results at 8 and dropped matches
  scoring below half of the top hit. Archived entries requested with
  `includeArchived` are ranked with the same BM25 scoring as active ones rather
  than by substring coverage; half of the limit stays reserved for them.
- Memory retrieval scores use a new age policy (`MemoryAgePolicy`): age is
  measured from the last content change (`max(createdAt, updatedAt)`) instead
  of creation, the half-life of facts rises from 30 to 120 days (entities 60 →
  120, custom 45 → 120; preferences 90 and corrections 365 unchanged), and the
  discount never falls below 0.2. The discount is applied to each ranking
  before reciprocal-rank fusion and to graph neighbours after the cascade,
  instead of to the fused scores, which are near-flat and were effectively
  sorted by age. Recall maintenance no longer touches `updatedAt` when it boosts
  a selected entry and no longer decays rejected candidates
  (`decayRejectedBy` defaults to 0). On the reference journal the median age of
  recalled entries moves from 5 to about 26 days and relevant entries older
  than 60 days become retrievable again.
- Automatic memory recall now reports its degradations: pausing a session
  after three consecutive unusable attempts emits one visible warning line,
  and a lexical fallback injected because the semantic request missed its
  bound emits one visible warning per session (every occurrence is logged at
  debug level), on the same channels as the embedding-failure diagnostics.
  The memory-tool prompt explains that a missing `<project-memory>` block
  means either nothing relevant or recall unavailable, and asks the model to
  call `memory.search` before concluding that no prior context exists.
- The recalled `<project-memory>` block now carries each entry's id on its
  first line (`- [id: <UUID>] …`, with the remaining lines indented), so the
  model can update or archive what it was shown without a lookup first, and
  the per-turn budget truncates on entry boundaries instead of line
  boundaries: a multi-line journal entry is never cut between its `Summary`,
  `State` and `Next`, and the notice reports how many entries were omitted.
  Visible memory diagnostics are no longer written to the raw stderr under
  the test harness when nothing captures them.
- Desktop: screenshots are delivered at point scale, so one image pixel is one
  desktop point, and the artifact reports `desktop_bounds` and
  `points_per_pixel` to turn image pixels into click coordinates; a 5K display
  is now captured at 2560x1440 px instead of 5120x2880. Window screenshots
  leave out the shadow by default (`include_shadow: true` keeps it, without an
  exact mapping), and display screenshots capture the bounds of the
  `system_info` display with the same `display_index`. A region or zoom that
  extends beyond the displays is captured as its visible part, which
  `desktop_bounds` reports.
- Desktop: `desktop.run` actions that can run code or end processes now ask
  for operator approval through the same flow as `local.exec` and the
  destructive tools (terminal Run once / Always for this session / Cancel,
  ACP, Telegram, delegated sub-agents, fail-closed when headless, skipped in
  full access): `open` of anything but a plain http/https URL (files, `file:`
  URLs, other schemes, or an app given by path), `launch_app` and
  `activate_app` from an app path, and every `terminate_app`. The prompt shows
  the equivalent command, such as `open /path/run.command` or
  `terminate_app --force --pid 4242 # loginwindow`.
- Desktop: `terminate_app` accepts only an exact, case-insensitive app name or
  bundle id, waits for the app to quit (`timeout`, default 5 s; 0 checks
  once), and reports an error when it is still running, for example while it
  asks to save changes.
- Desktop: `press_key` resolves a single character on the current keyboard
  layout, adding Shift or Option when the layout needs them, instead of the US
  key position; named keys are unchanged.

### Fixed

- Desktop: `type_text` now reaches the Terminal and other apps that read key
  codes. It presses the real keys of the current keyboard layout (with Shift
  or Option when needed, skipping dead keys), turns line breaks into Return
  and tabs into Tab, and falls back to a Unicode event only for characters the
  layout cannot type. Text containing a line break submits the line, so it
  now goes through the same consent gate as `local.exec`: the same command
  analysis, safe-command exemptions, and shared "Always" approvals.
- Browser: `browser.act` fill now works in rich-text editors such as
  social-media composers (Draft.js, Lexical, ProseMirror, Quill). It resolves
  the editable host from a descendant or wrapper node, replaces the existing
  text with trusted typed input (`Input.insertText`, line breaks as
  Shift+Enter) instead of assigning `textContent`, reads the text back, and
  falls back to the editor's `insertText` command. When the editor still does
  not keep the text, the action fails explicitly instead of reporting success.
  Text inputs and textareas are typed as well, with the native value setter
  as fallback; the result reports `fill.method` and `fill.verified`.
- Browser: refs from an `interactiveOnly` snapshot of a large page (for
  example a long feed) no longer fail with "no longer available". Ref
  resolution used a full snapshot truncated to the output budget; it now
  searches the complete accessibility tree.
- Browser: `click` and `double_click` check what receives input at the click
  point. A target covered by an overlay, cookie banner, or modal is centered
  and checked again, then fails with an error naming the covering element
  instead of silently clicking it. `press Enter` and `press Space` now carry
  their text, so Enter submits a form and Space toggles a control.
- `JSONMemoryPersistence` caches the last decoded graph keyed by the file
  identity (device, inode, size, mtime in nanoseconds). `memory.read`,
  `memory.search`, automatic recall, and the lexical fallback no longer decode
  an unchanged graph file again. Automatic recall on workspaces with large
  graphs never completed within its 150 ms deadline, because the JSON decode
  alone took about 175 ms, and the session was auto-suspended; it now completes.
- Desktop: `system_info` reports the physical pixel size of Retina displays
  (4096x2304 instead of 2048x1152 for a 2048x1152-point display).
- Desktop: `scroll` scrolls at `x`/`y` when they are given instead of at the
  current pointer position.
- Desktop: `close_window`, `minimize_window`, and `set_fullscreen` wait for the
  resulting window state and fail when it is not reached; `close_window`
  reports a sheet that asks to save changes.
- Desktop: `activate_app` and `focus_window` fall back to the Accessibility
  frontmost attribute when macOS ignores cooperative activation from a
  background process.
- Desktop: permission errors name the app that launched zen (for example
  Terminal), which is the app macOS asks to authorize, instead of ZenCODE.
- Desktop: `open` treats `file:` URLs as file paths with the same existence
  check, and runs `/usr/bin/open` from `/` so that a URL-looking target can
  never resolve to a file in the workspace.

## [2.3.3] - 2026-10-18

### Changed

- The coordinator now treats configured model bindings as a cost ladder when
  choosing between direct work and delegation: when a compatible profile offers
  a binding cheaper than the main session model that still meets a task's
  complexity, the task is delegated to the cheapest sufficient binding even if
  direct execution would be faster; only complexity-1 work with its context
  already in hand stays direct. Without bindings the previous
  direct-unless-parallelism logic is unchanged. Applies to the task workflow
  policy, the delegation roster, and the `/goal` prompt. See
  `Docs/bindings.md`.
- Live file artifacts in the terminal chat now show only the changed lines
  with three lines of surrounding context, as unified-diff hunks, instead of
  one hunk covering the whole file. `/artifacts` still shows the whole file
  when complete before/after snapshots are available.
- Telegram polling now backs off exponentially with jitter (3 s to 60 s) on
  transient `getUpdates` failures, honours `retry_after` on HTTP 429, and
  retries every 60 s on HTTP 401/403 (invalid token) and 409 (another poller)
  instead of retrying every 3 s forever. The last polling failure is shown in
  the Telegram control state's `lastError` (without the bot token) and cleared
  by the next successful poll.
- The `jira-tools` optional feature now works on Linux. Without a Keychain,
  the API token is stored in a `0600` file under
  `~/.zencode/jira/credentials/`, and the initial configuration is taken from
  `ZENCODE_JIRA_SITE_URL`, `ZENCODE_JIRA_EMAIL` and `ZENCODE_JIRA_API_TOKEN`
  in the environment of `zen` (validated against Jira before being saved;
  a clear error lists any missing variable). macOS keeps the Keychain store
  and the browser setup form. Previously every Jira call failed on Linux
  with "credential storage is only available on macOS".
- The CI and release whitespace gate now runs `git diff --check` against the
  empty tree, so it covers every tracked file instead of the always-clean
  checkout worktree; the pre-existing trailing-whitespace and
  blank-line-at-EOF violations were cleaned up.
- Removed the orphaned `Docs/zenvoice-bridge.md`, left behind by the ZenVOICE
  removal.

### Removed

- The Telegram `/report` command (and its `report`, `log`, `report file`
  aliases) has been removed from the bot menu, `/help` and the command parser.
  It looked up the newest `.log`/`.txt`/`.md`/`.json` file under the support
  and temporary directories, but the outbound artifact policy only accepts
  files in the private staging directory, so it effectively always answered
  "no exportable report or log file was found". `/diff` is unchanged.

### Security

- Every Telegram diagnostic (start-up, command menu, sends, attachments,
  voice downloads, shared-chat relay) now removes the bot token
  (`bot<id>:<secret>`) from error text and bounds it to 512 characters before
  it reaches `lastError`, the terminal or the linked chat. Previously only the
  long-poll error was redacted, and an HTTP error body (for example a proxy
  HTML page echoing the request URL) was shown in full.
- GitTools now validates every model-provided positional argument (remotes,
  branches, refspecs, revisions, stash references, grep patterns): values
  starting with `-` are rejected so they cannot be parsed as git options (for
  example `--force` as a push remote, `--upload-pack=<cmd>` as a fetch remote,
  or `--open-files-in-pager=<cmd>` as a grep pattern), forced `+refspec`
  pushes are refused, `ext::`/`fd::` remote helpers are refused, and `git grep`
  passes the pattern with `-e`. The package is split into the `GitToolsFeature`
  library, the thin `git-tools-feature` executable and a new test target; the
  executable name and `--list-tools` output are unchanged.
- The ChatGPT Subscription OAuth callback server now listens only on loopback
  (`127.0.0.1` and `::1`, port 1455) instead of every interface, and answers
  malformed or mismatched-`state` requests with HTTP 400 while continuing to
  wait for the real callback instead of aborting the sign-in.

### Fixed

- On Linux, leaving raw mode no longer risks keeping SIGINT, SIGTERM and SIGHUP
  swallowed after the TUI exits. libdispatch installs its own handler for a
  signal source asynchronously and never removes it, so restoring the previous
  disposition before cancelling the source could be overwritten by a late
  registration. The sources are now cancelled first and the previous
  dispositions restored once libdispatch has finished with them; this also
  fixes the intermittent `TerminalSignalRestoration` CI failure on Linux.
- On Telegram, plain-word command aliases (`status`, `diff`, `help`,
  `changes`, `undo`, `annulla`, `modifiche`, `stato`) no longer swallow an
  answer the session is explicitly waiting for: while `/plan approve` waits for
  its Goal, a Planner question is open or a `/goal` workflow waits for the
  user, the word is delivered as the answer, and quoting a live-message card
  and replying `diff` answers its sender. Slash forms (`/diff`, `/status`, ...)
  keep their command meaning, matching the TUI where these words are never
  commands.
- Messages produced while handling a Telegram `/plan approve` Goal reply, a
  Planner answer or a `/goal` continuation (for example "no completed plan is
  available to approve" or a task-graph error) are now sent to the Telegram
  chat too, instead of appearing only in the TUI.
- The TUI now reports, once, when Telegram polling hits a persistent failure
  (HTTP 401/403 invalid token or 409 another poller/webhook) and stops
  receiving messages, and reports again when polling recovers. Previously the
  error was visible only through `/telegram status`.
- The Telegram `/help` text no longer mentions the TUI-only `/telegram`
  command.
- Telegram `/help` now lists `/chat` and `/undo` too. The command list is
  derived from the same registry used for the published Telegram command menu,
  so help and menu can no longer drift apart.
- Telegram slash commands that do not exist on Telegram (for example `/tasks`,
  `/models` or a typo) are answered with "unknown command" and the list of
  available commands instead of being sent to the model as a prompt, matching
  the TUI. Remote commands are recognised by their first word, so
  `/status foo` or `/changes diff` answer that the command does not accept
  arguments instead of becoming a prompt.
- While a response is being generated, Telegram now also answers `/help` and
  `/changes` immediately (previously only `/status`, `/chat` and permission
  replies), instead of the busy message.
- Telegram `/help` and the argument request for a bare `/plan` list the `/plan`
  subcommands (`save`, `load`, `list`, `delete`, `status`, `approve`, `clear`).
- `/plan` and `/review` messages that reach Telegram now say the sub-agents
  tool group is enabled "from the ZenCODE TUI with /tools".
- `@botname` suffixes are stripped by one shared normalizer before every
  Telegram command check, so `/plan@` behaves like `/plan` everywhere.
- `/diff` on Telegram no longer fails with "outside the allowed directories"
  when the temporary directory is reached through a symlink (for example a
  `/private/var` `TMPDIR` on macOS or a symlinked home): the staging-directory
  check compares resolved real paths and rejects only symlinks inside the
  staging directory. Exportable files are now restricted to `.diff`, the only
  file Telegram can send, and the staged excerpt is removed by a single owner.
- `/telegram status` reports polling, command-menu and last send errors on
  separate lines, a successful send no longer replaces or clears the other two,
  and `/telegram off` clears them. A rapid `/telegram off` then `/telegram on`
  now waits for the previous long poll to end, so the new poller cannot hit
  HTTP 409 and wait a minute. Poll-status notifications no longer block the
  poll loop.
- The `tasks.update` tool schema no longer declares a root-level `anyOf`, which
  Anthropic-compatible providers reject with HTTP 400 `invalid_request_error`.
  Root-task and `/goal` workflow modes remain validated at execution time.
- Anthropic Subscription requests now announce Claude Code `2.1.302` instead of
  `2.1.201`, so current models such as `claude-opus-5-5` no longer fail with
  HTTP 400 requiring Claude Code `2.1.280` or newer.
- Anthropic Subscription adaptive-thinking requests now send
  `thinking.display: "summarized"`. Current Claude models default to
  `"omitted"`, so the selected thinking level ran but its text arrived empty
  and thinking looked disabled.
- Anthropic Subscription setup offers the `off` thinking level only for models
  whose catalog declares `thinking.types.disabled` support. Models such as
  Claude Opus 5.5 reject `thinking: {type: "disabled"}` with HTTP 400. Re-run the
  model setup to refresh already configured models.
- Setup's agent model bindings table is now drawn inside the "Agent model
  bindings" menu frame instead of being printed before it, so it stays visible
  without scrolling back past the menu's blank screen.
- Live file artifacts no longer show the same file twice after one tool
  completes, as happened for edits to files above 64 KiB. When the workspace
  checkpoint reports a file also covered by the tool's own evidence, only the
  checkpoint is shown, even if their diffs differ; artifact history and undo
  baselines are unchanged.
- Live file artifacts are separated from the completed tool line above them by
  a single blank line instead of two.
- Backup export/import (`SupportDirectoryArchive`) no longer deadlocks on
  archive members larger than the pipe buffer (about 64 KiB) or on long
  listings: tar's stderr is drained independently of stdout, and members are
  streamed straight to disk with an incremental SHA-256 and per-chunk size
  limits instead of being buffered in memory.
- When the terminal chat is killed by SIGINT (Ctrl-C), SIGTERM or SIGHUP while
  raw mode is active, ZenCODE now restores the terminal first (kitty keyboard
  protocol, bracketed paste, scroll region, autowrap, SGR, cursor visibility
  and the original termios) and then terminates with the original signal, so
  the shell no longer inherits a broken terminal. Ctrl-C keeps closing `zen`.
- Anthropic Subscription reloads its credentials at every tool round and, on
  HTTP 401/403, refreshes the access token and retries that round once, so
  agentic turns longer than the token's remaining lifetime no longer fail
  unrecoverably. A second rejection after the refresh is surfaced with a
  sign-in hint.
- `AgentCoreBackend.closeSession` now also drops the session's tool providers,
  as `clearSession` already did, so providers of closed sessions are no longer
  kept in memory and re-applied to rebuilt backends.

## [2.3.2] - 2026-10-16

### Changed

- Prompt/status and docked Chat frames now reach the final terminal column while
  preserving their left and internal padding. Authorization cards retain the same
  aligned edge; panel redraws keep autowrap disabled without widening transcript
  or artifact output.
- Dimmed the startup logo with ANSI SGR 2, preserving its orange color and leaving
  the startup summary text unchanged.
- Dimmed the prompt/status bar frame and their divider with ANSI SGR 2, preserving
  the orange color and leaving text, menus, and Summary headings unchanged.

### Fixed

- Live file artifacts now omit an unavailable-diff fallback when the same tool
  completion recovers a valid textual diff for that file, without hiding genuine
  fallbacks or changing final artifact history and undo baselines.
- Small local edits to large UTF-8 files now retain compact, operation-captured
  diffs with context instead of discarding all evidence above 64 KiB. Retained
  output stays byte-bounded, with explicit fallback for oversized or costly
  diffs and no misleading zero counts when evidence is unavailable. Compact
  patches remain transient; ACP presents them using existing text content.
- File artifacts from shell, Git, and external tools are now reconciled after
  each tool completes, including delegated calls, instead of accumulating at
  turn end. Already displayed file states are not repeated during final
  reconciliation. Assistant messages are held until their next tool boundary
  or turn completion so the final answer follows all artifacts and precedes Summary.
- Prompt turn separators still reserve the terminal's rightmost column, avoiding
  right-edge autowrap in transcript output, including after terminal resizes.

## [2.3.1] - 2026-10-16

### Changed

- Organised command coordination, setup, and Telegram into responsibility-based
  subtrees. Split the largest sub-agent and render-coordinator test suites into
  focused files and shared fixtures, removing repeated setup and projections
  without dropping test cases. Command handling now shares plan preparation and
  status selection; public symbols, prompt text, wire and persisted formats,
  and existing test names remain unchanged.

### Fixed

- Prompt borders now explicitly disable inherited bold, matching the shared-chat
  border weight while preserving their orange color.
- Restored ZenVoice's missing audio and Realtime sources, shared Xcode scheme,
  and entitlements, including the source references required to build the app
  and its offline tests.
- Managed feature processes no longer lose stdout or stderr when a short-lived
  child writes and exits between an empty pipe read and the exit-state check.
- Fixed the voice bridge's two stale authentication-service references that
  prevented the root package from compiling.
- MCP connections now identify the client as `ZenCODE` instead of
  `Feature MCP client`, including Xcode's Agent Activity panel.
- Shared-chat timestamp rendering tests now isolate terminal output, preventing
  test panels containing `draft` and `historical message` from appearing in the
  active terminal while tests run.
- Stabilised cursor-report diagnostics and ChatGPT HTTP fallback tests by
  allowing the asynchronous key handoff and waiting for complete HTTP requests
  and response flushes before the test server closes connections.

## [2.3.0] - 2026-10-14

### Added

- Terminal shared-chat messages now show their local send time as `HH:mm:ss`
  beside the sender in the `Chat` reader, preserving the original timestamp
  across reader refreshes.
- File artifacts now appear automatically in chat when root or delegated tools
  complete, using the same Markdown layout and source formatting as `/artifacts`.
  Turn numbers are reserved at the first live or final artifact and remain stable;
  reverted turns leave gaps in the net-final `/artifacts` history. Final worktree
  reconciliation adds only evidence not already shown in its final state,
  including later shell/Git/MCP edits to a path previously shown live.
- `/artifacts` now shows the complete in-memory file-artifact history for the
  active session, grouped by turn, with shared text/patch evidence and explicit
  binary or uncertain-evidence fallbacks. The history is presentation-only and
  is cleared when a session is created, loaded/restored, or rebuilt by setup.

### Changed

- `/goal` now works until completion or a genuine blocker, using direct execution
  or delegation when useful. Its persistent task DAG, original objective,
  structured pause/resume, and automatic continuation remain intact. Sub-agent
  tools are no longer required to start, resume, or discover `/goal`; delegated
  attempts still require independent validation and retry through a new attempt.
  Tool grants, schema-1 task checkpoints, and v4 saved sessions are unchanged.
- macOS CI, release gates, and standalone feature jobs now use the explicitly
  accepted arm64 `xcode-27` preview runner with Xcode 27 and Swift 6.4. The macOS
  SwiftPM cache is isolated from the previous image; Linux jobs are unchanged.
  Hosted gate success remains required before treating macOS builds as validated.
- Sub-agent thinking now uses the main thinking Markdown formatting, including
  muted accents and structured blocks. Both thinking views omit bold styling;
  normal responses, the stable thinking title, and in-place layout limits remain
  unchanged.
- Raised the Swift tools and installer minimum to 6.4, aligning standalone
  feature packages, generated feature scaffolds, and contributor documentation.
  Linux CI and release jobs now target the published `swift:6.4-noble` image on
  both supported architectures. The Raspberry Pi container recipe explicitly
  installs the 6.4 toolchain series without upgrading existing machines.
  The macOS runner migration remained pending in this release;
  see `Docs/release.md` for the current runner selection and validation limits.
- `/changes diff` and `/changes --diff` now keep the existing `Summary` above
  the same file metadata and numbered, syntax-highlighted diff renderer used by
  `/artifacts`, replacing the legacy patch renderer. `/changes` still selects
  only the latest change set without mutating or renumbering artifact history.
- Removed confirmed unused internal helpers, orphaned test fixtures, redundant
  imports and no-op MCP logging work across the runtime, TUI and optional features,
  preserving public APIs, wire and persisted formats, and transport lifecycle behavior.
- Automatic file artifacts in chat now start with the file metadata, without the
  `Artifacts` banner or `Turn N — M file(s)` heading, including final reconciliation.
  `/artifacts` keeps its banner and turn grouping; diff evidence, source line
  numbers, syntax highlighting and backgrounds remain unchanged.
- Dark-theme diff backgrounds now use muted forest green (`#1E3024`) and
  burgundy (`#372023`); light-theme backgrounds remain unchanged.
- Live file artifacts and `/artifacts` now show one unified `+`/`-` diff instead
  of separate Before/After files. Added and removed rows use full-width green
  and red backgrounds while retaining source-language syntax highlighting;
  wrapped rows, padding and syntax resets preserve the background without
  leaking into following output. Non-color output keeps readable diff markers.
- Terminal prompt history now retains every non-empty submission, including slash
  commands and consecutive repeats, for the entire `zen` process without the
  previous 200-entry limit. It survives `/new`, conversation loading and `/setup`
  in memory only, and starts empty on the next launch.
- Removed unused internal terminal rendering and input helpers left behind by
  the compositor integration, without changing public APIs or terminal behavior.
- `/plan approve` now asks for a descriptive Goal before activating implementation. The reply is consumed as transient control input, propagated to the active and saved plan, and shown by `/plan list` across TUI, Telegram, and ACP flows.
- TUI and ACP clear pending plan-approval state at session restore boundaries and roll back graph changes when approval persistence fails.
- TUI and ACP now share file-change normalization, deduplication, ordering,
  evidence limits, and fallback semantics through a backend-neutral mapper.
  Normal tool blocks remain compact; detailed source evidence is published live
  and remains available on demand through `/artifacts`.
- `/artifacts` now renders file names prominently and formats source evidence in fenced code blocks with syntax highlighting selected from each file extension; unknown extensions remain neutral.
- Existing `Summary`, `/changes` selection semantics, `/undo`, saved snapshots,
  checkpoints, transcripts, and ACP wire formats remain unchanged.

### Fixed

- Feature catalog generation now preserves the committed Swift catalog's author
  header, preventing CI `--check` failures caused by the header mismatch.
- `/goal` no longer closes its graph when the last currently defined task finishes.
  Open workflows remain extensible, pausable, and recoverable from checkpoints,
  including after analysis-only work. After verifying the whole objective, the
  root coordinator explicitly finalizes through `tasks.update` with workflow
  state `completed`, the graph ID, and its current revision; unfinished or
  unvalidated tasks prevent closure. Manual/plan auto-completion and previously
  terminal graphs are unchanged. Schema-1 and v4 readers retain legacy support;
  older binaries cannot read the new workflow state in finalized saved snapshots.
- The bundled Xcode feature adoption/build test is now compiled only on macOS,
  avoiding an unsupported `xcode-tools-feature` build during Linux test runs.
- Feature process pipe draining no longer drops final stdout/stderr bytes when
  a child writes and exits just after an empty non-blocking read.
- Swift Testing runners that explicitly select `--testing-library swift-testing`
  now use the test support-directory sandbox even without an `.xctest` path.
  Existing harness signals, explicit override precedence, and the production
  default `~/.zencode` remain unchanged.

- The `Authorization` card now fills the same safe width as the prompt box below,
  aligning their right borders even for short commands. Both leave the final
  terminal column unused, while long commands and narrow-terminal content keep
  their existing width-aware wrapping.
- Parallel test runs now isolate ACP checkpoint storage and plan-language settings,
  prepare the memory fallback before measuring its deadline, and keep blocking
  terminal fixtures off the cooperative executor. CPR fixtures count delivered
  bytes and await input release; legacy-memory compatibility tests no longer
  starve unrelated callbacks. Runtime behavior and production timeouts are unchanged.
- Newly recorded delegated file artifacts now clear a still-owned live Sub-Agents
  overview before inserting permanent output, so the completed tool row replaces
  its pending presentation. Root artifacts and history rendering are unchanged;
  lost ownership or unsafe geometry retains the append-only fallback.
- File-artifact metadata now colors `+n` counts green and `-n` counts red in both
  complete and streamed terminal rendering, without recoloring ordinary prose
  or changing plain Markdown and wire formats.
- Artifact diff source-line numbers and wrapped continuation gutters now use
  neutral gray, preserving source syntax colors, diff backgrounds and numbering.
- Terminal authorization now uses a dedicated single-key dialog presentation
  instead of the menu renderer, preserving the original Authorization card
  without a second border. Dialogs share the primary-screen stack and lifecycle,
  use the full available width, and retain trailing consent actions on short
  terminals without covering prompt/status; menu and text-input framing and
  run-once/always/cancel behavior are unchanged.
- Live file artifacts and `/artifacts` again show a single source-line-number
  column: removals use the old position, additions and context use the new one.
  Hunk offsets are preserved, metadata and wrapped continuations stay unnumbered,
  and plain output retains the same numbers and `+`/`-` markers.
- Recalling prompt history keeps completion menus from intercepting ↑/↓ or Enter:
  arrows traverse prior inputs and return to the empty draft, and Enter submits
  the recalled line unchanged. Editing the recalled text restores normal
  completion and multiline editing behavior.
- Active terminal chat reserves a dedicated menu area above prompt/status;
  normal output continues through native terminal scrolling instead of painting
  over hidden transcript rows. The inactive prompt retains its editor draft.
- Resize now requests a cursor-position report before moving the parked chrome
  cursor. `TerminalRawInput` demultiplexes fragmented CPR replies and preserves
  ordinary keys and bracketed paste; output and presentation snapshots wait for
  the report. Transcript/history are never reconstructed with ED2 or replay.
- Failed, cancelled, stale or timed-out cursor reports cancel open menus and
  prompts without applying selections or accepting defaults. The session stays
  append-only, with no fixed footer and a visible editable draft projection;
  anonymous CPR retries are fenced. Standalone menus retain their existing
  alternate-screen presentation outside an active chat.
- Live tool/overview ownership receipts are captured inside their output
  transaction, so an intervening diagnostic cannot be erased as an owned tail.
  Streaming tracks unfinished text, split graphemes and escape sequences without
  waiting for a complete line.
- CPR queries no longer split a buffered paste delimiter; timeout grace applies
  only to an already-started report prefix, not newly pressed Escape keys.
  Append-only fallback uses the current clamped terminal bottom rather than stale
  geometry, and stop/restart drains resize-queued output once even before query
  debounce completes. Focused regressions cover all four cases; the raw-VT dock
  fixture now expects CRLF row allocation rather than normalized LF text.
- The opt-in CPR harness opens and verifies its foreground controlling tty via
  `/dev/tty`, without relying on SwiftPM stdin forwarding. It requires a unique
  claimed UUID temporary root and isolated support directory; repaired behavior
  still awaits independent automated and real-terminal validation.
- Added isolated CPR/input/ownership regressions and an opt-in Swift harness for
  a fresh real Terminal window (`Docs/terminal-cpr-validation.md`). Its terminal
  reflow, short-window and Unicode behavior still requires independent build,
  test and real-terminal validation; these entries do not claim that validation
  has passed or that existing native scrollback chrome copies are removed.


## [2.2.0] - 2026-10-11

### Added

- Optional folder-only DS4 setup now discovers existing local GGUF artifacts,
  reports evidence-backed hardware/model compatibility, and stages a loopback
  OpenAI-compatible provider without downloading, building, starting DS4, or
  persisting process state. The new [DS4 setup guide](Docs/ds4.md) documents
  supported discovery, staged setup, managed-runtime, and internal endpoint
  integration levels.

### Changed

- DS4 setup now exposes and persists the managed `--ctx`, `--ssd-streaming`,
  `--mtp`, and `--power` runtime options, reusing existing values on
  reconfiguration and applying them to the supervised server argv.

- DS4 startup now probes the explicit loopback convention `127.0.0.1:8000`
  (or the configured provider port) and adopts a ready `/v1/models` endpoint
  only when the requested model alias is advertised. Adopted endpoints are
  explicitly external and are never terminated by ZenCODE; when no compatible
  listener exists, the supervisor launches its managed child with the existing
  dynamic-port fallback. Backend reset and full shutdown continue to stop only
  managed children, while logical session close leaves the runtime alive.

- ACP tool-completion updates now publish every recorded changed file in standard
  `locations`, alongside the complete per-file diff content, so clients can render
  multi-file operations as separate artifacts instead of retaining only the
  command or workspace target.

- Delegated agents created with the coordinator's same resolved profile now inherit
  the coordinator session's effective tool allowlist, preserving session-local tool
  additions and removals. Reviewer, Planner, Minimal, and other different-profile
  boundaries remain profile-scoped; only child-intrinsic skills, collaboration,
  and applicable task-reporting tools are added, and `agent.create` payloads cannot
  override the grant.

- Terminal chat no longer renders `agent.message` executions as tool blocks or
  sub-agent activity rows; the tool still executes normally and its shared-chat
  message remains visible.

### Fixed

- ACP delegated task presentations now persist across prompt lifecycles, delivering
  terminal updates after teardown without replaying already presented attempts on
  later text-only prompts.

- Linux builds now normalize POSIX `SOCK_STREAM` values for DS4 loopback
  reservations and test fixtures.

- macOS DS4 hardware probing now treats `system_profiler` as the primary GPU
  source and uses Metal enumeration only as a fallback, avoiding duplicate GPU
  entries when both sources report the same device.

## [2.1.8] - 2026-09-21

### Added

- `/attach` without arguments now opens a terminal-native picker at the user's home directory for navigating
  directories and selecting a supported image or video. Esc/Q cancellation leaves
  pending attachments unchanged; path-based `/attach`, list, and delete forms are
  unchanged, and non-interactive input still receives usage without blocking. Inaccessible
  protected directories are reported as such instead of being shown as empty, and
  symlinked directories remain navigable.

- The live terminal prompt now recognizes conservative press-and-hold
  key-repeat patterns for supported Latin letters and offers an inline numbered,
  arrow-navigable accent picker across terminal applications. The deterministic
  fallback preserves ordinary editing/paste semantics and does not modify
  operating-system keyboard preferences.

### Changed

- Prompt-skill guidance now conditionally permits documented script execution
  through `local.exec` only when that tool is available and the command is
  authorized by the local-execution permission policy. If unavailable or
  unauthorized, guidance requires reporting a blocker instead of inspecting a
  script or inventing a path. `skills.read` is explicitly a non-executor with
  no arbitrary filesystem access; it exposes a normalized absolute installed
  skill directory when available, marks it authoritative over stale example
  paths, and preserves relative-resource sandboxing, metadata-only
  `skills.list`, and pagination.

### Fixed

- Automatic terminal task-graph and sub-agent overview refreshes no longer append
  after a completed streamed model response or clarification question. Runtime
  state, linked Telegram mirroring, late delegated-agent completions, and
  operator-requested task/sub-agent inspection remain current; the next submitted
  turn re-enables live terminal overview updates.

- Live terminal prompt repainting now runs asynchronously with one serialized,
  coalesced pending snapshot. Slow transcript/status-bar output no longer delays
  key acquisition or distorts the conservative press-and-hold repeat timing;
  explicit refresh, submit/dismiss ordering, and stop revision fences remain
  intact.
- File-change previews now align with their tool headings without extra left
  padding, including multi-edit diffs and new-file writes in coordinator and
  sub-agent output. Their code background stops at the content boundary instead
  of spilling into the right terminal padding. Source indentation, line-number
  gutters, syntax highlighting and safe terminal wrapping are preserved.

## [2.1.7] - 2026-09-17

### Added

- Standard ACP task-plan snapshots, separate delegated execution rows, taskless
  runtime snapshot observation, and a capability-gated goal/review/plan catalog.
- Per-operation local text diff evidence for write, edit, replace, multi-edit,
  append, patch, delete and move, propagated without changing provider or persisted
  DTOs. Binary/opaque/uncertain changes keep explicit text fallback; background
  exec conservatively disables reliable-diff presentation for the process lifetime.
- Focused ACP projection/permission and operation-file-evidence test cases.
  Wire conformity does not establish Xcode rendering compatibility.
- Offline ACP bridge/pipeline coverage for delegated DAG invalidations, validation
  and retry, two taskless prompt cycles, close/cancel delivery fences and late consent.

### Fixed

- Submitted-prompt turn separators now span the full available terminal width.
- ACP clients advertising filesystem capabilities now service the existing text
  read/write/edit tools through standard `fs/read_text_file` and
  `fs/write_text_file` requests, preserving editor buffers and avoiding silent
  disk fallback on client errors. Verified client text comparisons use standard
  ACP diff content; missing preimages or uncertain results keep text fallback.
- ACP delegated permission routing uses the root session while consent keys remain
  isolated; unoffered allow options and cancelled/teardown-racing decisions fail
  closed. Ordinary tool completions retain their previous output-only content;
  summaries and diff/fallback blocks are added only with operation evidence.
- Accepted buffered ACP updates drain before close replies, while replacement
  session/prompt fences reject stale delivery. Persistent taskless agents are
  observed again on text-only follow-up prompts with distinct runtime-turn IDs.
- Diff capture accepts regular files only, bounds each text to 64 KiB and each
  operation to 256 KiB (separate snapshot-read and emitted old/new budgets), and
  falls back to explanatory text rather than truncating or reading special files.

### Changed

- Simplified ACP MCP string-map parsing and tool-completion content assembly without
  changing accepted input forms, emitted payloads, ordering, or metadata.
- Subscription setup and reconfiguration discover models through authenticated
  ChatGPT Codex and Anthropic Models endpoints, retaining the last successful
  account/login-scoped catalog on transient failures. Saved model IDs, metadata,
  and default selections are preserved; discovery never switches runtime models
  or falls back to a public/static catalog.
- Discovered context/output limits and explicit Anthropic thinking modes reach
  generation without requiring new model IDs in bundled lists. Unknown or absent
  capabilities remain disabled. Static subscription catalogs and all model-ID-based
  model defaults, limits and capability fallbacks are removed; older manifests use
  configured metadata and generic fallbacks rather than their previous bundled-model
  behavior. A missing configured model is an explicit configuration error. Auth and
  the persisted Codex credentials contract remain unchanged, now owned by Auth.
  The linked Anthropic API-key path uses configured thinking authorization and a
  generic manual fallback rather than ID heuristics, retaining its 64000-token
  generic output default.
  ChatGPT reasoning preserves `none`/`off` and `minimal` through persisted manifests
  and wire payloads. Malformed Anthropic pagination never replaces the last complete
  cached catalog.
- Catalog cache files use private permissions and contain no tokens or token hashes.
  Anthropic OAuth credentials gain an optional opaque catalog login identifier;
  existing credentials remain compatible but require a future new sign-in before
  persistent Anthropic catalog caching is available (refresh alone does not migrate
  the identifier). No sign-in or live Anthropic validation was performed for this
  change: OAuth acceptance by its Models endpoint remains unverified. See
  [subscription catalogs](Docs/subscription-catalogs.md).

## [2.1.6] - 2026-09-14

### Changed

- Setup no longer offers global model or thinking selection, including quick setup
  and its summary. Use `/models` and `/think` to update those persisted selections;
  per-model configuration and agent profile model bindings remain available in setup.
- Consolidate common ACP tool-update fields, inline shared-chat result delivery,
  and existing feature JSON and subscription numeric parsing helpers. Model-name
  formatting shared by setup and the terminal UI now lives in a neutral presentation
  helper; public APIs, ACP payloads, displayed text, and persisted formats are unchanged.
- Documentation reorganized: memory ownership and persistence rules moved from
  `Docs/architecture.md` to the new `Docs/memory.md`, referenced from the contract;
  `Docs/README.md` is now the single documentation index and the project README links
  to it; the validation gate is defined once in `CONTRIBUTING.md` and referenced from
  the README and `Docs/release.md`; `/think` and `/attach` are documented in the
  command references; the unimplemented Core AI backend evaluation document was removed.

### Fixed

- Direct DeepSeek setup keeps dynamic `/models` discovery while assigning documented
  `off/low/high/max` thinking options and the `high` default to Flash, V4 Pro, and
  accepted legacy Flash IDs, without renaming saved models. When editing existing
  metadata, the support confirmation keeps its saved default (No without metadata);
  only an explicit Yes proposes these levels and `high` when saved options are absent.
  Existing explicit options and defaults remain authoritative. OpenRouter enrichment
  no longer replaces direct DeepSeek thinking capabilities. Chat Completions now
  sends distinct DeepSeek `reasoning_effort` levels alongside `thinking.type`,
  retains manifest authorization, and preserves legacy toggle-only selections
  without interpreting `xhigh` as `max` or migrating settings and agent profiles.

- `/goal` now persists its original objective and structured workflow control
  (`running`, `awaiting_user`, `blocked`) separately from tasks in optional schema-1
  checkpoint metadata. Clarification no longer requires a particular heading on
  new workflows, and genuine blockers stop automatic continuation instead of
  repeating retries. TUI, Telegram, and ACP user replies resume the same graph
  with its original goal; checkpoints retain workflows paused before task creation.
  Legacy checkpoints remain readable with an explicit unavailable-goal fallback.
  Root-only workflow updates and revision-fenced resume/rollback preserve task
  progress, required sub-agent delegation, and coordinator validation.
- Workflow recovery now preserves persisted objectives and structured pauses even
  when generation fails before the first task. ACP `session/cancel` keeps the next
  reply on the same workflow without accepting stale prompt completions; loading
  a saved TUI session reconstructs (or clears) its workflow continuation from the
  adopted graph. `/tasks clear` remains the explicit cancellation path.

- Remote generation retries a malformed tool-argument batch once per turn before
  committing history or executing any tool, including Anthropic Messages and ChatGPT
  Subscription. Earlier tool rounds are not replayed. Content and thinking retain
  their existing streaming behavior; matching retry prefixes are suppressed
  independently across chunk boundaries, while divergent text already displayed
  remains visible. ChatGPT Subscription discards the malformed response's transport
  and continuation before rebuilding from validated history, including when the
  retry budget is exhausted. Cancellation and session replacement prevent stale
  retries and history commits.

## [2.1.5] - 2026-09-10

### Added

- ACP chat now shows the current agent, model and thinking selection once before
  the first model-generating prompt, using `agent_message_chunk` in standard and
  app mode. Immediate local commands do not consume this summary; configuration
  changes preserve it and restored session incarnations show it again. The summary
  is presentation-only, never model input, reasoning or persisted history. Missing
  thinking selections are reported as default/unsupported rather than disabled.

### Fixed

- Live ChatGPT Subscription thinking sent through ACP now removes asterisks and
  separates bold summary titles with one internal newline, including split streaming
  delimiters. Only whitespace separators are deferred until actual following content;
  title text still streams immediately. Existing CR/LF, repeated whitespace and empty
  or incomplete markers cannot leave a trailing blank line. Tool, answer and turn-exit
  boundaries finish without output and reset separators, so the next thinking card
  starts without leading whitespace, including after repeated flushes. Ambiguous bold
  text followed by prose on the same line stays inline.
  Other providers, final answers and internal/persisted text are unchanged.
  History replay stays verbatim because snapshots lack per-message provider provenance.
  The user confirmed correctly separated thinking lines in Xcode with the previous
  presentation patch but reported a terminal blank line; this deferred-separator
  refinement has not yet been tested in the host.

- Claude Subscription setup now offers a new login when token refresh explicitly
  fails with OAuth `invalid_grant`. Network, server, malformed token responses,
  authorization-code exchange failures and cancellation remain visible instead
  of being treated as disconnected credentials.

- ChatGPT subscription requests now explicitly request detailed public reasoning
  summaries for ACP thinking streams: `auto` can produce reasoning without a public
  summary. This requests provider-supplied summaries, not raw chain-of-thought.

- ACP thinking streams now contain only model reasoning: model-loaded notices,
  runtime status and diagnostics (including retries) are no longer emitted as
  `agent_thought_chunk` in either standard or app mode. Genuine thought deltas
  and model-generated assistant responses remain unchanged; model metadata is
  also available through ACP configuration.

## [2.1.4] - 2026-09-07

### Added
- ZenVoice provider selection adds ChatGPT Subscription alongside the existing API
  mode, with separate cloud consent and backward-compatible settings. A dedicated
  `zen --voice-bridge` owns subscription authentication and SwiftNIO control while
  the independent macOS app owns WebKit/WebRTC media. The bridge never starts tasks,
  refreshes shared tokens or falls back to API keys; delegation reaches only the
  app's allowlisted ACP clients. Subscription permissions require an explicit,
  scrollable menu/modal confirmation bound to the ACP client/request/activation,
  not inferred vocal playback receipts. Offline protocol, migration, lifecycle,
  privacy and failure regressions accompany the integration; interactive audio
  validation remains user-controlled and distinct from successful handshakes.
- Regression coverage for a WebSocket frame coalesced with HTTP 101; the shared
  SwiftNIO upgrader now forwards leftover bytes instead of silently dropping the
  first event. No dependency versions or pins changed.

- Standalone personal macOS status-bar voice assistant in `Apps/ZenVoice`, with
  its own Swift 6 Xcode project, OpenAI Realtime speech-to-speech, Keychain setup,
  explicitly allowed projects and independent local ACP processes. Voice-only
  one-shot permission challenges fail closed; disabling voice preserves running
  tasks and pipes, while quitting closes children. Includes bounded incremental
  ACP transport, playback-correlated permission checks and interruption-safe
  audio scheduling. Unsigned Release build and 16 offline Swift Testing tests
  verified on Xcode 27 / Swift 6.4 / SDK 27; setup/privacy/lifecycle documented.
  Live API/audio, signing and notarization remain untested; no root product changes.

- Conservative automatic project-memory consolidation after eligible root turns:
  one isolated, tool-less request to the current model/backend may propose a
  verified error/correction lesson, explicit project decision, or durable fact.
  Runtime citation/order/privacy/grant checks, atomic current-state deduplication,
  and limits of one mutation per event / three per root session also cover updates
  and manual-write races. Empty output is normal; failed/cancelled turns and task
  completion alone are not evidence. Initial adapters support bounded project-file
  evidence and Swift build/test invocation outcomes; causal relevance and semantic
  deduplication remain model judgments with documented limits. Temporary requests
  do not inherit recall, history, tools, user cache keys, or persisted session state.
  Existing memory tools and JSON formats are unchanged; no `MEMORY.md` is restored.

### Removed

- Removed all legacy `MEMORY.md` handling, including parsing, import, migration,
  templates and file-specific API constants/errors. Memory opens only the JSON
  graph, or an empty graph when absent; existing Markdown files are ignored and
  left untouched, including malformed files. Already persisted JSON entries,
  JSON version compatibility and graph-backed synchronous APIs are preserved.
  Installation no longer treats `MEMORY.md` as a configuration artifact.

### Fixed

- Renamed the DesktopTools executable entry-point file from `main.swift` to
  `DesktopToolsFeatureMain.swift` to avoid Swift's conflict with `@main`, preserving
  the existing `private enum DesktopFeatureMain` and executable behavior.

- Terminal Chat reader updates no longer reset the transcript cursor to the status
  bar, leaving empty space above republished tool and Sub-Agents blocks. Same-height
  unread/selection repaints preserve the cursor; opening, closing and unread-row
  transitions compensate only actual transcript scrolling. Navigation uses the
  same render barrier, retaining resize/capacity checks and append-safe fallback.

- Conversation compaction now aims for at most 50% of the available prompt budget
  (after output, overhead and wire-inflation reservations), with the 95% trigger
  unchanged. This is a target, not a guarantee: indivisible system context and
  tool-safe recent turns retain the existing material-progress fallback.
- Compaction deduplicates safe suffixes and prunes impossible fits using the exact
  additive no-summary lower bound. Impossible targets stop after the preferred
  summary-budget pass instead of scanning up to 24,001 budgets. Feasible suffixes
  still use exhaustive per-character search because rendering is non-monotonic;
  its residual worst-case cost is intentionally retained rather than skipping fits.
- Compacted user/tool history is explicitly marked as untrusted historical data,
  quoted with provenance and escaped against structural marker/markup collisions.
  Tiny summaries omit facts when their trust envelope cannot fit. Legacy summaries
  remain readable and repeated compaction does not nest quote wrappers. Stable
  summary headers, system role, snapshot/cache formats and memory storage are unchanged.

- Desktop window actions now reject conflicting selectors and absent or ambiguous
  public AX/Quartz associations instead of choosing a relative best match or
  reporting an unverified requested window ID. Screenshot regions validate safe
  rounded integer dimensions before capture side effects, and pointer/region
  validation uses actual monitor bounds rather than a desktop bounding box.
- Desktop text input rejects requests exceeding a conservative execution budget
  before posting events, without shortening text, changing intervals, or using the
  clipboard. Application-state probes remain fresh one-shot AppKit snapshots but
  use bounded retry backoff; desktop child processes now share FeatureKit's
  cancellable, deadline-bound runner with concurrently drained, bounded pipes.

- Anthropic Subscription streaming now requires `message_stop` before finalizing
  responses or tool calls. Incomplete streams fail clearly without replaying the
  request or committing an incomplete assistant response.

- Setup yes/no prompts now display their help before selection. The remote reset
  warning accurately distinguishes the saved-session index from per-project
  session files and still defaults to No. Cancelling a multiple-selection setup
  menu now cancels setup instead of silently accepting the preselected defaults.
- Agent model bindings are now optional for delegation as well as direct use.
  Profiles without bindings inherit the main session's selected model and provider;
  the delegation roster, `agent.create` schema, and workflow guidance no longer
  require a dedicated binding. Explicit bindings and profile tool grants remain
  unchanged.

### Changed

- Consolidated remote runtime forwarding, terminal tool/skill selection helpers,
  and feature projections without changing public APIs, selection behavior,
  permissions, persistence, or runtime ownership.
- Telegram internals were conservatively reorganized without changing user
  experience, persistence, Bot API wire contracts, authorization policy, or
  routing/lifecycle ownership. `TerminalTelegramControlService` now retains
  lifecycle and ingress coordination while pairing, wire effects, attachments,
  and the command registry live in dedicated files; the terminal adapter is
  split into eight responsibility-focused extensions alongside its existing
  Overviews companion. Two Markdown fallback tests characterize the existing
  Markdown-to-plain-text retry behavior; they are not a functional bug fix.

### Removed

- Provider-reported and locally estimated prefill/generation token-throughput
  metrics are no longer decoded, propagated, or rendered. Token usage counts,
  cache/context data, response durations, and streaming usage requests remain
  available.

## [2.1.3] - 2026-09-04

### Changed

- `/goal` now derives a concrete objective and testable acceptance criteria from
  the request, workspace, context, and project conventions without requiring a
  routine confirmation step. If a coordinator generation ends while its workflow
  graph is still open, ZenCODE automatically continues on the same graph instead
  of behaving like an ordinary one-turn prompt; it returns control only for
  graph-backed completion, explicit cancellation, failure, or a focused workflow
  clarification.
- The setup menu now groups "Default model & thinking" and "Agents" under
  Required, directly after providers and models. `zen --doctor` now always
  reports a dedicated check for each required setup item, including the
  effective default thinking level.
- Voice transcription is now configured automatically with Telegram: it is
  enabled on macOS using the default Italian language and is unavailable on
  other platforms. The separate "Voice tools" setup section has been removed;
  disabling Telegram also removes its voice configuration.

### Fixed

- Automatic memory recall no longer drops already-available lexical matches when
  the fixed embedding endpoint exceeds the turn deadline. Operator and delegated
  sub-agent turns prepare a maintenance-free BM25 fallback alongside semantic
  retrieval; a fast semantic result still wins, while a timeout injects the
  prepared text into the currently selected chat model/provider without waiting
  for or coupling memory vectors to that model.
- Automatic-recall's timeout fallback now reloads the durable graph before
  ranking, so it cannot inject a memory another ZenCODE process has archived or
  deleted after the local reader opened.
- Memory reads stay fresh across processes: `memory.read` and `memory.search`
  now resolve one coherent snapshot of the durable graph per request (reloading
  what another `zen` process may have committed and overlaying this process's
  pending recall maintenance on the copy only) while remaining pure — the graph
  file, live metadata, lazy migrations and pending maintenance are untouched.
  Session close and backend shutdown now flush every open memory store's
  pending recall maintenance after prompts have quiesced, attempting all stores;
  a memory persistence failure is surfaced only after the existing teardown
  completes, so in-memory maintenance is no longer lost below its checkpoint
  threshold.
- Semantic embedding fallback diagnostics from `memory.search` and memory
  mutations now pass through the TUI render coordinator instead of writing to
  raw `stderr` beside a pending tool. They remain visible after the completion,
  while headless and ACP paths keep the preserved-`stderr` fallback; tool headers
  are no longer duplicated when semantic retrieval degrades to BM25.
- Interactive authorization cards now exclusively own the shared terminal cursor.
  Existing live tool and Sub-Agent rows are retired before the card is drawn;
  concurrent coordinator output is held until the operator answers, then replayed
  in order with the latest Sub-Agents overview reanchored below the intact card.
  Delayed consent no longer leaves duplicate Sub-Agent headers or erases the card
  footer.
- Xcode tool discovery and agent invocations now share the same persistent
  feature runtime in Chat, preventing a second Xcode authorization request
  after tools have already been activated.

## [2.1.2] - 2026-08-31

### Added

- `zen --jsonl -p PROMPT` runs the headless turn with a machine-readable
  newline-delimited JSON stream. Runtime events, the final result, and failures
  are emitted as one JSON object per line on stdout; stderr remains empty in
  JSONL mode. Records carry schema version 1 and a run identifier for clients
  that need to correlate the stream. Textual meta-commands (`--help`,
  `--version`, `--doctor`, and `--install-features`) ignore `--jsonl` and keep
  their existing output and exit behavior.

### Fixed

- Sub-Agent overviews are now retired before ordinary tool output and its Chat
  repaint replay, preventing stale or duplicate overview sections.
- Active tool blocks now preserve their terminal anchor when Chat opens, closes,
  or first appears: the verified old rows are removed before the status-bar
  repaint and the pending tool is republished against the resulting layout.
- Tool argument handling now treats `skills.read`'s optional `resource` argument as absent when empty, and no longer lets empty string/array aliases hide later non-empty aliases in `tasks.get` and `local.readFiles`.
- `/plan save` now preserves the original planning request as the saved Goal
  when a Planner clarification reply (such as an approval to prepare the plan)
  immediately precedes the final plan response.

## [2.1.1] - 2026-08-31

### Changed

- The recommended Developer profile now avoids unsolicited initiative and asks
  the user to choose whenever multiple reasonable implementation options exist.
  The recommended Reviewer profile now explicitly checks for simplification,
  fewer lines of code, and duplicated code.

- The Planner's mandatory brainstorming is now explicitly a multi-turn phase
  that continues until every material implementation decision is clear; the
  Planner must not produce the final plan while unresolved decisions remain.

- The Builder and Planner workflow policies now live in the recommended agents'
  `instructions` persisted by setup in `agents.json`, rather than being appended
  implicitly at runtime. Regenerating the recommended agents installs the full
  policies, while existing custom profile instructions remain authoritative and
  unchanged. The `/plan` coordinator prompt remains smaller but retains
  single-author delegation, same-agent correction, output freshness,
  question/final-plan validation, and structured task bootstrap guarantees.
  Planner identity continues to enforce read-only core grants independently of
  its editable instructions.

- Removed the manual `/sessions checkpoint [label]`, `/sessions tree`, and
  `/sessions branches` commands, plus restore-by-branch-index. Session
  checkpoint trees continue to record ordinary messages automatically; restore
  remains available through its interactive picker and entry IDs.

- `swift.test` now accepts additional SwiftPM argv such as `--no-parallel`,
  passes them directly without shell interpretation, and always reports the
  process exit code plus timeout/truncation state in its bounded summary.

- Telegram routing now uses schema 2 with one global owner in one private chat.
  Personal routes retain private topics, multi-session rooms, lifecycle,
  generation, leases and wire fences, while group/supergroup routing, member
  lists and per-route ACL APIs are removed. Voice notes, attachments, permission
  replies and artifact consent continue through the same fenced owner route.
  Schema-1, ownerless and incoherent configurations are no longer migrated or
  claimed at runtime: they stay inactive until Telegram is paired again.

### Added

- Telegram now exposes `/chat` in its command menu to choose a live-chat
  recipient. It replaces the standalone `@` picker trigger and remains
  available while ZenCODE is generating a response.

- `zen -p PROMPT` (also `--prompt`) runs one headless text-only turn. It accepts
  an inline prompt with optional piped stdin context, prints only the final
  assistant text to stdout, and fails without
  launching interactive setup when configuration, input, or generation is unavailable.

### Fixed

- Selecting Telegram menu commands that require an argument (`/plan` or
  `/goal`) now asks for it with Telegram's reply flow instead of executing an
  incomplete request. Commands without required arguments keep their immediate
  behavior.

- Telegram ingress now rejects new prompts, commands, live-chat mentions,
  attachments and voice notes while that TUI session is generating, instead of
  queueing or starting work in the background. The authorized route receives a
  generation-fenced busy notice; stop-generation, pending authorization replies
  and consent callbacks remain operational, and the gate runs in the serialized
  runtime loop before downloads or transcription.

- Telegram `@coordinator` shared-chat mentions now retain their authorized,
  generation-fenced route through the synthetic coordinator turn, so a response
  shown in the TUI is also delivered back to the originating Telegram chat. The
  surface correlation is registered before publishing wakes the shared-chat
  coordinator, closing an actor-reentrancy race without adding transport data to
  the shared bus or weakening route ACL validation.

- `/telegram on` now restores the persisted, generation-fenced route lease and
  uses it for terminal-originated turns, including a turn already running when
  Telegram is enabled. The multi-session routing migration had left real local
  prompts as `.local`, while every outbound path required `origin.telegramLease`;
  the command therefore reported an active link but silently created no Telegram
  reporter until a fresh authorized Telegram message happened to arrive.

- Telegram ingress no longer dies silently after the first consumer teardown.
  `TerminalTelegramControlService.incomingMessages` stored a single
  `AsyncStream(unfolding:)`, which is one-shot: the first `nil` — a cancelled
  forwarding task, a consumer handoff, or a restarted interactive panel loop —
  terminated that shared stream permanently, so every later consumer completed
  immediately. `/telegram on` still reported success and the bounded mailbox kept
  buffering updates, but no Telegram message was ever delivered again. The façade
  is now vended per access over the same shared, bounded, backpressured mailbox,
  so a new forwarding task always gets a live stream without extra buffering or
  duplicated elements.

## [2.1.0] - 2026-08-29

### Added

- Telegram remote control now has persistent multi-session routing keyed by
  `(chat_id, user_id, topic_id?, room_id)`. Each route carries an owner ACL,
  explicit members, lifecycle and monotonic generation; revocation, close,
  delete, rebind and teardown fence stale queue, delivery-ledger, draft and reply
  operations. Forum topics resolve exactly before an explicit chat fallback,
  persistent replies retain `message_thread_id`, and groups/supergroups remain
  disabled unless both global opt-in and an active ACL route exist. Legacy
  private-chat single-link settings migrate on first authorized use without
  enabling groups. Native ephemeral drafts remain private-chat UX only and are
  never treated as proof of authorization.
- Telegram polling is process-wide per bot: one dispatcher owns `getUpdates`
  and the durable offset, then broadcasts each update to every active session
  before route-local filtering. Runtime prompts carry a generation-fenced route
  lease through queue admission, generation, permission dialogue and egress;
  fallback ACL topics retain the concrete `message_thread_id`, and revocation
  cancels the correlated generation instead of merely suppressing its reply.

- Telegram assistant output now uses Bot API 10.3 Rich Messages through a
  backend-neutral presentation AST. Paragraphs, headings, inline/preformatted
  code, ordered and unordered lists, expandable details, in-message buttons and
  already-uploaded documents have dedicated wire serialization without leaking
  Telegram types into the domain. Rich drafts retain the existing throttling,
  coalescing, cancellation fencing and outbound governor; clients or API servers
  that explicitly reject Rich Messages fall back to a deterministic plain-text
  draft/final response, while ambiguous failures never risk a duplicate final
  send. Invisible control/bidi characters and unsafe button/document references
  are rejected or sanitized before serialization.
- Telegram can send documents as `multipart/form-data` uploads. The encoder
  is bounded: per-file and whole-form byte budgets are enforced before any
  byte reaches the wire, the corpus is streamed from disk in chunks, and a
  file that grows between the size check and the read aborts instead of
  inflating the upload. Uploads share the outbound rate governor and retry
  only on an explicit 429.
- Outbound files are gated by an anti-exfiltration policy and explicit
  consent. `/diff` materializes a bounded diff excerpt (or `/report` the
  latest report/log) into a private staging area; the operator then confirms
  with a Send/Cancel keyboard. The consent grant is single-use, chat- and
  user-scoped, bound to the SHA-256 of the bytes captured when offered, and
  expires, so a stale or replayed confirmation can never upload. Repository
  working directories,
  `.git`, secret files (`.env`, keys, tokens) and unapproved extensions are
  rejected fail-closed wherever they live; nothing is ever uploaded
  automatically.
- Telegram ingress now accepts documents and photos selectively: only
  allowlisted MIME types (text, markdown, csv, json, yaml, pdf, rtf, word,
  odt; jpeg/png/webp/gif images) within the 20 MB download budget are
  admitted, identifiers are bounded and filenames sanitized before any
  network request. Received files land in a `0600` temporary under a `0700`
  directory, are capped per chat and per concurrent download, and are removed
  deterministically on discard, `/telegram off`, and teardown.
- Pressing ESC to stop a running turn now also terminates every active
  `local.exec` background job the turn started, using the same
  process-group TERM-then-KILL escalation as `exec.job` kill and session
  shutdown. Final output of each stopped job remains readable through
  `exec.job` poll, and jobs that already finished are left untouched.
- Telegram now streams visible plain-text assistant output through native
  `sendMessageDraft` previews. Updates are throttled and coalesced behind the
  outbound governor, while the completed answer is persisted exactly once with
  `sendMessage`; unsupported or failed draft calls therefore degrade safely
  without retrying ambiguous outcomes. Internal reasoning, tool names,
  arguments, results, and secrets never enter the draft API.
- Telegram's `stopped_message_generation` update now cancels the actual
  in-flight ZenCODE generation only when its linked chat and non-zero `draft_id`
  still belong to that turn. Late updates from finished or rebound turns are
  fenced out.
- Live task progress uses an owned editable card via `editMessageText`,
  `editMessageReplyMarkup`, and `deleteMessage`. Its receipt ledger is separate
  from shared-chat/reply routing, and finish, failure, cancellation, rebind,
  disable, and teardown retire the card and all pending draft work.
- Telegram remote control now shows a typing presence while a mirrored turn or
  a voice-note transcription is running. The indicator is held by a
  lifecycle-safe lease: renewals are fenced by a generation token, so a
  renewal that wakes after the turn ends, after a replacement, or after
  `/telegram off` exits without touching the wire, and a stopped session never
  keeps "typing".
- Telegram outbound sends are governed against the Bot API rate limits: one
  send per second per chat and a global spacing budget, with cancellable waits
  and an automatic retry only when Telegram answers with an explicit 429
  envelope carrying `retry_after`. Any other failure — including ambiguous
  outcomes such as transport errors — is surfaced to the operator instead of
  being retried into a possible duplicate.
  Reservations are actor-atomic and one logical send performs at most two
  retries; a 429 without a valid `retry_after` is never retried.
- Bot API errors are now decoded into a typed envelope (status, `error_code`,
  `description`, `retry_after`) so callers no longer re-parse response bodies.
- ZenCODE registers its Telegram command menu with `setMyCommands` when the
  link becomes active. The menu is driven by a single command registry that
  also feeds the ingress parser, so a command can never be parseable but
  missing from the menu.
- Telegram pairing now stops polling when its advertised 10-minute grant
  expires and asks the operator to rerun `/setup`. Enabling Telegram also
  rolls the service back unless the paired session has a valid egress route.
- The Telegram menu now discovers `/plan`, `/goal`, and `/review` from the
  coordinator command parser. While a response is running, `/status` remains
  available alongside pending permission replies; all work stays rejected.
- Telegram pairing now issues a single-use, 128-bit deep-link grant: the
  terminal shows a `t.me/<bot>?start=<payload>` link plus a manual fallback
  code. The grant expires in 10 minutes, is stored only as a SHA-256 digest,
  and is consumed atomically, so a replayed or leaked code cannot link a chat.
  A non-private chat is rejected before consumption, so it cannot burn a valid
  grant intended for the private pairing flow.
- Telegram operators can send a standalone `@` to open an inline keyboard of
  active agents. Selecting one opens a forced-reply composition card; its reply
  is delivered only to that selected live agent, rather than being queued as an
  ambiguous ordinary prompt.

### Changed

- The terminal task-graph overview (`/tasks`, live graph updates) now renders
  each task vertically: one header row with the status marker, task ID and
  title, and the complexity/agent/waits metadata on an indented detail row
  directly below it. Long descriptive content such as blocked reasons wraps
  onto hanging-indent continuation lines so multi-line metadata stays
  readable; status symbols, graph identity and summary counts are unchanged.
- The terminal status bar now renders its previously white neutral metadata in
  a readable light gray, while preserving the white input row and semantic
  accent colors.
- The terminal Chat reader notification is now quieter and fully transient:
  the compact header appears only while unread messages remain and disappears
  completely once every message has been read, releasing its reserved row back
  to the transcript until the next unread arrival makes it reappear. Its box
  and header also switched from light blue to a desaturated slate blue so
  transient agent-to-agent traffic stays distinguishable from the orange
  application chrome without competing for attention.

### Fixed

- Ordinary task-graph recovery checkpoints now retain only resumable work and
  are removed once all graphs are terminal or archived, preventing completed
  graph history from accumulating. Explicit `/plan save` library entries remain
  durable, including completed saved plans.
- Foreground tool and feature processes now retain at most 16 MiB from each of
  `stdout` and `stderr`; exceeding either bound terminates and reaps the producer
  instead of allowing an unbroken line or runaway diagnostics to exhaust system
  memory. Remote SSE responses now also have a 64 MiB whole-stream ceiling in
  addition to their existing per-line and per-event limits.
- The detailed TUI/session-save transcript is now limited to 128 MiB, retaining a
  contiguous recent suffix and a truncation marker while leaving the separately
  compacted runtime conversation untouched.
- Terminal task-bound sub-agent failures now release their backend, shared-chat
  registration, recall state, and task execution scope immediately (taskless
  conversational failures remain retryable). Closed/terminal inspection history
  retains only the 32 newest records, with at most 256 KiB of report text each,
  instead of keeping every backend and accumulated report for the entire session.
- OpenAI-compatible reasoning streams no longer rescan and copy the complete
  accumulated reasoning output for every token. Cross-delta closing-marker
  detection now retains only a bounded marker prefix, preventing quadratic work
  during long thinking responses.
- Telegram live mentions such as `@coordinator` now retain their Telegram
  response destination when shared-chat coordination starts its synthetic
  coordinator turn, so the coordinator reply is delivered back to Telegram
  instead of appearing only in the terminal.
- Receiving a Telegram prompt in the interactive TUI no longer aborts with a
  Swift exclusivity violation while updating and scheduling the prompt queue.
- The Telegram inbound mailbox now identifies the receiver it parks, like a
  pending producer. A new receive resolves a suspended one with `nil` — no
  element consumed, no silent continuation overwrite — task cancellation
  removes only the receiver that task parked, and `finish()` resolves the
  receiver currently suspended. Concurrent iterators or a close consumer
  handoff can no longer strand one continuation while terminating another.
  The bounded, FIFO, lossless backpressure and the source-compatible
  `AsyncStream` ingress surface are unchanged.

## [2.0.1] - 2026-08-28

### Added

- `/goal` workflows can now be continued in conversation across the TUI,
  Telegram and ACP. When a coordinator turn ends with the explicit
  `Workflow question` block mandated by the `/goal` contract, ZenCODE says so
  and the next plain message resumes the *same* graph, re-injecting the graph
  ID, the completion contract and the delegation rules instead of starting an
  unrelated chat turn. Any other coordinator output (progress reports, final
  summaries) leaves the round-trip disarmed, so ordinary messages are never
  captured. Slash commands and live `@mentions` keep their precedence, and the
  round-trip stops as soon as the graph is completed or cleared.
- A workflow task graph resumed from a previous session (startup "Open tasks
  from previous sessions" menu) is re-armed the same way: the notice now
  explains that the next message continues the workflow on that graph.
- A `/goal` turn that fails or is cancelled while its graph already holds
  delegated tasks keeps that graph and arms the same round-trip for recovery,
  so the announced retry path really exists: the next message resumes the graph
  and the continuation prompt asks the coordinator to re-delegate or
  `tasks.retry` the interrupted work.

### Fixed

- Starting a second `/goal` while a workflow is still open now fails with an
  actionable message naming the open graph, the number of open tasks, and how
  to proceed (reply in chat, `/tasks`, or `/tasks clear`) instead of surfacing
  the internal `graphNotMutable` runtime error. The same guard was added to the
  ACP `/goal` route.
- A `/goal` whose very first coordinator turn fails or is cancelled no longer
  leaves an empty workflow graph behind, so the startup resume menu stops
  offering "0 of 0 tasks pending" graphs. Conversely, neither the TUI nor ACP
  deletes a workflow graph that already contains delegated tasks when a later
  turn fails or is cancelled.
- Expanded file-change diffs now render Markdown, plain-text, documentation and
  unknown file types entirely in white, including wrapped continuations, instead
  of letting the first fragment inherit the muted line-number gutter color.
- Opening, closing, or first showing the terminal Chat reader now preserves the
  live Sub-Agents section across ordinary dock transitions by safely removing
  its verified old region before the status bar moves the terminal cursor and
  republishing it against the resulting layout. This also covers incoming Chat
  messages whose dock cannot be displayed; unsafe old regions are abandoned
  append-only rather than being erased from an inferred cursor position. Real
  terminal resizes still invalidate unsafe geometry.
- Pressing `Esc` during a terminal turn now interrupts delegated sub-agents for
  that session as well as stopping the main agent.
- Telegram now mirrors every visible intermediate and final response from both
  the main agent and sub-agents, including sub-agent `💬` blocks emitted before
  tool calls.
### Removed

- **Breaking:** Removed the projection of the live shared chat onto ACP. The
  ACP bridge no longer attaches a shared-chat observer on `session/new`,
  `session/load` or `session/resume`, no longer tears one down on
  `session/close`/`shutdown`, and no longer renders `agent.message` traffic as
  `session/update` notifications. ACP stays an ordinary prompt/response
  channel: it keeps streaming the selected profile's own reply as standard
  `agent_message_chunk` updates, and ACP profile selection is unchanged. The
  live shared chat remains a terminal and Telegram surface only; its core
  infrastructure (rooms, mentions, delivery, observers) is untouched.
- `/plan <goal>` now always starts with a mandatory Planner brainstorming turn,
  including for simple or apparently complete requests, so the user can confirm
  or refine scope, assumptions, behavior, or acceptance criteria before the
  final plan is produced. The initial turn now rejects an immediate final plan
  unless it comes after the Planner's question block, while preserving the
  existing chat-routed Planner delegation and follow-up flow.
- The Git summary in the terminal statusbar now refreshes as soon as a delegated
  sub-agent completes a file-mutation tool, instead of waiting for the whole
  sub-agent run to finish.
- `/plan` no longer fails with a missing structured task list when the Planner
  produced a valid final plan but the coordinator skipped the expected task
  registration. The ordered points are now derived from the final message
  itself, in the terminal TUI and over ACP alike, and only when that message is
  rigorously valid (agreed specifications, numbered implementation plan and
  explicit dependencies for every point). Malformed plans, incoherent task
  registrations and the mandatory initial Planner question turn keep being
  rejected exactly as before.

### Changed

- The sub-agent overview separates the model from its token counters with the
  same `·` divider already used between `task:` and `attempt:`, and renders the
  counters with muted `c:` / `p:` / `g:` labels and highlighted values matching
  the other metadata values.
- The statusbar mutes the `c:` / `p:` / `g:` token-counter and `d:` / `w:`
  subscription-usage labels while keeping their values in the default foreground.

### Added

- The sub-agent overview now shows each delegated agent's token counters
  (`c:` cached, `p:` prefill, `g:` generated) inline on the model row — and on
  the `agent: · model:` row in the compact presentation — so the section keeps
  the same number of rows as before. The counters use the same formatting and
  abbreviations as the statusbar; counters wait until a model row is available
  rather than adding one, and the dense and inline presentations remain one
  row per agent. Per-agent
  metrics are merged in `DirectSubAgentRuntime` with the semantics already used
  by the statusbar (partial provider updates accumulate within a turn, prompt
  counters can be retracted, a snapshot event replaces everything) through a
  single shared `DirectAgentGenerationMetrics.merging(current:update:)` helper,
  and each new turn starts a fresh accumulation instead of carrying the
  previous turn's totals forward.
- All live shared-chat messages (`agent.message`) from the active room are now
  forwarded to the linked Telegram chat, including operator-originated,
  coordinator↔agent, agent↔agent, direct multi-recipient and broadcast traffic.
  Each card shows a readable sender → recipient route; replying to a forwarded
  non-operator card with **text** answers its sender directly. A relay actor reuses the terminal's single
  shared-chat observation (no second observer) and owns its own delivery ledger,
  so a forced reattach or `/telegram off` → `/telegram on` on the same room and
  chat cannot resend a card that was already delivered. Delivery is at-most-once
  per room, chat, and message identity for as long as that binding's ledger
  lives: the ledger survives `/telegram off` → `/telegram on` and a forced
  reattach of the same pair, and is cleared when the binding changes room or
  chat, at teardown, or when its bounded history evicts the oldest entries. A
  receipt that arrives while the relay is unbound (a send started before
  `/telegram off` that answers during it) is parked in a bounded list and becomes
  routable only if the very same room and chat are re-activated; any real binding
  change or teardown discards it, so an `A → B → A` round trip cannot reopen a
  retired context. The
  Telegram Bot API offers no idempotency key for `sendMessage`, so an identity is
  marked before the HTTP call and never retried automatically. Rebinding to
  another room fences the previous binding: the outbound queue is retired and the
  rebind only returns once no card of the retired room can still be in flight,
  while re-activating the same room and chat is idempotent and keeps queued cards
  and in-flight receipts. Cards are sent as plain text without a Markdown parse
  mode and with control/bidi scalars removed, because sender names and message
  bodies are agent-authored content, and the outbound wire bound is measured in
  UTF-16 code units so hostile Unicode cannot exceed the Telegram limit or be cut
  mid grapheme cluster. Incoming updates now decode `reply_to_message`
  non-recursively, and the Telegram receipt of each card is kept in a bounded map
  that routes an agent sender to its stable participant id and the coordinator to
  its reserved destination. Routing never uses the quoted text Telegram echoes
  back; remote commands, slash commands and a resolving `@mention` keep
  precedence as decided by their own parsers, an unknown or retired card falls
  back to the ordinary prompt path, and a reply to an agent that is no longer
  active fails loudly instead of silently becoming a root prompt. Direct replies
  are text-only: a voice note that quotes a card is refused with an explicit
  message instead of being turned into a root prompt, because the reply target
  cannot be revalidated across transcription. The terminal's blocking input
  fallback forwards cards too, but it has no Telegram ingress consumer, so its
  cards and its `/telegram on` notice state that answers must be typed in the
  terminal; that fallback binds the relay when the loop starts and again at every
  `/new` or `/resume` boundary, so a room that never emits shared-chat traffic
  cannot leave the retired room bound. Forwarding is lossless: the outbound queue
  stays bounded, but a full queue suspends the producer (bounded backpressure)
  instead of discarding cards, capacity is granted in strict arrival order so
  FIFO survives the wait, and a batch or replay far larger than the queue is
  delivered completely and in order. Admission and deduplication commit in the
  same actor step, so a producer whose wait is cancelled or whose binding is
  retired marks nothing and the message stays replayable; a rebind, `/telegram
  off` or teardown wakes every parked producer with a refusal, so backpressure
  cannot deadlock the fence or deliver a stale card. A room swap (`/new`,
  `/resume`) or teardown retires the ledger, the
  receipt map and the bounded outbound worker.

### Changed

- `/plan`, `/goal`, and `/review` are now routed consistently in the terminal TUI,
  Telegram, and ACP. `/plan` and `/goal` use one Agent Core command kernel, while
  `/review` delegates read-only inspection through the configured `Reviewer`
  profile on every frontend. `/plan` supports an ephemeral multi-turn Planner
  clarification loop: question blocks do not create tasks or replace the active
  plan, normal replies return to the same Planner with output-revision fencing,
  and a new `/plan <goal>` or `/plan clear` closes and abandons the prior
  collection. Its control state is never persisted or reconstructed after a
  session restore; visible question/reply messages may remain in normal history,
  but question blocks cannot be saved as plans. ACP keeps the original command
  visible while sending only the hidden operational prompt to the model, fences
  late results by session, epoch, prompt, collection, and runner-generation
  identity, and rolls back stale history/task-graph commits. Final plans now
  require one pending, ordinal `plan-<token>-N` task per numbered point with exact
  text and dependency agreement before they can replace or approve a plan.

- Telegram now mirrors every response a turn produces — each intermediate root
  response that precedes a tool call, each completed sub-agent response, Task
  updates, authorization requests, the final response, and the file-change
  Summary — while still excluding reasoning and tool-call names, arguments, and
  results. The final response is never duplicated, and the outcome and Summary
  are delivered directly to the linked chat when progress reporting is
  unavailable.
- Long source lines in tool-rendered file changes now wrap within their existing
  single or side-by-side columns instead of being truncated, preserving line
  gutters, alignment, and colors, including when writing a new file.
- Wrapped side-by-side diff continuations now retain their code-area background
  through the added-cell padding and to the physical row edge.
- Telegram now exposes only root and delegated responses, Task updates, authorization
  requests, and the final Summary; it no longer mirrors tool-call activity.
- Sub-agent overviews now keep using the configured model binding's readable title
  after a provider reports a less-specific runtime model identifier.
- `skills.read` now accepts an optional relative `resource` within the selected
  prompt skill, resolving it without exposing absolute paths or requiring a
  filesystem tool.

### Fixed

- In app mode, the custom `_zencode/usage/subscription` notification of a
  turn can no longer overtake content the same turn had already produced and
  was still buffered: the buffer is drained first, and a buffered
  `usage_update` is emitted only after any text produced before it, so the wire
  order keeps matching the production order. This is an ordering guarantee for
  already-produced content, not a promise that the reply always precedes every
  notification. The wire format and API are unchanged.
- `agent.wait` now redraws and continuously refreshes the live Sub-Agents section
  even when the agent snapshot is unchanged when the wait begins, instead of
  showing only the blocking tool row until completion.
- Wrapped source lines in file-change tool output now preserve the syntax color
  active at each line break instead of rendering continuation fragments in the
  default foreground color.
- File mutation tool completions now show every changed source line without
  snippet limits; recognized code extensions use their matching syntax colors,
  while text, documentation, and unknown file types remain unhighlighted.
- Coordinator `agent.*` tool calls and the live Sub-Agents overview now transfer
  their shared terminal rewrite anchor in both directions across repeated calls.
  Starts, progress refreshes, and completions erase only their still-owned rows
  instead of accumulating duplicate tool and Sub-Agents sections.

- The hidden operational prompt of a Planner delegation turn is no longer
  persisted into session history, snapshots, or resumed conversations; the
  replay-required tool envelope of that turn is preserved while the visible
  Planner output replaces the coordinator prose.
- Telegram remote slash commands now accept the `@botname` suffix Telegram
  adds in group chats, and a coordinator command that completes synchronously
  (for example `/review` with nothing to review) now has its terminal output
  delivered to the linked chat instead of being dropped.
- The Telegram pairing offset can no longer regress when a long-poll batch
  returns updates out of order, which would reprocess already-seen updates;
  failures while sending advisory messages for rejected attempts also no longer
  abort the active pairing wait.
- A single grapheme cluster wider than the outbound UTF-16 budget is replaced
  by a visible ellipsis instead of an empty message Telegram would reject.

## [2.0.0] - 2026-08-26

> **Breaking release:** compared with v1.3.0, v2.0.0 removes public
> `ToolOutputDetailLevel` and the TUI output-detail toggle (`Ctrl+T`), the
> `--verbose`/`verboseLogging` and legacy logging interfaces, and the former
> contextual result payloads of `local.editFile` and `local.multiEdit`. Update
> integrations to use `ZENCODE_LOG` and the platform system log.

### Added

- Tool executions now emit secret-redacted structured records through Swift's
  system `Logger` instead of application-owned files. Records include tool and
  session data, agent identity, model, status, optional duration, and detailed
  typed error causes; delegated-agent executions carry the child's identity.
  `/tools logs` opens the platform system log viewer (Console.app on macOS).
- `/skills uninstall` now opens an interactive multi-selection menu for removing
  app-installed prompt skills. Uninstall destinations are validated against the
  app catalog roots, including symlink and containment checks, before deletion.

### Changed

- Completed sub-agent responses now render directly beneath their agent metadata,
  with every Markdown output line indented as nested agent content instead of
  resembling a coordinator response.
- `/plan` now requires the read-only Planner to produce a concise, self-contained
  functional analysis. Every numbered implementation point is a complete
  specification implementable from the plan and workspace after declared
  prerequisites, with observable behavior/flow, verified files or symbols,
  applicable constraints and edge cases, and concrete validation. It omits context
  summaries, generic background, non-pertinent sections, and detail that does not
  change implementation, using the fewest points and words that preserve
  implementation certainty. The Planner resolves necessary choices from evidence
  or asks a focused blocking question.
- Delegated sub-agent tool calls now reuse the coordinator's canonical terminal
  rows—including lifecycle status, duration, failures, and source-change diffs—
  while remaining indented inside the live Sub-Agents section. Each agent keeps
  one current tool area, replaced in place with the rest of the overview.
- Sub-agent thinking now keeps a stable `🤔 thinking…` header in the terminal
  overview and renders the currently streamed paragraph beneath it, replacing
  only that value in place when the next paragraph begins. Paragraph detection is
  independent of stream chunk boundaries (including CRLF split across deltas),
  the phase is tracked as typed state instead of a marker prefix, and the reasoning
  text is neutralized against terminal control sequences before it is rendered.
- **Breaking:** `local.editFile` and `local.multiEdit` now return fixed compact
  confirmations with only the path and replacement/edit count, not post-edit
  context or diff-like output.
- Project-memory guidance and descriptors now treat memory as a concise,
  evidence-backed journal: verified handoffs, durable decisions, blockers, and
  releases/publications are retained while transient activity, speculation, and
  raw output are excluded. Read-only memory tool surfaces now receive guidance
  that does not suggest unavailable mutations.
- **Breaking:** Removed public `ToolOutputDetailLevel` and the terminal
  output-detail toggle, including its `Ctrl+T` shortcut. Tool output now has one
  standard compact presentation.
- Terminal command completion now recognizes parser aliases and static arguments
  for `/tasks`, `/agents`, `/tools`, `/feature`, `/changes`, and `/skills`,
  including `/skills add`, `/skills uninstall`, `/tasks ls`, and `/tasks get`.
- Removed redundant compatibility and helper code across the MCP bridge, bundled
  features, Xcode tools, and shared tool models without changing public behavior.
- Decomposed the session runner, terminal render coordinator, feature process
  lifecycle, and local MCP transport into focused domain units — shared
  lifecycle/teardown primitives, typed stream-pump handlers, and per-domain
  companion files. No existing public API, wire, or persistence behavior
  changed; one new public helper, `FeatureProcessTreeSupervisor.terminateImmediately`,
  was lifted out of a private teardown path.

### Removed

- **Breaking:** Removed `--verbose`, `ZENCODE_AGENT_VERBOSE`, and the
  `verboseLogging` runtime setting, along with verbose stderr/progress, ACP
  file-log, and provider-diagnostic output. The flag is rejected.
- **Breaking:** Removed `ZENCODE_LOG_LEVEL`, `ZENCODE_LOG_FILE`, and legacy
  `ZenLoggerConfiguration.Destination.file`/`.standardError`; logging uses
  `ZENCODE_LOG` and the platform system log.

### Fixed

- Nested Sub-Agent Markdown code blocks no longer add a spurious blank row, and
  nested tables and code blocks now reserve their indentation when fitting to
  the terminal width.
- Fixed live Sub-Agents rendering losing its terminal anchor when the first
  shared-chat message makes the compact Chat header appear.
- `/tools logs` is now available while a prompt is running; other `/tools`
  invocations remain unavailable.
- Standard terminal tool output preserves its ANSI colors, compact status
  layout, source changes, and redraw lifecycle without alternate detail modes.
- The ChatGPT subscription WebSocket test server now closes its channel only
  after its response has flushed, eliminating a response-delivery race.
- End-of-turn terminal file-change summaries now remain the final section after
  pending task-graph and plan output on both successful and failed prompts.

## [1.3.0] - 2026-08-23

### Added

- Builder now exposes `feature.promote`: generated non-adopted Swift features can be
  copied transactionally into a branch of a ZenCODE Git checkout. Promotion
  performs validate/build/`--list-tools` preflight, excludes Builder manifests,
  build state, Git metadata, and symlinks, writes `feature-distribution.json`,
  updates declarative/Swift catalogs, and never commits or pushes.
- Setup gained a **Data management** subsection grouping backup export,
  backup import, and the existing remote-configuration reset (removed from
  the main menu). Export writes the whole support directory — hidden files
  and nested directories included — to a single compressed tar.gz archive;
  Import validates it completely (per-file SHA-256, traversal and symlink
  rejection, entry limits) before atomically replacing the support
  directory, with automatic rollback on failure. Backups are unencrypted
  and contain provider credentials.
  Export fails explicitly when the support directory contains a symbolic
  link, runs under the shared coordination lock for a coherent snapshot,
  and replaces an existing archive rollbackably. The import swap preserves
  the coordination lock's inode so cross-process exclusion survives the
  rename, and manifest totals use overflow-checked arithmetic.

### Changed

- Renamed the delegated task-graph command from `/workflow` to `/goal`; the old
  command is no longer accepted.
- Project `AGENTS.md` guidance is now fully manual and read-only from ZenCODE's
  perspective. When the file exists in the working directory, ZenCODE reads it
  and inserts it into the agent context, but it no longer creates, regenerates,
  materializes, or rewrites the file. `AGENTS.md` is no longer ignored by the
  repository so projects may version it intentionally.
- The setup menu moved **Features** and **Memory embeddings** from the Optional
  group to the Recommended group, so the recommended configuration steps are
  shown together before the optional integration toggles.
- File editing tools now use compact canonical `old`/`new` arguments, preserve
  consistent line endings, reject ambiguous or empty matches, and return
  bounded post-edit context with affected line ranges. Their schemas and output
  payloads are substantially smaller while retaining atomic multi-edit
  semantics.

### Fixed

- The terminal’s live **Sub-Agents** overview now replaces its existing owned
  rows when a new delegation wave arrives, avoiding duplicated stale sections.
- Messages written by the terminal operator remain visible in the shared-chat
  reader but no longer increment, shift, or consume the unread-message marker.

### Removed

- Removed the `/agents-md` command and its legacy `/make-agents` alias, including
  the dedicated model turn, restricted tool allowlist, and write
  post-condition tracking. **Migration:** create or edit the project
  `AGENTS.md` manually; ZenCODE will apply it automatically when it is present
  in the working directory. The separate global `~/.zencode/AGENTS.md` behavior
  is unchanged.
- Removed the public `ProjectContextFileService` APIs that created, regenerated,
  or materialized context files; the service now exposes read-only project
  context loading.

## [1.2.6] - 2026-08-20

### Changed

- ACP and agent session lifecycle state is now isolated by session and backend
  generation: stale work is fenced during rebuild, close, reset, and shutdown,
  while authorization handlers, prompt-skill providers, snapshots, and
  task-graph observers are cleaned up with their owning session. Prompt
  reservations remain held until the final ACP result is sent.
- ACP session refresh preserves session revisions, context-window limits, and
  generation-parameter overrides; task-bound sub-agents receive a restricted
  `tasks.update` schema, and OpenAI tool payload generation requires an explicit
  session scope.
- Terminal overview rendering now keeps actor-confined state in dedicated value
  types, clears stale delegated rows, respects display width and CommonMark
  ordered-list limits, and mirrors only task-graph overviews to Telegram;
  high-frequency sub-agent snapshots remain terminal-only.
- Direct Anthropic requests now share subscription thinking capability and
  payload rules, while model catalog URLs preserve configured base paths and
  query items.
- MCP local transports share bounded stream-pump and process-tree lifecycle
  handling, drain buffered output before teardown, and keep Figma endpoint
  ownership in its standalone feature.
- Session prompt composition now centralizes shared workflow, memory, agent, and
  project-context guidance, avoiding duplicate legacy Developer instructions and
  redundant active-plan policy. The generated global `AGENTS.md` template keeps
  only the additional Xcode-specific guidance.

### Fixed

- Provider thinking authorization again honors known manifest options while
  preserving `.enabled` for effort-level dialects and unknown capabilities.
- Task-graph checkpoint state is reset when sessions are discarded or recreated,
  so saving after deleting all plans no longer fails with a stale checkpoint.
- ChatGPT browser sign-in no longer hangs when the local callback port is
  unavailable: it falls back to manual authorization-code input.
- SSE streams now enforce post-head idle timeouts, bound line and event
  accumulation, handle bare CR delimiters across chunks, and report typed
  parsing failures instead of stalling or growing without limit.
- ACP diagnostics are filtered consistently and empty tool results omit empty
  content blocks; terminal thought and Markdown rendering handles structured
  content without hard wrapping.
- The shared-chat reader overlay no longer paints over the live Sub-Agents
  section: expanding the Chat box now relinquishes the section's owned
  terminal rows before the status bar redraws, and ACP lifecycle checks no
  longer await synchronous state.
- Application-provided system prompts now receive the same dynamic `AGENTS.md`,
  delegatable-agent roster, memory-tool policy, and task-workflow context as
  standard sessions, so exposed delegation and memory tools always have the
  profile bindings and usage rules they require.

### Security

- Destructive tool authorization now applies before feature-owned alias dispatch,
  renders consent arguments with lossless shell quoting, and keeps per-session
  permission decisions isolated and evicted on close and shutdown. Task
  cancellation without an explicit session is rejected, and ambiguous
  tool-selection prefixes no longer resolve silently.
- WebTools now rejects loopback, private, link-local, metadata, multicast,
  reserved, local, and ambiguous numeric destinations on requests, redirects,
  and main-frame navigation. Jira credential-bearing requests require HTTPS and
  exact same-origin redirects.
- Saved-session indexes are created and read with private file and directory
  permissions, harden legacy modes, and reject destination symlinks; MCP logs
  redact sensitive environment values and invalid OAuth metadata URLs fail
  closed.

## [1.2.5] - 2026-08-17

### Added

- Telegram sessions can now manage tasks and sub-agents, mirroring task-graph
  activity as overviews while keeping high-frequency sub-agent snapshots in the
  terminal only.
- Saved plans gained a full lifecycle: completed live plans are mirrored into
  the library, `/plan list` reviews them with short ids, and `/plan delete`
  removes exact or unique-prefix targets.
- Optional features are validated in CI through a generated per-feature
  matrix, and the installers share hardened support helpers with an explicit
  Swift 6.3+ toolchain check and pinned per-feature lockfiles.

### Changed

- Provider thinking configuration is resolved from explicit settings and
  model metadata instead of streaming heuristics, and `/setup` only offers
  thinking for models that support it.
- Anthropic message encoding, stream accumulation, and thinking-block handling
  moved into dedicated transport components as part of the provider rework.
- Memory engine persistence was reworked with graph versioning, transactional
  saves, entry deduplication, and read-only search, with project-context write
  contracts covered by dedicated tests.
- Behavior-preserving refactoring removed dead code and deduplicated helpers
  across Remote, Telegram, TUI, and the session orchestrator.

### Fixed

- Feature processes are signalled across their whole process tree, so
  terminating a feature job no longer leaves orphaned children.
- Sub-agent tool calls render correctly in compact terminal output.

## [1.2.4] - 2026-08-13

### Changed

- Remote model discovery now queries each configured OpenAI-compatible provider
  directly, while OpenRouter metadata is merged separately when available to
  preserve context-length and thinking-capability details.
- Shared JSON, hashing, direct-tool argument parsing, and network-error helpers
  replace duplicated compatibility layers, removing obsolete runtime code while
  preserving existing public behavior.

### Fixed

- Task-bound sub-agents now receive accurate `tasks.update` guidance and can
  report progress without attempting lifecycle mutations owned by the runtime.
- Non-streaming HTTP requests now retain their timeout through complete body
  consumption, follow bounded redirects safely, and strip sensitive headers on
  cross-origin redirects.
- Remote model selection keeps provider results authoritative while enriching
  matching entries with OpenRouter metadata without exposing provider API keys.

## [1.2.3] - 2026-08-11

### Changed

- `tasks.create` and `agent.create` system-prompt guidance and tool descriptors
  now use a single canonical payload shape, producing more consistent task-graph
  and delegation instructions across `/plan`, `/workflow`, and `/review`.
- Compact tool rendering in the terminal handles sub-agent tool calls more
  cleanly, with improved rendering for delegated agent activity.
- The shared-chat reader (`Ctrl+Y`) now opens at the first unread message instead
  of the latest, so new messages are immediately visible.

### Fixed

- A session turn lease (`AgentSessionTurnLease`) now serializes concurrent turn
  requests to the session runner, preventing overlapping turns from corrupting
  coordinator state.
- ChatGPT subscription WebSocket pool and task race conditions are resolved: the
  pool tears down HTTP connections deterministically, and WebSocket task
  cancellation can no longer leak or double-fire.
- The MCP tool runtime now fences install-generation boundaries, preventing
  interleaved feature installations from corrupting the runtime.
- Terminal redraw glitches during sub-agent delegation are fixed: the render
  coordinator no longer leaves stale frames when agent status changes.
- Shared-chat unread counts are now computed correctly when the reader is
  reopened after new messages arrive.
- A timing-dependent test (`readBridgeAbandonsOnTimeout`) is stabilized with a
  wider margin between the bounded timeout and the simulated slow read.
- A flaky HTTP transport test (`chatGPTHTTPFallbackDoesNotRetryCallbackFailure`)
  is stabilized: the local test server now sends an explicit HTTP `.end`
  terminator before closing the channel, preventing a transport-level close from
  racing ahead of the final body chunk.

## [1.2.2] - 2026-08-10

### Added

- A transient `Chat` reader is now available in the terminal for live shared-chat
  messages. `Ctrl+Y` opens or closes it (`Ctrl+O` also works where supported),
  with compact total/unread counts and expanded message navigation; entries stay
  out of the main transcript.

### Changed

- Shared-chat messages delivered while the coordinator or a delegated agent is
  already working are injected into the next tool result so the recipient can
  reply immediately and resume its current turn. Idle and standby recipients
  retain queued delivery, with a lossless fallback when no further tool call is
  made.
- Task-graph summaries now show total and color-coded status counts, use
  terminal-safe plain text outside ANSI output, and present more compact task
  details.

### Fixed

- Terminal shared-chat observations now reconnect after an unexpected
  non-cancelled stream end or backend replacement, while bounded retries avoid a
  hot loop when an empty stream repeatedly closes.
- Operator messages to `@coordinator` now wake shared-chat processing immediately
  instead of waiting for the safety poll.
- Terminal escape and OSC sequences, including multiline and unknown payloads,
  are drained safely instead of leaking bytes into prompt input.

## [1.2.1] - 2026-08-09

### Fixed

- Coordinator-originated `agent.message` traffic now wakes shared-chat
  transcript observers immediately. Direct coordinator→sub-agent messages no
  longer depend on the periodic safety poll before their blue terminal card (or
  ACP update) is emitted.
- The terminal `@` autocomplete no longer shows only `@coordinator` and `@all`
  when agents are live. The input panel now pulls the current shared-chat roster
  while a mention token is being edited, instead of depending solely on roster
  notifications, which the bounded terminal queue evicts first and which the
  coordinator published only on a roster-signature change. A dropped roster
  event is now also re-published on the next coordination poll, and `/agent` no
  longer clears the mention entries from the panel catalogue.
- Live shared-chat messages are now rendered by ACP clients. A sub-agent that
  reports through `agent.message` reaches the ACP host as a standard
  `agent_message_chunk` instead of being visible only in the terminal UI. The
  renderer is attached once per session incarnation, is kept in a bridge-scoped
  registry so no session-state rebuild (prompt refresh, `@agent` routing,
  `set_model`) can silently drop it, is attached after a `session/load` history
  replay so transcripts are never interleaved, skips operator traffic the client
  already displays, and is awaited to quiescence by `session/close` and
  `shutdown`.

## [1.2.0] - 2026-08-09

### Added

- Project memory now uses a durable, per-workspace graph outside the working
  tree. Existing `MEMORY.md` content is imported lazily and left untouched,
  while graph mutations are persisted atomically.

- Automatic memory recall is enabled by default: relevant project facts are
  injected transiently into main and delegated turns without entering
  conversation history, snapshots, or prompt cache keys. Retrieval uses local
  BM25 by default; optional endpoint-based embeddings add semantic ranking and
  are configured from `/setup`.

### Changed

- The terminal `@` autocomplete now builds display labels and routing IDs from
  one live participant snapshot. Departed agents are removed from handle
  resolution immediately, while their aliases remain reserved against reuse;
  returning instances with the same stable ID recover their original route.

- Replies from a delegated agent to a direct human-operator message now use the
  dedicated `agent.message` destination `operator` instead of being routed to
  the coordinator. Operator replies remain visible through the transient room
  transcript and never enter the coordinator mailbox. If a provider completes
  that direct conversational turn without calling `agent.message`, its final
  output is delivered to `operator` as a non-duplicating runtime fallback.

- Shared chat delivery is now serialised in each recipient's work loop instead
  of tied to a tool call. The inline-delivery mechanism that appended live
  messages to the result of the next tool boundary has been removed: every
  message — to an idle, running or standby agent — is drained from the bounded
  mailbox and queued as a prompt, so the reply is the next turn of that agent,
  independent of any future tool call. This fixes the case where a standby agent
  never replied because it had no tool to execute. A message is never lost or
  delivered twice, and the coordinator room drains its mailbox even while busy
  (pending batch shown to observers, synthetic turn held back until the room goes
  idle and re-armed at turn end).

- The blue shared-chat message card now reliably reaches every active observer
  within the transcript bound. The coordinator replays the bounded room
  transcript to each newly attached observer, shared-chat messages are never
  dropped from the terminal event queue (backpressure instead of eviction), and
  the TUI deduplicates by message id.

- `@` autocomplete now lists active agents by readable handles derived from
  their display names (`@dev`, `@code-reviewer`) via an actor-isolated mention
  catalogue, instead of opaque `@agent-Base64` blobs. Routing always resolves
  back to the stable participant id; aliases are never recycled within a session,
  duplicate names get numeric suffixes, and the legacy `@agent-Base64` spelling
  remains accepted for backward compatibility.

## [1.1.4] - 2026-08-07

### Added

- Live messages (`AgentSharedChat`): while sub-agents are active, the human
  operator, the coordinator LLM, and the agent instances share a bounded,
  in-memory chat room. From the terminal, `@coordinator` messages the live
  coordinator, `@all` broadcasts to the coordinator and every active agent, and
  the `@agent-…` handle addresses one instance directly. The `agent.message` tool
  exposes the same destinations (`direct`, `coordinator`, `peers`, `all`); direct
  messages wake idle recipients immediately. Every reply travels back through the
  same chat via `agent.message`: both the coordinator and delegated agents are
  instructed that ordinary model output is not part of the chat, so any reply to
  a chat message must be sent through `agent.message` regardless of the sender.
  The chat is transient and never written to a session snapshot or task
  checkpoint.

### Changed

- Runtime prompt composition now separates the cacheable static system prefix
  from the dynamic user context: working directory and response language stay in
  the static prefix, while workflow/task graph, agent roster, and memory travel
  in the dynamic initial message preserved across snapshot restore and
  conversation compaction.

## [1.1.3] - 2026-08-05

### Changed

- `agent.create` now advertises only the canonical batch payload
  `{"agents":[...]}`, where every item carries an explicit `profile` and a
  `binding:<id>` model reference. Delegation no longer falls back to a profile's
  default binding: the model must pick an authorized one from the delegatable
  roster. Legacy root fields and aliases stay input-compatible but are no longer
  model-visible, and conflicting aliases are rejected.
- Sub-agent routing resolves profiles and bindings against a consistent
  `settings.json` snapshot, validating model, provider, capability, and
  authentication before a task is claimed. The resolved provider, model, key, and
  generation parameters are handed to the child backend instead of being looked
  up a second time, so the effective provider cannot change between validation
  and backend creation.
- The TUI command that authors project guidance is now `/agents-md`. It asks the
  model to inspect the current working directory and create or update its
  `AGENTS.md` without assuming a project type. The former `/make-agents` name
  keeps working as a hidden alias.
- Custom ACP extensions are namespaced: `model/preload` and `session/set_model`
  are now `_zencode/model/preload` and `_zencode/session/set_model`.
- ZenCODE-specific data moved out of standard ACP fields and into the `_meta`
  extension object. The model catalog returned by `initialize` and `session/new`
  is now `_meta.models`, and the `rawInput` carried by `tool_call` updates and
  permission requests is now `_meta.rawInput`.
- Subscription usage is delivered as an immediate custom
  `_zencode/usage/subscription` JSON-RPC notification instead of a
  `subscription_usage_update` session update that did not satisfy the ACP
  `usage_update` schema. Context-window usage keeps using the valid
  `usage_update` with `used`/`size`.

### Added

- `/agents-md` verifies its own post-condition against the turn's tracked file
  changes. When the turn ends without creating `AGENTS.md`, or leaves an existing
  file untouched, ZenCODE reports it instead of returning silent success.

### Removed

- The modal `Ctrl+R` reverse history search was removed from the prompt editor,
  together with its panel hints and help text. Ordinary history recall with the
  arrow keys is unaffected.

### Fixed

- Session shutdown waits for in-flight prompt tasks before flushing, closing a
  race at session close.
- Restoring a single task graph preserves the other graphs of a multi-graph
  session, and installing the task orchestrator is idempotent under its exclusive
  ownership guard.
- Optional-feature installations are serialized per feature ID, so concurrent
  requests for the same feature no longer interleave.
- Agent settings are loaded without a stale cache and mutated under
  cross-process exclusive coordination, so delegation cannot run against an
  outdated `settings.json` snapshot. The persisted JSON format is unchanged.

### Security

- Error messages rendered by the ChatGPT OAuth callback server are HTML-escaped,
  and the OAuth `state` parameter is now required when a callback URL is pasted
  manually.
- Sensitive environment values (token, secret, auth, key, password) are redacted
  in MCP bridge logs.
- Timeout input is validated at the optional-feature installation entry point,
  and a force-unwrapped URL construction in the MCP browser OAuth configuration
  was replaced with a guarded failure.

## [1.1.2] - 2026-08-05

### Changed

- Expanded tool blocks now syntax-highlight the `parameters` JSON with the same
  palette used for fenced code blocks in chat: keys, strings, numbers and
  literals keep their classic colors while punctuation and indentation stay on
  the neutral parameter gray. Raw multi-line string bodies rendered inside a
  `"""` block remain flat, so prose is never tokenized as data.
- Prompt editing now follows the Emacs/readline conventions so that motion works
  on keyboards without `Home`/`End` keys: `Ctrl+A`/`Ctrl+E` move to line
  start/end, `Ctrl+B`/`Ctrl+F` move by character, `Ctrl+P`/`Ctrl+N` move by
  line or history entry, and `Alt+<`/`Alt+>` jump to the start/end of the whole
  draft. Escape sequences prefixed by a second `ESC` (macOS terminals that send
  `Option` as `Meta`) are decoded as Alt-modified keys, so `Option+←/→` performs
  word motion there.
- The `local.exec` access-mode toggle moved from `Ctrl+A` to `Ctrl+G`, freeing
  the standard line-start binding. Panel hints, `/help`, and `Docs/zen.md` list
  the current shortcuts.
- Release builds of `zen` now strip local symbols before the binary is verified,
  archived, or installed. CI, the release workflow, and both install scripts run
  `strip -u -r` on macOS and `strip --strip-all` on Linux, and optional Swift
  features are stripped with `strip -S` after a successful release build.

## [1.1.1] - 2026-08-03

### Added

- Persistent process support for optional features (`FeaturePersistentProcess`
  and `FeaturePersistentService`): compatible features such as Xcode tools can
  now reuse one long-lived session-scoped process instead of spawning a new one
  per invocation.

### Changed

- Prompt input field rewritten with a new `TerminalPromptEditor`, inline
  autocompletion, refined key handling, panel layout, and history navigation.

### Fixed

- Xcode tools now reuse one session-scoped feature process and MCP bridge for
  discovery and invocation, so Xcode consent is requested once per ZenCODE
  session instead of once per tool call.
- `zen --doctor` diagnostics corrected; unused agent-runtime and ACP
  configuration fields removed.

## [1.1.0] - 2026-08-02

### Added

- `/plan save` persists the active plan, or the latest non-empty assistant
  response, in the project task-graph plan library; `/plan load` restores the
  latest save as an unapproved plan in a session without an active plan and
  never resumes old execution state.
- Agent profiles now have a backwards-compatible `readOnly` setting that
  centrally removes mutable catalog-owned core tools. Existing manifests decode
  a missing value as `false`; the default Planner and Reviewer enable it.
- Task-graph checkpoints can carry optional saved-plan metadata while remaining
  compatible with existing schema-1 checkpoints.

### Changed

- Delegated agents now derive their tool grant exclusively from a selected,
  configured profile, and the model-visible workflow policy prefers suitable
  sub-agents for non-trivial, independently scoped work. **Migration:**
  `agent.create` now requires `profile` (or `agent`) and rejects request-level
  tool overrides such as `toolNames`; configure the required tools on the
  profile instead.
- Conversation compaction now uses provider-aware prompt budgets, preserves a
  larger useful suffix and bounded summaries, accounts for transport overhead,
  and applies conservative retry targets after context-window failures.
- Xcode feature descriptors now direct models to prefer applicable Xcode tools
  over shell, filesystem, search, SwiftPM, or `xcodebuild` alternatives.
- Terminal presentation now uses centralized semantic styling for thinking,
  tools, sub-agent activity, status, Markdown, and permission dialogs, with
  tool output visually attenuated without dimming model responses.

### Fixed

- Concurrent ACP prompts now share one in-flight runtime-backend preparation;
  actor reentrancy during asynchronous backend hydration can no longer invoke
  the backend factory multiple times for the same runner.
- Read-only agents assigned to a task retain `tasks.update` for attempt progress
  and lifecycle reporting, while `tasks.create`, `tasks.retry`, `tasks.cancel`,
  and other mutating core tools remain restricted.
- `/telegram on` can attach an already-running local turn to Telegram and keeps
  progress reporting synchronized when Telegram is enabled or disabled during
  generation.
- Voice transcription handling, terminal first-row and streamed-thinking
  rendering, sub-agent activity presentation, and related color consistency.
- Context compaction edge cases across shared runtime, ChatGPT, and Anthropic,
  including tiny transcripts, impossible budgets, provider payload inflation,
  cache invalidation, and retry convergence.

## [1.0.11] - 2026-08-01

### Added

- Native Linux arm64 CI and release artifacts alongside the existing Linux
  x86_64 builds, providing downloadable binaries for ARM servers and devices
  such as Raspberry Pi.

### Changed

- Interactive setup is now part of `ZenCODECore`: first-run setup opens
  automatically when required, `/setup` rebuilds the runtime and restores the
  active conversation, and setup tests now live with the Core test target.
- Expanded tool parameter JSON and metadata values now reuse the peach-orange of
  compact tool values instead of medium gray, keeping both presentation modes
  visually consistent while preserving the orange-title-over-content hierarchy.

### Removed

- The separate public `ZenCODESetup` product and target. Setup APIs such as
  `ZenCODESetupRunner` are now exported by `ZenCODECore`.

### Fixed

- A detailed in-progress tool block that exactly filled the scrolling region
  scrolled its title past the top margin before completion could replace it,
  leaving a stale hourglass copy in the transcript beside the completed result.
  The rewriteable row capacity now reserves the cursor row needed after the
  block's terminating newline.

## [1.0.10] - 2026-07-31

v1.0.9 was tagged but never published: its Linux release gate failed on the
flaky test fixed below, so no release assets were produced for that tag.

### Added

- Downloadable macOS arm64 and Linux x86_64 binaries from successful CI runs,
  retained as workflow artifacts for 30 days. Verified tag builds also publish
  versioned archives and SHA-256 checksums as persistent GitHub Release assets.
  This is the first release whose assets are actually published, see the fix
  below.

### Fixed

- Release workflow now publishes the verified binaries it builds. The release
  gate ran the test suite in parallel, which could park Foundation's
  process-global lifecycle state and stall the step until the job timeout, so
  the archive, upload, and publish steps were skipped and every GitHub Release
  from v1.0.0 to v1.0.8 was created without assets. The gate now matches CI with
  `swift test --no-parallel`, and its timeout allows for the clean, uncached
  build it performs.
- Removed an unsupported `timeoutSeconds` argument from the `feature.build`
  invocation in `SwiftFeatureManagementTests`.
- Flaky ACP concurrency test `concurrentACPPromptsReserveTheSessionExactlyOnce`,
  which dispatched both prompts and opened the completion gate without waiting
  for the first prompt to reach the backend. Because `Task` does not start its
  body synchronously, a slow runner could let the first prompt finish and
  release its reservation before the second one began, so no rejection was
  recorded. The test now pins the first prompt with the same `startGate` used by
  the other lifecycle tests in the suite, making the reservation contention
  deterministic.

## [1.0.8] - 2026-07-30

### Changed

- `xcode-tools` is now a fully self-contained macOS-only optional package. The
  former root `XcodeToolsFeature` library product was removed: its MCP bridge
  discovery and policy, request compatibility normalization, workspace matching,
  execution, presentation, and tests now live entirely in the package-local
  implementation. The root graph exports no Xcode feature product, `ZenCODECore`
  imports no Xcode implementation module, and Linux builds no longer compile
  Xcode runtime metadata or compatibility shims (removed
  `LinuxXcodeToolCompatibility`).
- Telegram runtime files reorganized out of `ZenCODETUI` into
  `Sources/ZenCODECore/ZenCODE/Telegram`, with the `TerminalChat+Telegram`
  adapter moved under `Chat/Telegram`, keeping terminal presentation separate
  from the Telegram runtime.
- Simplified the direct MCP tool runtime (`DirectMCPToolRuntime`), the direct
  tool executor, the memory service, and tool-selection presentation across the
  root package.

### Fixed

- Optional-feature upgrade and installation from setup: bounded installation
  diagnostics and logging, executable resolution validation, and feature
  management rendering across `SwiftFeatureOptionalInstallation`,
  `SwiftFeatureManagementTools`, `SwiftFeatureRuntimeValidation`, and the setup
  runner.
- Linux test compatibility for the bundled-feature catalog parity suite.

## [1.0.7] - 2026-07-30

### Added

- New optional macOS feature package `desktop-tools` (`desktop.run`): typed
  desktop control covering permission/system inspection, app and window
  enumeration, PNG screenshots attached to the model's multimodal context,
  pointer/keyboard/clipboard input, and app/window management. It is installed
  on demand like every other optional package, never executes caller-supplied
  shell or AppleScript code, and is not offered on Linux.

### Fixed

- Startup task recovery now skips checkpoint scanning and its interactive
  selection when `zen` runs in `--acp` mode, preserving JSON-RPC-only I/O.

### Changed

- Optional Swift features are now standalone SwiftPM packages under
  `Sources/Features` rather than executable products in the root package or
  files installed beside `zen`. The installer removes the legacy
  `zen-features/` directory, preserves a source checkout, and offers on-demand
  installation through `zen --install-features`; selected packages are built as
  Builder-compatible local features in `~/.zencode/features/<id>/`.

## [1.0.6] - 2026-07-29

### Added

- Startup recovery for incomplete task graphs. Interactive sessions now scan
  the current project for unfinished work and present it in the same orange,
  scrollable picker used by setup. Operators can resume a graph, start fresh
  without changing saved work, or mark obsolete graphs with `[x]` and delete
  them selectively.
- Exact-graph recovery semantics: a startup choice is resolved by
  `sessionID + graphID`, and the selected graph is made active/current and
  persisted before the model backend starts. Other graphs in the same
  checkpoint are preserved, while superseded active graphs are archived.
- Declarative tool-presentation metadata shared by direct tools, MCP tools, and
  Swift Features, including structured titles, locations, arguments, statuses,
  and change summaries.
- Expanded Browser feature observability, including bounded console and network
  diagnostics with filtering and redaction.

### Changed

- Tool output rendering now uses the shared presentation contract across the
  compact and expanded TUI views, ACP updates, bundled features, and delegated
  tools, with clearer orange-family hierarchy and parameter formatting.
- ChatGPT subscription sessions now prefer Responses WebSockets for the root
  session, retry replay-safe transient failures within a bounded budget, and
  fall back to HTTP/SSE for the remainder of the logical session when the
  WebSocket path is unavailable. Delegated sessions start directly on
  HTTP/SSE to avoid accumulating long-lived connections.
- Telegram turn reporting and permission handling now preserve tool-call order,
  accumulate assistant content cleanly, and provide richer inline progress
  without duplicating the final response.

### Fixed

- Task recovery no longer restores whichever graph happened to be current when
  an old checkpoint was written. The exact graph selected by the operator is
  now authoritative, including when one previous session contains multiple
  incomplete graphs. Persisted active attempts are marked `interrupted` and
  their tasks become `blocked` instead of being assumed to still be running.
- ChatGPT WebSocket lifecycle, continuation parsing, connection fallback, and
  close handling across transport resets and replay-safe retries.
- Anthropic subscription thinking-block accumulation and thinking payload
  handling across streamed responses.
- Expanded tool rendering, active-tool selection, tool-name normalization, and
  related Linux build compatibility.

## [1.0.5] - 2026-07-28

### Fixed

- ChatGPT prompt-cache persistence crash: persisted cache keys now use a
  compact SHA-256 hash of a canonical session-identity encoding instead of
  embedding the full system prompt. The previous reversible representation
  could grow to tens of kilobytes per session and, with hundreds of sessions,
  exceed macOS's 4 MiB `UserDefaults` limit. Added bounded storage with LRU
  eviction, value validation, legacy-format migration, and a dedicated
  mutation lock.
- `MCPFeatureConfiguration` protocol dispatch crash: `makeExecutor`,
  `toolNamePrefix`, and `descriptionPrefix` are now protocol requirements with
  dynamically dispatched defaults, replacing the statically dispatched
  `fatalError` default that trapped even when a conformance supplied its own
  implementation.

### Changed

- Telegram progress reporting: the turn reporter now accumulates assistant
  content and emits tool-call messages inline, replacing the previous stream
  of separate system messages (turn started, voice received, transcription
  ready, file-change summary). The final response is delivered once on
  completion, reducing notification noise.

## [1.0.4] - 2026-07-27

### Fixed

- ChatGPT prompt-cache routing: separated the canonical `prompt_cache_key`,
  now persisted by session identity, from the rotating WebSocket session ID
  that changes after compaction, failure recovery, or stream-interruption
  replays. The cache key no longer rotates on transport resets, so prompt
  caching survives continuation replays and connection failures.
- Prompt-skill tools (`skills.list`, `skills.read`) in delegated sub-agents:
  the parent session's prompt-skill tool provider is now propagated to each
  sub-agent, keeping the intrinsic skill selection always-on at every
  delegation depth.

### Changed

- Broad internal refactoring across the MCP transport codec and clients, the
  browser CDP feature layer, the ACP bridge and update pipeline, the remote
  generation and subscription clients, the SwiftNIO HTTP/SSE/WebSocket
  transport, and the terminal input and rendering layer.

## [1.0.3] - 2026-07-27

### Added

- Continuous integration workflow running the full build, test, and release
  gate on macOS 26 and Ubuntu 24.04 with Swift 6.3.
- Release verification workflow enforcing the strict `vX.Y.Z` tag contract
  against `ZenPackageMetadata.version`.
- Contribution, security, and changelog documents plus issue and pull request
  templates.

### Changed

- Expanded project documentation.

### Fixed

- Linux CI deadlock in `FeatureProcessRunner`: Foundation's global process
  reaper could suppress a child's terminationHandler after SIGKILL, hanging the
  cooperative thread pool and cascading test timeouts; added a bounded reaping
  fallback and an explicit exit monitor.
- Cross-platform Xcode MCP candidate detection on Linux, replacing the no-op
  shim that misclassified ACP-provided servers.
- `exec.job` tool handling.

## [1.0.2] - 2026-07-26

### Changed

- New rendering for the sub-agents section.
- Improved rendering of agent model bindings.

### Fixed

- `swift-tools-feature` test handling and related layout issues.

## [1.0.1] - 2026-07-25

### Added

- Session language setup and an editing-files renderer.
- New prompt-skills management.

### Changed

- Complete `TerminalChat` isolation and a lifetime token for the NIO transport.

### Fixed

- Anthropic thinking-effort handling.
- `upgradeRejected` handling in the ChatGPT WebSocket transport.
- ChatGPT model selection.
- Installer and Linux build issues.
- Tool authorization handling.

## [1.0.0] - 2026-07-24

First stable release.

### Added

- Native-Swift coding agent for the terminal and ACP, distributed as a single
  compiled binary with no Node runtime.
- Provider-agnostic generation: any OpenAI-compatible endpoint, plus browser
  sign-in with an existing ChatGPT or Claude subscription.
- Cross-platform SwiftNIO HTTP/SSE/WebSocket transport shared by macOS, Linux,
  and Windows via WSL.
- Agentic workflows with a dependency-aware task graph (`/plan`, `/workflow`,
  `/review`) and capability-based delegation to sub-agents.
- `/bindings` command for agent model bindings.
- Granular `/tools` selection with file-change tracking and `/undo`.
- Dynamic Swift Features as durable tools, including bundled search, web,
  browser, Git, Swift, and Xcode feature executables.
- Selectable prompt skills, installable from GitHub or a local folder.

### Changed

- Removed local inference in favor of remote providers.
- Removed the dedicated Xcode agent profile.

[Unreleased]: https://github.com/gerardogrisolini/ZenCODE/compare/v2.1.2...HEAD
[2.1.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v2.1.1...v2.1.2
[2.1.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v2.1.0...v2.1.1
[2.1.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v2.0.1...v2.1.0
[2.0.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.3.0...v2.0.0
[1.3.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.6...v1.3.0
[1.2.6]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.5...v1.2.6
[1.2.5]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.4...v1.2.5
[1.2.4]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.3...v1.2.4
[1.2.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.4...v1.2.0
[1.1.4]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.3...v1.1.4
[1.1.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.2...v1.1.3
[1.1.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.1...v1.1.2
[1.1.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.11...v1.1.0
[1.0.11]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.10...v1.0.11
[1.0.10]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.8...v1.0.10
[1.0.8]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/gerardogrisolini/ZenCODE/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/gerardogrisolini/ZenCODE/releases/tag/v1.0.0
