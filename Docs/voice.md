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

2. Speak. A pause of about 2.5 seconds ends the utterance, which is sent as a
   prompt. On Linux an utterance lasts at most 60 seconds.
3. The utterance is handled exactly like a line you type and press `Enter` on:
   while a prompt is running it is queued, and it can answer a pending `/plan`
   clarification or `/goal` question. Text that would read as a slash command is
   always sent as a plain prompt: voice never runs `/exit` or any other command.
   You can keep typing at any time.
4. The final answer of every completed turn is read aloud, including turns
   started from Telegram and the coordinator turns that report the results of
   delegated agents. Answers are read as plain text: Markdown markers are
   dropped, links are read by their text, URLs by their host name, table rows
   cell by cell, and every code block is replaced by a short notice such as
   "Code block omitted." (in English, Italian, Spanish, French, German or
   Portuguese, following the voice mode language). A new answer replaces the
   one being read. An answer longer than about 600 characters (some 40
   seconds of reading) is not read whole: after a short notice such as "Long
   answer, reading only the end." only its final sentences are read, since the
   end of an answer usually holds the outcome and the questions on how to
   continue. The terminal always shows the whole answer.
5. `Esc` stops the reading without clearing the draft. While a prompt is
   running, `Esc` stops both the generation and the reading.

`/voice pause` stops listening and reading aloud at once; answers that complete
while voice mode is paused are not read later.

### How long voice mode lasts

Voice mode belongs to the current terminal session. It does not depend on the
active agent and stays on across `/agents` and `/sessions` switches. It ends
with `/voice off` or `/exit`, and also when `/setup` opens: run `/voice on`
again after setup. It is never saved, so every new `zen` starts with voice mode
off.

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
- **Reading voice.** `/setup` > **Voice mode** downloads nothing on macOS. It
  lists the system voices installed for the voice mode language, with name and
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
   `incomplete download`, or the installed voice), then lists the Piper voices
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
setup** saves, and cancelling setup does not undo them.

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
  - `ffmpeg`, used when `opusdec` is missing or the audio is in another format.

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
| An utterance is never sent | Pause for about 2.5 seconds after speaking, and reduce background noise. |
| Answers are read in the wrong language | Set the Response language in `/setup`; on Linux, also choose a voice of that language in `/setup` > Voice mode. |
