//
//  ZenCronJobCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Cron job command")
struct ZenCronJobCommandTests {
    /// `outputFormat` defaults to `.jsonl`: most cases below pin the grammar of
    /// lines written before the text format existed, which must keep working.
    private func makeJob(
        executable: String = "zen",
        supportDirectory: String? = nil,
        agentName: String? = nil,
        workingDirectory: String = "/Users/me/project",
        outputFormat: ZenCronJobCommand.OutputFormat = .jsonl,
        promptFile: String? = nil,
        prompt: String? = "summarize the repo"
    ) -> ZenCronJobCommand {
        ZenCronJobCommand(
            executable: executable,
            supportDirectory: supportDirectory,
            agentName: agentName,
            workingDirectory: workingDirectory,
            outputFormat: outputFormat,
            promptFile: promptFile,
            prompt: prompt
        )
    }

    // MARK: - encode

    @Test
    func encodesMinimalCommandWithABareZenInFixedOrder() {
        #expect(
            makeJob().encode()
                == "zen --working-directory '/Users/me/project' --jsonl -p 'summarize the repo'"
        )
    }

    @Test
    func encodesATextJobWithoutTheJSONLFlag() {
        #expect(
            makeJob(outputFormat: .text).encode()
                == "zen --working-directory '/Users/me/project' -p 'summarize the repo'"
        )
        let full = makeJob(
            supportDirectory: "/Users/me/.zencode",
            agentName: "reviewer",
            outputFormat: .text,
            prompt: "hello"
        )
        #expect(
            full.encode()
                == "ZENCODE_SUPPORT_DIRECTORY='/Users/me/.zencode' zen --agent 'reviewer' "
                + "--working-directory '/Users/me/project' -p 'hello'"
        )
    }

    @Test
    func encodesAnyOtherExecutableSingleQuoted() {
        #expect(
            makeJob(executable: "/usr/local/bin/zen").encode()
                == "'/usr/local/bin/zen' --working-directory '/Users/me/project' --jsonl -p 'summarize the repo'"
        )
        // Only the exact word `zen` is bare.
        #expect(makeJob(executable: "Zen").encode().hasPrefix("'Zen' "))
        #expect(makeJob(executable: "zen ").encode().hasPrefix("'zen ' "))
        #expect(makeJob(executable: "").encode().hasPrefix("'' "))
    }

    @Test
    func encodesAllOptionalPartsInFixedOrder() {
        let job = makeJob(
            supportDirectory: "/Users/me/.zencode",
            agentName: "reviewer",
            prompt: "hello"
        )
        #expect(
            job.encode()
                == "ZENCODE_SUPPORT_DIRECTORY='/Users/me/.zencode' zen --agent 'reviewer' "
                + "--working-directory '/Users/me/project' --jsonl -p 'hello'"
        )
    }

    @Test
    func encodesSingleQuotesAsCloseEscapeReopen() {
        let job = makeJob(prompt: "it's a 'test'")
        #expect(job.encode().hasSuffix("-p 'it'\\''s a '\\''test'\\'''"))
    }

    // MARK: - encode with a prompt file

    @Test
    func encodesAPromptFileAloneWithoutAnyPromptFlag() {
        let job = makeJob(outputFormat: .text, promptFile: "/Users/me/prompts/daily.md", prompt: nil)
        #expect(
            job.encode()
                == "zen --working-directory '/Users/me/project' -f '/Users/me/prompts/daily.md'"
        )
        #expect(!job.encode().contains(" -p "))
    }

    @Test
    func encodesAPromptFileBeforeThePromptThatInstructsIt() {
        let job = makeJob(
            outputFormat: .text,
            promptFile: "/Users/me/prompts/daily.md",
            prompt: "summarize it"
        )
        #expect(
            job.encode()
                == "zen --working-directory '/Users/me/project' -f '/Users/me/prompts/daily.md' -p 'summarize it'"
        )
    }

    @Test
    func encodesTheJSONLFlagBeforeThePromptFile() {
        let fileOnly = makeJob(outputFormat: .jsonl, promptFile: "/p/daily.md", prompt: nil)
        #expect(fileOnly.encode() == "zen --working-directory '/Users/me/project' --jsonl -f '/p/daily.md'")

        let both = makeJob(outputFormat: .jsonl, promptFile: "/p/daily.md", prompt: "summarize it")
        #expect(
            both.encode()
                == "zen --working-directory '/Users/me/project' --jsonl -f '/p/daily.md' -p 'summarize it'"
        )
    }

    @Test
    func encodesAPromptFileAfterEveryOptionalPart() {
        let job = makeJob(
            supportDirectory: "/Users/me/.zencode",
            agentName: "reviewer",
            outputFormat: .jsonl,
            promptFile: "/p/daily.md",
            prompt: "hello"
        )
        #expect(
            job.encode()
                == "ZENCODE_SUPPORT_DIRECTORY='/Users/me/.zencode' zen --agent 'reviewer' "
                + "--working-directory '/Users/me/project' --jsonl -f '/p/daily.md' -p 'hello'"
        )
    }

    @Test
    func encodesAJobWithoutAPromptFileExactlyAsBeforeThatOptionExisted() {
        // Same bytes as the lines already on users' crontabs.
        #expect(
            makeJob(promptFile: nil).encode()
                == "zen --working-directory '/Users/me/project' --jsonl -p 'summarize the repo'"
        )
        #expect(
            makeJob(outputFormat: .text, promptFile: nil).encode()
                == "zen --working-directory '/Users/me/project' -p 'summarize the repo'"
        )
        #expect(!makeJob(outputFormat: .text).encode().contains(" -f "))
    }

    @Test
    func encodesQuotesInAPromptFilePath() {
        let job = makeJob(outputFormat: .text, promptFile: "/Users/me/it's here/a b.md", prompt: nil)
        #expect(job.encode().hasSuffix(" -f '/Users/me/it'\\''s here/a b.md'"))
    }

    @Test
    func keepsShellMetacharactersInertInsideSingleQuotes() {
        let job = makeJob(prompt: "echo $HOME `id` \"x\" \\n ; rm -rf * | cat &")
        #expect(job.encode().hasSuffix("-p 'echo $HOME `id` \"x\" \\n ; rm -rf * | cat &'"))
    }

    // MARK: - round trip

    @Test(arguments: [
        "plain prompt",
        "",
        "it's",
        "'",
        "''",
        "'leading and trailing'",
        "two  spaces   and\ttab",
        "100% sure, 50%% more, %",
        "backslash \\ and \\% and \\\\%",
        "quote then combining mark '\u{0301}x",
        "unicode \u{1F600} \u{00E8}",
        "$(touch /tmp/x) `id` ${HOME}",
        "--agent 'x' --jsonl -p 'y'"
    ])
    func roundTripsPromptsThroughEncodeAndDecode(_ prompt: String) {
        for outputFormat in [ZenCronJobCommand.OutputFormat.text, .jsonl] {
            let job = makeJob(
                supportDirectory: "/tmp/with space/and'quote",
                agentName: "agent with 'quotes'",
                outputFormat: outputFormat,
                prompt: prompt
            )
            #expect(ZenCronJobCommand.decode(job.encode()) == job)
        }
    }

    @Test
    func roundTripsEachOutputFormatToItself() {
        for outputFormat in [ZenCronJobCommand.OutputFormat.text, .jsonl] {
            let job = makeJob(outputFormat: outputFormat)
            #expect(ZenCronJobCommand.decode(job.encode())?.outputFormat == outputFormat)
        }
    }

    @Test
    func roundTripsMinimalAndPathsWithSpacesAndQuotes() {
        let minimal = makeJob(
            executable: "/Applications/My Apps/zen's/zen",
            workingDirectory: "/Users/me/it's here/proj ect"
        )
        #expect(ZenCronJobCommand.decode(minimal.encode()) == minimal)

        let emptySupport = makeJob(supportDirectory: "")
        #expect(ZenCronJobCommand.decode(emptySupport.encode()) == emptySupport)
    }

    @Test(arguments: [
        "50% done",
        "100%% \\% mix",
        "%",
        "\\%",
        "\\\\%",
        "no percent at all"
    ])
    func roundTripsThroughCronPercentEscaping(_ prompt: String) throws {
        for outputFormat in [ZenCronJobCommand.OutputFormat.text, .jsonl] {
            let job = makeJob(outputFormat: outputFormat, prompt: prompt)
            let onCronLine = ZenCronJobCommand.cronEscape(job.encode())
            let unescaped = try #require(ZenCronJobCommand.cronUnescape(onCronLine))
            #expect(ZenCronJobCommand.decode(unescaped) == job)
        }
    }

    @Test
    func roundTripsTheBareZenAndAQuotedPathAlike() {
        for executable in ["zen", "/usr/local/bin/zen", "/opt/my apps/zen", "relative/zen", "it's"] {
            let job = makeJob(
                executable: executable,
                supportDirectory: "/s",
                agentName: "a",
                prompt: "100% it's 'quoted' \\% done"
            )
            #expect(ZenCronJobCommand.decode(job.encode()) == job)

            let onCronLine = ZenCronJobCommand.cronEscape(job.encode())
            #expect(ZenCronJobCommand.cronUnescape(onCronLine).flatMap(ZenCronJobCommand.decode) == job)
        }
    }

    // MARK: - round trip with a prompt file

    @Test(arguments: [
        "/Users/me/prompts/daily.md",
        "/Users/me/My Prompts/daily report.md",
        "/Users/me/it's here/a'b.md",
        "/Users/me/'quoted'/x",
        "/Users/me/\"double\"/x",
        "/tmp/100% done/50%% off.md",
        "/tmp/back\\slash/\\%/x.md",
        "/tmp/--jsonl -p 'y'/x.md",
        "/tmp/quote then combining mark '\u{0301}x.md",
        "/tmp/unicode \u{1F600} \u{00E8}.md",
        "/tmp/$(touch x) `id` ${HOME}.md"
    ])
    func roundTripsEveryShapeOfAPromptFile(_ path: String) throws {
        let shapes: [(file: String?, prompt: String?)] = [
            (path, nil),
            (path, "summarize it"),
            (path, "100% it's 'quoted'"),
            (path, ""),
            (nil, "summarize it")
        ]
        for outputFormat in [ZenCronJobCommand.OutputFormat.text, .jsonl] {
            for shape in shapes {
                let job = makeJob(
                    supportDirectory: "/tmp/with space/and'quote",
                    agentName: "agent with 'quotes'",
                    outputFormat: outputFormat,
                    promptFile: shape.file,
                    prompt: shape.prompt
                )
                #expect(ZenCronJobCommand.decode(job.encode()) == job)

                // Through the crontab line: `%` must survive cron's escaping.
                let onCronLine = ZenCronJobCommand.cronEscape(job.encode())
                let unescaped = try #require(ZenCronJobCommand.cronUnescape(onCronLine))
                #expect(ZenCronJobCommand.decode(unescaped) == job)
            }
        }
    }

    @Test
    func cronEscapesAPercentInAPromptFilePath() {
        let job = makeJob(outputFormat: .text, promptFile: "/tmp/100% done.md", prompt: nil)
        #expect(ZenCronJobCommand.cronEscape(job.encode()).hasSuffix(" -f '/tmp/100\\% done.md'"))
    }

    @Test
    func roundTripsEachShapeToItself() {
        let fileOnly = ZenCronJobCommand.decode(
            makeJob(outputFormat: .text, promptFile: "/p/a.md", prompt: nil).encode()
        )
        #expect(fileOnly?.promptFile == "/p/a.md")
        #expect(fileOnly?.prompt == nil)
        #expect(fileOnly?.outputFormat == .text)

        let both = ZenCronJobCommand.decode(
            makeJob(outputFormat: .jsonl, promptFile: "/p/a.md", prompt: "go").encode()
        )
        #expect(both?.promptFile == "/p/a.md")
        #expect(both?.prompt == "go")
        #expect(both?.outputFormat == .jsonl)

        let promptOnly = ZenCronJobCommand.decode(makeJob(outputFormat: .text).encode())
        #expect(promptOnly?.promptFile == nil)
        #expect(promptOnly?.prompt == "summarize the repo")
    }

    // MARK: - decode rejections

    @Test(arguments: [
        "",
        "zen",
        "echo hello",
        // unquoted executable other than the bare `zen`
        "/usr/local/bin/zen --working-directory '/w' --jsonl -p 'x'",
        "zenith --working-directory '/w' --jsonl -p 'x'",
        "ls --working-directory '/w' --jsonl -p 'x'",
        "ZEN --working-directory '/w' --jsonl -p 'x'",
        "zen/zen --working-directory '/w' --jsonl -p 'x'",
        "echo --working-directory '/w' --jsonl -p 'x'",
        "zen'x' --working-directory '/w' --jsonl -p 'x'",
        "zen--working-directory '/w' --jsonl -p 'x'",
        "zen  --working-directory '/w' --jsonl -p 'x'",
        "zen \"zen\" --working-directory '/w' --jsonl -p 'x'",
        "zen --jsonl -p 'x'",
        "ZENCODE_SUPPORT_DIRECTORY='/s' ls --working-directory '/w' --jsonl -p 'x'",
        // missing pieces
        "'/z' --jsonl -p 'x'",
        "'/z' --working-directory '/w'",
        "'/z' --working-directory '/w' --jsonl",
        "'/z' --working-directory '/w' --jsonl -p",
        "'/z' --working-directory '/w' -p",
        "'/z' --working-directory '/w' -p ",
        // wrong order
        "'/z' --jsonl --working-directory '/w' -p 'x'",
        "'/z' --jsonl --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --agent 'a' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --agent 'a' -p 'x'",
        "'/z' --working-directory '/w' -p 'x' --jsonl",
        "'/z' --working-directory '/w' -p --jsonl 'x'",
        "'/z' --working-directory '/w' -p 'x' -p 'y'",
        "'/z' --working-directory '/w' --jsonl -p 'x' --jsonl",
        "'/z' --agent 'a' --agent 'b' --working-directory '/w' --jsonl -p 'x'",
        "'/z' --model 'm' --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p 'x' --extra",
        // unquoted values
        "'/z' --agent a --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory /w --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p x",
        "'/z' --working-directory '/w' -p x",
        // environment prefix variations
        "ZENCODE_SUPPORT_DIRECTORY=/s '/z' --working-directory '/w' --jsonl -p 'x'",
        "ZENCODE_SUPPORT_DIRECTORY='/s''/z' --working-directory '/w' --jsonl -p 'x'",
        "ZENCODE_SUPPORT_DIRECTORY='/s'  '/z' --working-directory '/w' --jsonl -p 'x'",
        "OTHER='/s' '/z' --working-directory '/w' --jsonl -p 'x'",
        "'/z' ZENCODE_SUPPORT_DIRECTORY='/s' --working-directory '/w' --jsonl -p 'x'",
        // spacing
        "'/z'  --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p 'x' ",
        " '/z' --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w'\t--jsonl -p 'x'",
        "'/z' --working-directory '/w'  --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl  -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p  'x'",
        "'/z' --working-directory '/w'  -p 'x'",
        "'/z' --working-directory '/w' -p  'x'",
        "'/z' --working-directory '/w' -p 'x' ",
        "'/z' --working-directory '/w'\t-p 'x'",
        "'/z' --working-directory '/w' --jsonl\t-p 'x'",
        "'/z' --working-directory '/w' --JSONL -p 'x'",
        "'/z' --working-directory '/w' --jsonl=true -p 'x'",
        // quoting defects
        "'/z' --working-directory '/w' --jsonl -p 'unterminated",
        "'/z' --working-directory '/w' --jsonl -p 'a''b'",
        "'/z' --working-directory '/w' --jsonl -p 'a'\\'",
        "'/z' --working-directory '/w' --jsonl -p 'a'\\' b",
        "\"/z\" --working-directory '/w' --jsonl -p 'x'",
        "'/z' --working-directory '/w' --jsonl -p \"x\"",
        "'/z' --working-directory '/w' -p \"x\"",
        "'/z' --working-directory '/w' -p 'a''b'",
        "'/z' --working-directory '/w' -p 'unterminated",
        // line breaks never fit on one crontab line
        "'/z' --working-directory '/w' --jsonl -p 'two\nlines'",
        "'/z' --working-directory '/w' --jsonl -p 'carriage\rreturn'",
        "'/z' --working-directory '/w' --jsonl -p 'x'\n",
        "'/z' --working-directory '/w' -p 'two\nlines'",
        "'/z' --working-directory '/w' -p 'x'\n"
    ])
    func decodeReturnsNilOutsideTheFixedGrammar(_ command: String) {
        #expect(ZenCronJobCommand.decode(command) == nil)
    }

    @Test
    func decodeAcceptsABareZen() {
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' --jsonl -p 'x'")
                == makeJob(workingDirectory: "/w", prompt: "x")
        )
        #expect(
            ZenCronJobCommand.decode(
                "ZENCODE_SUPPORT_DIRECTORY='/s' zen --agent 'a' --working-directory '/w' --jsonl -p 'x'"
            ) == makeJob(
                supportDirectory: "/s",
                agentName: "a",
                workingDirectory: "/w",
                prompt: "x"
            )
        )
    }

    @Test
    func decodeReadsALineWithTheJSONLFlagAsJSONL() {
        // Lines written before the text format existed always carry `--jsonl`.
        let decoded = ZenCronJobCommand.decode(
            "ZENCODE_SUPPORT_DIRECTORY='/s' zen --agent 'a' --working-directory '/w' --jsonl -p 'x'"
        )
        #expect(decoded?.outputFormat == .jsonl)
        #expect(decoded?.prompt == "x")
    }

    @Test
    func decodeReadsALineWithoutTheJSONLFlagAsText() {
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' -p 'x'")
                == makeJob(workingDirectory: "/w", outputFormat: .text, prompt: "x")
        )
        #expect(
            ZenCronJobCommand.decode(
                "ZENCODE_SUPPORT_DIRECTORY='/s' '/z' --agent 'a b' --working-directory '/w' -p 'it'\\''s'"
            ) == makeJob(
                executable: "/z",
                supportDirectory: "/s",
                agentName: "a b",
                workingDirectory: "/w",
                outputFormat: .text,
                prompt: "it's"
            )
        )
        // A prompt that merely looks like the flag stays prompt text.
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' -p '--jsonl -p x'")
                == makeJob(workingDirectory: "/w", outputFormat: .text, prompt: "--jsonl -p x")
        )
    }

    @Test
    func decodeAcceptsAPromptFileWithAndWithoutAPromptInEitherOutputFormat() {
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' -f '/p/a b.md'")
                == makeJob(workingDirectory: "/w", outputFormat: .text, promptFile: "/p/a b.md", prompt: nil)
        )
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' -f '/p/a.md' -p 'go'")
                == makeJob(workingDirectory: "/w", outputFormat: .text, promptFile: "/p/a.md", prompt: "go")
        )
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' --jsonl -f '/p/a.md'")
                == makeJob(workingDirectory: "/w", outputFormat: .jsonl, promptFile: "/p/a.md", prompt: nil)
        )
        #expect(
            ZenCronJobCommand.decode(
                "ZENCODE_SUPPORT_DIRECTORY='/s' '/z' --agent 'a' --working-directory '/w' --jsonl -f '/p/a.md' -p 'go'"
            ) == makeJob(
                executable: "/z",
                supportDirectory: "/s",
                agentName: "a",
                workingDirectory: "/w",
                outputFormat: .jsonl,
                promptFile: "/p/a.md",
                prompt: "go"
            )
        )
    }

    @Test
    func decodeKeepsEveryLineWrittenWithoutAPromptFileAsBefore() {
        let jsonl = ZenCronJobCommand.decode("zen --working-directory '/w' --jsonl -p 'x'")
        #expect(jsonl == makeJob(workingDirectory: "/w", prompt: "x"))
        #expect(jsonl?.promptFile == nil)

        let text = ZenCronJobCommand.decode("zen --working-directory '/w' -p 'x'")
        #expect(text == makeJob(workingDirectory: "/w", outputFormat: .text, prompt: "x"))
        #expect(text?.promptFile == nil)

        // An empty prompt was a valid quoted word before and still is.
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' -p ''")
                == makeJob(workingDirectory: "/w", outputFormat: .text, prompt: "")
        )
        // A prompt that merely looks like the option stays prompt text.
        #expect(
            ZenCronJobCommand.decode("zen --working-directory '/w' -p '-f /etc/passwd'")
                == makeJob(workingDirectory: "/w", outputFormat: .text, prompt: "-f /etc/passwd")
        )
    }

    @Test(arguments: [
        // `-f` without a usable value
        "zen --working-directory '/w' -f",
        "zen --working-directory '/w' -f ",
        "zen --working-directory '/w' --jsonl -f",
        "zen --working-directory '/w' --jsonl -f ",
        "zen --working-directory '/w' -f /p/a.md",
        "zen --working-directory '/w' -f \"/p/a.md\"",
        "zen --working-directory '/w' -f '/p/a.md",
        "zen --working-directory '/w' -f 'a''b'",
        "zen --working-directory '/w' -f '/p/a\nb.md'",
        "zen --working-directory '/w' -f '/p/a\rb.md'",
        "zen --working-directory '/w' -f  '/p/a.md'",
        "zen --working-directory '/w' -f -p 'x'",
        "zen --working-directory '/w' -f '/p/a.md' -p",
        "zen --working-directory '/w' -f '/p/a.md' -p x",
        // neither `-f` nor `-p`
        "zen --working-directory '/w'",
        "zen --working-directory '/w' --jsonl",
        "zen --agent 'a' --working-directory '/w'",
        // `-p` before `-f`, or either repeated
        "zen --working-directory '/w' -p 'x' -f '/p/a.md'",
        "zen --working-directory '/w' --jsonl -p 'x' -f '/p/a.md'",
        "zen --working-directory '/w' -f '/p/a.md' -f '/p/b.md'",
        "zen --working-directory '/w' -f '/p/a.md' -p 'x' -f '/p/b.md'",
        "zen --working-directory '/w' -f '/p/a.md' -p 'x' -p 'y'",
        // `--jsonl` after the file
        "zen --working-directory '/w' -f '/p/a.md' --jsonl",
        "zen --working-directory '/w' -f '/p/a.md' --jsonl -p 'x'",
        "zen --working-directory '/w' -f '/p/a.md' -p 'x' --jsonl",
        // trailing text
        "zen --working-directory '/w' -f '/p/a.md' extra",
        "zen --working-directory '/w' -f '/p/a.md' ",
        "zen --working-directory '/w' -f '/p/a.md' -p 'x' extra",
        "zen --working-directory '/w' -f '/p/a.md' -p 'x' ",
        "zen --working-directory '/w' -f '/p/a.md'\n",
        "zen --working-directory '/w' -f '/p/a.md' -x 'y'",
        // flags are exact and case-sensitive
        "zen --working-directory '/w' -F '/p/a.md'",
        "zen --working-directory '/w' --file '/p/a.md'",
        "zen --working-directory '/w' -f='/p/a.md'",
        "zen --working-directory '/w'\t-f '/p/a.md'",
        "zen --working-directory '/w' -f\t'/p/a.md'"
    ])
    func decodeReturnsNilForAMalformedPromptFileOrPrompt(_ command: String) {
        #expect(ZenCronJobCommand.decode(command) == nil)
    }

    @Test
    func decodeAcceptsAQuotedPathWrittenByHandOrByAnOlderVersion() {
        #expect(
            ZenCronJobCommand.decode("'/usr/local/bin/zen' --working-directory '/w' --jsonl -p 'x'")
                == makeJob(executable: "/usr/local/bin/zen", workingDirectory: "/w", prompt: "x")
        )
        #expect(
            ZenCronJobCommand.decode("'/Applications/My Apps/zen' --working-directory '/w' --jsonl -p 'x'")?
                .executable == "/Applications/My Apps/zen"
        )
        // A quoted `zen` is the same job as the bare one.
        #expect(
            ZenCronJobCommand.decode("'zen' --working-directory '/w' --jsonl -p 'x'")
                == makeJob(workingDirectory: "/w", prompt: "x")
        )
    }

    @Test
    func decodeAcceptsTheDocumentedGrammarWrittenByHand() {
        let decoded = ZenCronJobCommand.decode(
            "ZENCODE_SUPPORT_DIRECTORY='/s' '/z' --agent 'a b' --working-directory '/w' --jsonl -p 'it'\\''s'"
        )
        #expect(
            decoded == makeJob(
                executable: "/z",
                supportDirectory: "/s",
                agentName: "a b",
                workingDirectory: "/w",
                prompt: "it's"
            )
        )
    }

    // MARK: - cron escaping

    @Test
    func cronEscapeEscapesEveryPercent() {
        #expect(ZenCronJobCommand.cronEscape("a%b%%c") == "a\\%b\\%\\%c")
        #expect(ZenCronJobCommand.cronEscape("no percent") == "no percent")
        #expect(ZenCronJobCommand.cronEscape("") == "")
    }

    @Test
    func cronUnescapeReversesEscapedPercent() {
        #expect(ZenCronJobCommand.cronUnescape("a\\%b\\%\\%c") == "a%b%%c")
        #expect(ZenCronJobCommand.cronUnescape("plain") == "plain")
        #expect(ZenCronJobCommand.cronUnescape("") == "")
        #expect(ZenCronJobCommand.cronUnescape("trailing backslash \\") == "trailing backslash \\")
        #expect(ZenCronJobCommand.cronUnescape("\\n stays") == "\\n stays")
    }

    @Test(arguments: ["a%b", "%", "50\\%%", "100%", "\\\\\\%%"])
    func cronUnescapeReturnsNilWhenAnUnescapedPercentRemains(_ text: String) {
        #expect(ZenCronJobCommand.cronUnescape(text) == nil)
    }

    @Test
    func cronUnescapeTreatsABackslashBeforeAnEscapedPercentAsLiteral() {
        // `x\\%y` is a literal backslash followed by an escaped percent, as cron itself reads it.
        #expect(ZenCronJobCommand.cronUnescape("x\\\\%y") == "x\\%y")
    }

    @Test(arguments: ["", "%", "\\%", "\\\\%", "a%b\\%c", "%%%", "50\\\\%\\%"])
    func cronEscapeThenUnescapeIsTheIdentity(_ text: String) {
        #expect(ZenCronJobCommand.cronUnescape(ZenCronJobCommand.cronEscape(text)) == text)
    }

    @Test
    func cronEscapedCommandContainsNoBarePercent() {
        let escaped = ZenCronJobCommand.cronEscape(makeJob(prompt: "100% and %d").encode())
        var previous: Character?
        for character in escaped {
            if character == "%" {
                #expect(previous == "\\")
            }
            previous = character
        }
    }

    // MARK: - locating zen

    private func withTemporaryDirectories(
        _ count: Int,
        _ body: ([URL]) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("zen-cron-locate-\(UUID().uuidString)", isDirectory: true)
        let directories = (0..<count).map { index in
            root.appendingPathComponent("dir\(index)-\(UUID().uuidString)", isDirectory: true)
        }
        for directory in directories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: root) }
        try body(directories)
    }

    private func writeZen(in directory: URL, executable: Bool) throws -> String {
        let url = directory.appendingPathComponent("zen")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url.path
    }

    @Test
    func locateZenReturnsTheFirstExecutableZenOnThePath() throws {
        try withTemporaryDirectories(2) { directories in
            let first = try writeZen(in: directories[0], executable: true)
            _ = try writeZen(in: directories[1], executable: true)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == first)

            let reversed = directories.reversed().map(\.path).joined(separator: ":")
            #expect(
                ZenCronJobCommand.locateZen(onPath: reversed)
                    == directories[1].appendingPathComponent("zen").path
            )
        }
    }

    @Test
    func locateZenSkipsANonExecutableZenAndFallsThroughToTheNextDirectory() throws {
        try withTemporaryDirectories(2) { directories in
            _ = try writeZen(in: directories[0], executable: false)
            let second = try writeZen(in: directories[1], executable: true)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == second)
        }
    }

    @Test
    func locateZenReturnsNilWithoutAnExecutableZen() throws {
        try withTemporaryDirectories(2) { directories in
            _ = try writeZen(in: directories[0], executable: false)
            let path = directories.map(\.path).joined(separator: ":")
            #expect(ZenCronJobCommand.locateZen(onPath: path) == nil)
        }
        #expect(ZenCronJobCommand.locateZen(onPath: "") == nil)
        #expect(ZenCronJobCommand.locateZen(onPath: ":::") == nil)
    }

    @Test
    func locateZenIgnoresEmptyAndRelativeEntries() {
        let fileManager = ProbingFileManager(executables: ["/fixture/zen"])
        let path = ":.::./:bin:~/bin:$HOME/bin::/fixture::/other:"
        #expect(ZenCronJobCommand.locateZen(onPath: path, fileManager: fileManager) == "/fixture/zen")
        // Only the absolute entries up to the match were probed.
        #expect(fileManager.probedPaths == ["/fixture/zen"])

        let miss = ProbingFileManager(executables: [])
        #expect(ZenCronJobCommand.locateZen(onPath: path, fileManager: miss) == nil)
        #expect(miss.probedPaths == ["/fixture/zen", "/other/zen"])
    }

    @Test
    func locateZenToleratesATrailingSlashOnADirectory() throws {
        try withTemporaryDirectories(1) { directories in
            let zen = try writeZen(in: directories[0], executable: true)
            #expect(ZenCronJobCommand.locateZen(onPath: directories[0].path + "/") == zen)
            #expect(ZenCronJobCommand.locateZen(onPath: directories[0].path + "//") == zen)
        }
    }

    @Test
    func locateZenUsesTheGivenFileManager() {
        let fileManager = ProbingFileManager(executables: ["/fixture/b/zen"])
        #expect(
            ZenCronJobCommand.locateZen(onPath: "/fixture/a:/fixture/b:/fixture/c", fileManager: fileManager)
                == "/fixture/b/zen"
        )
        #expect(fileManager.probedPaths == ["/fixture/a/zen", "/fixture/b/zen"])
    }

    @Test
    func locateZenProbesTheRootDirectoryAsSlashZen() {
        let fileManager = ProbingFileManager(executables: ["/zen"])
        #expect(ZenCronJobCommand.locateZen(onPath: "/", fileManager: fileManager) == "/zen")
        #expect(fileManager.probedPaths == ["/zen"])
    }
}

/// A `FileManager` that records every path asked about and reports a fixed set
/// as executable, so `locateZen` is tested without touching the machine's PATH.
private final class ProbingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private let executables: Set<String>
    private var probed: [String] = []

    init(executables: Set<String>) {
        self.executables = executables
        super.init()
    }

    var probedPaths: [String] {
        lock.withLock { probed }
    }

    override func isExecutableFile(atPath path: String) -> Bool {
        lock.withLock { probed.append(path) }
        return executables.contains(path)
    }
}
