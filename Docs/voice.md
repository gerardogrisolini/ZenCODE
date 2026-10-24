# Voice

ZenCODE has two voice features, both on macOS and Linux:

- **Voice mode** (`/voice`) in the interactive terminal: speak your prompts to
  any agent and hear the answers read aloud.
- **Telegram voice messages**: a voice note sent to the paired Telegram chat is
  transcribed and runs as an ordinary prompt.

Speech recognition and speech synthesis run on your machine: macOS uses the
system speech frameworks, Linux runs the sherpa-onnx programs downloaded from
`/setup` > **Voice mode**. The model provider never receives audio, only the
recognized text, exactly as if you had typed it.

The architecture and persistence contract behind this guide is in
[architecture.md](architecture.md#compatibility-contract).

## At a glance

| | macOS | Linux |
| --- | --- | --- |
| Speech recognition | Apple speech recognition, on-device when the language supports it | Parakeet TDT 0.6B v3 behind the Silero voice activity detector (sherpa-onnx), on the machine |
| Spoken answers | A system voice: the one chosen in `/setup` > Voice mode, or the best installed one | The Piper voice downloaded in `/setup` > Voice mode |
| Talking over an answer | Yes: echo cancellation keeps the microphone open, and speaking interrupts the reading | No: the microphone is off while an answer is read; `Esc` stops the reading |
| Download | Nothing | About 580 MB from `/setup` > Voice mode |
| Language | The response language, else the system language, else English | Recognized automatically among 25 European languages; answers are read in the language of the installed voice |
| Telegram voice messages | Apple speech recognition | The Voice mode files plus `opusdec` or `ffmpeg` |

## Voice mode in the terminal

### Commands

| Command | Effect |
| --- | --- |
| `/voice on` | Starts voice mode: listen to the microphone and read answers aloud. |
| `/voice off` | Stops voice mode. |
| `/voice pause` | Stops listening and stops reading answers aloud; voice mode stays on. |
| `/voice resume` | Listens and reads answers aloud again. |
| `/voice` | Pauses a listening voice mode, or resumes a paused one. |

`/voice` works with every agent profile and is available while a prompt is
running. It exists only in the interactive terminal: it is not a Telegram
command, and `zen -p`, `--jsonl` and ACP do not have it.

### A conversation

1. Run `/voice on`. On macOS the first start asks for the permissions (see
   [macOS](#macos)); on Linux the speech recognizer takes a few seconds to load
   (`Voice: loading the speech recognizer...`). ZenCODE confirms when it
   listens, for example:

   ```text
   Voice: listening (dictation, it_IT, on-device). Speak or type; answers are read aloud. /voice pauses or resumes, /voice off stops.
   ```

2. Speak. Recognized speech can appear in the prompt draft, the line you type
   in, while you talk (see [The prompt draft](#the-prompt-draft)). A pause of
   about 5 seconds (the pause chosen with the **Send mode** "After a pause" in
   `/setup` > Voice mode, see [Options](#options)) ends the utterance, which is
   sent as a prompt. With the Send mode "On a word", the pause does not send:
   you say your word (for example "vai" or "done") at the end instead, and can
   pause as long as you like before it. On Linux an utterance lasts at most 60
   seconds.
3. The draft is sent as a prompt: the typed text and the dictation together.
   Sent by voice, it is queued while a prompt is running, and it can answer a
   pending `/plan` clarification or `/goal` question. Text that would read as a
   slash command is always sent as a plain prompt: voice never runs `/exit` or
   any other command. Two kinds of utterance are not prompts: a yes or no while
   voice mode is asking you about a live-chat message, and a "message to …"
   phrase (see [Live chat by voice](#live-chat-by-voice)). Pressing `Enter`
   sends the draft by the keyboard rules instead. You can keep typing at any
   time.
4. The final answer of every completed turn is read aloud, including turns
   started from Telegram and the coordinator turns that report the results of
   delegated agents. Answers are read as plain text: Markdown markers are
   dropped, links are read by their text, URLs by their host name, table rows
   cell by cell, and every code block is replaced by a short notice such as
   "Code block omitted." (in English, Italian, Spanish, French, German or
   Portuguese, following the voice mode language). A new answer replaces the
   one being read. An answer longer than about 600 characters (some 40
   seconds of reading; the **Spoken answer limit** chosen in `/setup` > Voice
   mode, see [Options](#options)) is not read whole: after a short notice such
   as "Long answer, reading only the end." only its final sentences are read,
   since the end of an answer usually holds the outcome and the questions on
   how to continue. The terminal always shows the whole answer.
5. `Esc` stops the reading without clearing the draft. While a prompt is
   running, `Esc` stops both the generation and the reading.

`/voice pause` stops listening and reading aloud at once; answers that complete
while voice mode is paused are not read later.

### The prompt draft

While voice mode listens, the text recognized but not yet sent appears live at
the end of the prompt draft, the line you type in:

- **macOS** updates it word by word as you speak, in both Send modes.
  Dictation may correct earlier words while you keep speaking, so the draft can
  change slightly.
- **Linux** updates it one speech segment at a time, about a second after you
  stop, and only with the Send mode "On a word". With "After a pause" each
  segment is sent at once, so nothing is shown.

If the draft already holds typed text, the dictation is appended after it, with
a space. When voice sends, the whole draft you see goes out, typed text and
dictation together, without the word, and the draft is cleared. Saying the word
alone sends the draft as it stands; with an empty draft it does nothing. For
example, type `@reviewer ` and say "controlla il diff, vai": the message goes
to Reviewer as a live message.

- Sent by voice, the draft follows the voice rules: a "message to …" phrase
  or a leading `@` mention sends a live message, a yes or no answers a
  live-chat question, and text that starts with `/` is sent as a plain prompt.
  Sent with `Enter`, it follows the keyboard rules exactly as typed input:
  slash commands run, `@` mentions apply, and a "message to …" phrase is an
  ordinary prompt.
- `Enter` sends the draft, dictation included, and clears it. Voice mode forgets
  everything it had collected, so a later word does not send it again.
- Typing or editing while dictation is shown turns all of it into ordinary text.
  Voice mode forgets what it collected, and later speech is appended at the end
  of the draft. On macOS an edit made while you are speaking restarts
  recognition, so the words being spoken at that moment may be lost. Moving the
  cursor alone is not an edit.
- `Esc` clears the draft, dictation included, when no answer is being read and
  no prompt is running. While an answer is read or a prompt runs, `Esc` stops
  them as before and leaves the draft alone.
- A bare yes or no that answers a live-chat question is still sent at once on
  its own and does not touch the draft.
- `/voice pause` and `/voice off` drop the collected speech and remove its
  preview from the draft; typed text stays. Typing a command turns a
  dictation shown in the draft into ordinary text, so clear the draft with
  `Esc` first, or the command becomes part of the prompt.

### Live chat by voice

While delegated agents run, the coordinator and the agents write to the
[live agent chat](zen.md#live-agent-chat) shown in the dock at the bottom of the
terminal. With voice mode listening, the messages meant for you are also
handled by voice, one at a time.

**What is announced.** Only a new message from the coordinator or an agent that
names you among its recipients (`→ Operator` or `→ All`), sent while voice mode
listens. Traffic between the coordinator and the agents, and between agents,
stays silent in the dock; so does whatever arrived before voice mode started
or while it was paused, and the transcript replayed after `/resume` or a
reconnection. A message you already read in the dock is skipped.

**The dialogue.** Voice mode says, in its own language, something like
"New message from Reviewer, 2 more waiting. Do you want me to read it?" and
waits for your answer:

- **Yes** reads the whole message as plain text, however long it is (the
  spoken answer limit does not apply), then asks "Do you want
  to reply?". A second **yes** is followed by "Tell me your reply.": the next
  utterance goes to the sender (to the coordinator, or directly to the agent)
  and voice mode confirms "Sent.". **No** moves on to the next message waiting.
  A yes or no spoken while the message is still being read is taken as the
  answer to "Do you want to reply?" (on macOS it also stops the reading).
- **No** leaves the message unread in the dock and announces the next one.
- Anything else closes the question: the message stays unread, and the
  utterance is handled as usual, as a prompt or as a "message to …" phrase.
  After "Tell me your reply." or "Tell me the message.", though, the whole
  next utterance is the text, even one that starts with "message to …".
- Silence closes the question too: after 60 seconds without an answer the
  question lapses, the message stays unread, and the next one is announced.

The yes and no words are recognised in English, Italian, Spanish, French,
German and Portuguese whatever the voice language, without case, accents or
punctuation, and only when they are the whole utterance ("yes, but first…" is a
prompt):

| | Yes | No |
| --- | --- | --- |
| English | yes, yeah, yep, sure, ok, okay, please, yes please, go ahead, read it | no, nope, not now, later |
| Italian | sì, certo, va bene, d'accordo, ok, okay, leggi, leggilo, leggila | no, non ora, dopo |
| Spanish | sí, claro, vale, ok, léelo | no, ahora no, luego |
| French | oui, ouais, d'accord, ok, lis-le | non, pas maintenant, plus tard |
| German | ja, jawohl, klar, ok, okay, lies vor | nein, nicht jetzt, später |
| Portuguese | sim, claro, ok, pode ler | não, agora não, depois |

**Sending a message.** At any time, one phrase sends a live message without a
question: the recipient, an optional `:` `,` `.` or `-`, and the text. The
coordinator and the broadcast are reserved words and win over an agent with the
same name; any other name must be the name of an active agent, matched without
case or accents and with any punctuation between its words ("parser reviewer"
reaches `parser-reviewer`); otherwise voice mode says "No active agent is
named …". Without a text, voice mode asks "Tell me the message." and the next
utterance is the text.

| Language | Examples |
| --- | --- |
| English | "message to the coordinator: stop", "send a message to all, take a break", "message to Reviewer: check the diff" |
| Italian | "messaggio al coordinatore: fermati", "manda un messaggio a tutti, pausa", "messaggio a Reviewer: controlla il diff" |
| Spanish | "mensaje al coordinador: para", "envía un mensaje a todos, pausa", "mensaje a Reviewer: revisa el diff" |
| French | "message au coordinateur : arrête", "envoie un message à tous, pause", "message à Reviewer : vérifie le diff" |
| German | "Nachricht an den Koordinator: stopp", "sende eine Nachricht an alle, Pause", "Nachricht an Reviewer: prüfe den Diff" |
| Portuguese | "mensagem ao coordenador: para", "envia uma mensagem para todos, pausa", "mensagem para Reviewer: verifica o diff" |

Voice mode confirms "Sent." or says "Sending failed." (the terminal shows the
reason). A sent message is not a prompt: no turn starts for it.

**Queue and precedence.** Announcements never interrupt an answer being read:
they follow it. The other way round, an answer that completes while the
dialogue is in progress is read first. A "Do you want me to read it?" question
is then asked again; a message already being read, or whose "Do you want to
reply?" was not answered, is dropped (you can still write to its sender with a
"message to …" phrase); after "Tell me your reply." or "Tell me the message."
the text is still awaited once the answer is over. At most 32 messages wait to
be announced; older ones are dropped.

**Dock and keyboard.** Reading a message aloud marks it as read in the dock,
exactly like opening it there; a declined or lapsed question leaves it unread.
Typed input is never intercepted: a typed `yes` is a prompt. A bare yes or no
that answers the question is sent at once on its own and does not touch the
draft. `Esc`, `/voice pause`, `/voice off`, `/new` and `/resume` drop the
pending question and every queued announcement, with no catch-up later.

### How long voice mode lasts

Voice mode belongs to the current terminal session. It does not depend on the
active agent and stays on across `/agents` and `/sessions` switches. It ends
with `/voice off` or `/exit`, and also when `/setup` opens: run `/voice on`
again after setup. It is never saved, so every new `zen` starts with voice mode
off.

### Options

The first two items of `/setup` > **Voice mode**, on macOS and Linux alike,
tune how voice mode listens and reads. The pause and the limit open a list of
presets with the current value preselected and the default marked; **Back** or
`Esc` keeps the current value, and after a choice the Voice mode menu comes
back so the voice can still be chosen.

- **Send mode** — how voice mode decides that you finished speaking:
  - **After a pause** (default): the silence after you stop speaking ends the
    utterance and sends it as a prompt. Choosing it goes on to the pause: 2,
    3, **5** (default), 8 or 10 seconds. A longer pause lets you think
    mid-sentence without sending half a prompt; a shorter one answers faster.
    **Back** or `Esc` in the list keeps the current send mode.
  - **On a word**: you type one word (no default; for example `vai`, `done`,
    `fatto`), and from then on the utterance is sent only when what you say
    ends with that word, which is removed from the prompt: "cerca il file,
    vai" sends "cerca il file". Silence never sends, so you can think
    mid-sentence for as long as you like; everything recognized meanwhile is
    shown in the draft (see [The prompt draft](#the-prompt-draft)) and sent
    together once you say the word. The word alone sends the whole draft, typed
    text included; with an empty draft it does nothing. The same word in the
    middle of a sentence is ordinary text. It is compared without case, accents
    or punctuation. A spoken yes or no (see
    [Live chat by voice](#live-chat-by-voice)) cannot be the word, and while
    voice mode is asking you about a live-chat message a bare yes or no is sent
    at once, without the word. `Esc` at the word prompt keeps the current send
    mode; going back to "After a pause" keeps the word for later. On macOS the
    word takes effect about half a second after it is recognized; on Linux at
    the end of the current speech segment, about a second after you stop. This
    mode asks for no pause.
- **Spoken answer limit** — the length past which an answer is read from its
  final sentences only, after the "Long answer" notice: 300, **600** (default),
  1000 or 2000 characters, or **whole answer** to always read everything.

All are saved with the other settings when setup finishes
(`voice.sendMode` as `pause` or `keyword`, `voice.sendKeyword`,
`voice.utteranceSilenceSeconds` and `voice.maximumSpokenCharacters` in
`settings.json`, where `0` means whole answer) and apply the next time
`/voice on` starts. The main setup menu shows a value that differs from the
default next to the Voice mode status, for example `automatic voice · send on
“vai” · whole answer`.

### macOS

- **Permissions.** The first `/voice on` asks macOS to let your terminal app use
  the **Microphone** and **Speech Recognition**. If you denied them, allow the
  terminal app under *System Settings > Privacy & Security > Microphone* and
  *Speech Recognition*, then run `/voice on` again.
- **Recognition.** Apple speech recognition runs on-device when the language
  supports it, otherwise on Apple servers. The start message says which:
  `on-device` or `Apple servers`.
- **Echo cancellation.** Capture and playback share one audio engine with
  system echo cancellation, so the microphone stays open while an answer is
  read and speaking interrupts the reading. A residual-echo filter also discards
  recognized text that repeats the answer being read, so the assistant neither
  interrupts nor answers itself. When the current output cannot run echo
  cancellation, for example an AirPlay device, voice mode starts without it and
  names the output: switch to a local output or use headphones.
- **Reading voice.** `/setup` > **Voice mode** downloads nothing on macOS.
  After the three [options](#options) it lists the system voices installed for
  the voice mode language, with name and
  quality (standard, enhanced or premium), plus **Automatic**: the best
  installed voice of the exact locale, else of another region of the language.
  Choosing a voice, or Automatic while a voice of the language is installed,
  opens a submenu:
  - **▶ Listen** reads a short sample that says the voice's name, while the
    menu stays usable. A new sample, or leaving the submenu, stops the one
    playing. The sample uses no microphone and is never saved.
  - **Use this voice** applies the choice.
  - **Back** returns to the list unchanged.

  The choice is saved when setup finishes and applies the next time `/voice on`
  starts. Add voices under *System Settings > Accessibility > Spoken Content >
  System voice > Manage Voices*. Siri voices are not available to other apps
  and are not listed. A saved voice that is no longer installed, or that reads
  another language, falls back to Automatic.

### Linux

Requirements:

- An x86_64 or arm64 processor: sherpa-onnx publishes prebuilt programs only
  for these.
- `tar` and `bzip2` to unpack the downloads.
- ALSA (`libasound.so.2`) with a working `default` capture and playback device.
  The recognizer listens and the voice plays on that device.
- About 580 MB of disk space.

Telegram voice messages need no audio device, so a headless machine such as a
Raspberry Pi can transcribe them.

Download the files from `/setup` > **Voice mode**:

1. The section shows where the files go and their status (`not installed`,
   `incomplete download`, or the installed voice), then, after the three
   [options](#options), lists the Piper voices
   of the voice mode language with locale, quality and size. When no voice
   reads that language, every voice is listed. The catalogue has 127 voices in
   25 locales.
2. Choosing a voice lists what is missing and its total size, and asks for
   confirmation:
   - the sherpa-onnx v1.13.8 programs (about 28 MB);
   - the Parakeet TDT 0.6B v3 speech recognition model (about 487 MB);
   - the Silero voice activity detector (under 1 MB);
   - the voice (tens of MB, shown in the list).
3. Each file is downloaded from the sherpa-onnx GitHub releases and checked
   against its pinned size and SHA-256 checksum. It is then unpacked in a
   staging directory and moved into place only when complete: a failed download
   installs nothing incomplete, and choosing the voice again retries.

Exactly one voice is kept: choosing another one replaces it without downloading
the shared files again. **Remove voice mode files** deletes everything. The
section acts immediately: downloads are not part of the settings that **Finish
setup** saves, and cancelling setup does not undo them. The three options, on the
other hand, are settings: they are saved by **Finish setup** like on macOS.

While voice mode runs, `sherpa-onnx-vad-alsa-offline-asr` listens and
`sherpa-onnx-offline-tts-play-alsa` reads each answer, as separate processes.
Without echo cancellation the microphone is off while an answer is read. It
turns back on when the reading ends or `Esc` stops it.

## Language

The voice language is not a separate setting. It follows the **Response
language** chosen in `/setup`, else the system language, else English. A change
applies the next time `/voice on` starts and to the next Telegram voice message.

- **macOS** listens and reads in that language. Common codes map to a region
  (`it` → `it-IT`, `en` → `en-US`, `es` → `es-ES`, `fr` → `fr-FR`, `de` → `de-DE`,
  `pt` → `pt-BR`, `ja` → `ja-JP`, `ko` → `ko-KR`, `zh` → `zh-CN`, `ru` → `ru-RU`);
  other codes are used as they are. The reading voice must read the same
  language.
- **Linux** recognizes the spoken language by itself among the 25 European
  languages of Parakeet. Answers are read in the language of the installed
  voice. The response language only selects the voices that `/setup` > Voice
  mode lists first, so pick a voice of the language your answers are written in.

Earlier versions saved a fixed `voice.language` (`"it"`) when Telegram was set
up, and it overrode the response language. That key is now ignored and is
removed the next time the settings are saved.

## Telegram voice messages

When Telegram remote control is configured in `/setup`, voice-message
transcription is on, on macOS and on Linux. The setup summary shows
`Voice-message transcription: enabled`.

Record a voice note in the paired chat or topic. ZenCODE downloads it (up to
20 MB) and transcribes it on the machine while the chat shows ZenCODE typing.
The transcript then runs as an ordinary prompt and is queued while another
prompt runs. Up to three voice notes are transcribed at once; more are refused
with *Too many voice messages are being transcribed. Try again shortly.* A
voice note that replies to a live message card is refused, because answers to
live cards must be typed. Voice mode does not need to be on.

- **macOS** uses Apple speech recognition in the voice language and asks for
  the Speech Recognition permission. The system may use Apple servers for better
  accuracy.
- **Linux** uses the files of `/setup` > Voice mode, with any voice installed.
  It also needs one of these decoders in `/usr/bin`, `/bin` or `/usr/local/bin`:
  - `opusdec` (package `opus-tools`), preferred for Telegram voice notes, which
    are Ogg Opus;
  - `ffmpeg`, used when `opusdec` is missing or the audio is in another format,
    and also when `opusdec` fails on the file, for example an `.ogg` that holds
    Vorbis rather than Opus. The file is then decoded again from scratch. If
    `ffmpeg` fails too, the message gives both reasons; if it is not installed,
    the `opusdec` reason is reported.

  The note is decoded into a temporary 16 kHz mono WAV file.
  `sherpa-onnx-vad-with-offline-asr` splits it on silences and recognizes each
  part with Parakeet, which detects the language by itself.

Settings saved by an earlier version on Linux have transcription off. A voice
note then gets the reply *Voice-message transcription is off*. To turn it on,
open the Telegram section of `/setup` again; you can keep the current pairing.

## Privacy and storage

- Audio never reaches the model provider: only the recognized text is sent, as
  a prompt.
- Voice mode never writes microphone or synthesized audio to disk, and the
  recognizer's partial results are never saved. On Linux, the mandatory WAV
  output of the synthesizer is pointed at `/dev/null`.
- Dictated and transcribed prompts are part of the conversation, like typed
  prompts, and are saved with the session.
- A Telegram voice note is downloaded to a private temporary file (mode `0600`)
  that is deleted after transcription. On Linux it is decoded into a private
  temporary directory (mode `0700`), deleted when the transcription ends,
  including after a failure or cancellation.
- On macOS, speech recognition can use Apple servers: in voice mode only when
  the language has no on-device recognition, as the start message reports.
- `settings.json` keeps a `voice` object only while something is set: `enabled`
  turns on Telegram voice-message transcription, and `macOSVoiceIdentifier` is
  the macOS reading voice.
- The Linux files live in `~/.zencode/voice/`, or in `voice/` under
  `ZENCODE_SUPPORT_DIRECTORY`. They are re-downloadable programs and models:
  a **Data management** export skips them. An import replaces the whole support
  directory, so download the files again afterwards.

## Troubleshooting

| Message or symptom | What to do |
| --- | --- |
| `microphone access is not granted` | macOS: allow the terminal app under *Privacy & Security > Microphone*, then `/voice on`. |
| `speech recognition is not allowed` | macOS: allow the terminal app under *Privacy & Security > Speech Recognition*, then `/voice on`. |
| `echo cancellation is unavailable with the current audio output (…)` | macOS: switch to a local output or use headphones, so the assistant does not hear itself. |
| `speech recognition stopped repeatedly` | Run `/voice on` to retry. On Linux, check the audio device. |
| `Voice mode files are not installed` | Linux: download them from `/setup` > Voice mode. |
| `… does not contain the expected files` | Linux: choose the voice again in `/setup` > Voice mode, or remove the files and download them again. |
| `No prebuilt sherpa-onnx programs exist for this processor architecture` | Linux voice features need x86_64 or arm64. |
| `The tar program is required…` / `The bzip2 program is required…` | Install the missing program with your package manager and choose the voice again. |
| `speech recognition could not start: … Unable to open: default` | Linux: ALSA has no usable default device. List the devices with `arecord -l` and configure the default one, for example in `~/.asoundrc`. |
| `the answer could not be read aloud: …` | Linux: the voice could not play; check the ALSA playback device, or reinstall the voice. |
| Telegram: `Voice-message transcription is off` | Open the Telegram section of `/setup` again; you can keep the current pairing. |
| Telegram: `Transcribing voice messages needs opusdec (package opus-tools) or ffmpeg` | Linux: install one, for example `sudo apt install opus-tools`. |
| `/voice is available only in the interactive terminal` | Run `/voice` from the `zen` terminal UI. |
| An utterance is never sent | Pause for about 5 seconds after speaking (or the pause chosen with the Send mode "After a pause" in `/setup` > Voice mode), and reduce background noise. With the Send mode "On a word", say your word at the end. |
| An utterance is sent before you finish | Choose the Send mode "After a pause" with a longer pause in `/setup` > Voice mode, or "On a word" so that only your word sends. |
| Answers are read in the wrong language | Set the Response language in `/setup`; on Linux, also choose a voice of that language in `/setup` > Voice mode. |
