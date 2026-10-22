import Foundation
import Testing

@testable import MacOS

@Suite
struct NotesHTMLTests {
    @Test
    func escapesPlainTextAndSplitsParagraphs() {
        let html = NotesController.html(title: "A <b> & B", body: "line 1\r\n\nx < y & z > w", format: nil)
        #expect(html == "<h1>A &lt;b&gt; &amp; B</h1><div>line 1</div><div><br></div><div>x &lt; y &amp; z &gt; w</div>")
    }

    @Test
    func passesHTMLBodiesThroughButStillEscapesTheTitle() {
        let html = NotesController.html(title: "<t>", body: "<p>kept <b>as is</b></p>", format: "HTML")
        #expect(html == "<h1>&lt;t&gt;</h1><p>kept <b>as is</b></p>")
    }

    @Test
    func omitsAnEmptyTitle() {
        #expect(NotesController.html(title: "", body: "x", format: nil) == "<div>x</div>")
        #expect(NotesController.html(title: nil, body: "", format: nil) == "<div><br></div>")
    }
}

@Suite
struct RemindersPriorityTests {
    @Test
    func mapsNamesAndIntegersToEventKitPriorities() throws {
        #expect(try RemindersController.priorityValue("none") == 0)
        #expect(try RemindersController.priorityValue(" High ") == 1)
        #expect(try RemindersController.priorityValue("medium") == 5)
        #expect(try RemindersController.priorityValue("low") == 9)
        #expect(try RemindersController.priorityValue(" 3 ") == 3)
        #expect(throws: MacOSControlError.self) { try RemindersController.priorityValue("10") }
        #expect(throws: MacOSControlError.self) { try RemindersController.priorityValue("urgent") }
    }

    @Test
    func labelsRoundTrip() throws {
        for name in ["none", "high", "medium", "low"] {
            #expect(RemindersController.priorityLabel(try RemindersController.priorityValue(name)) == name)
        }
        #expect(RemindersController.priorityLabel(3) == "high")
        #expect(RemindersController.priorityLabel(7) == "low")
    }
}

@Suite
struct MessagesDatabaseTests {
    @Test
    func normalizesChatSelectors() {
        #expect(MessagesDatabase.normalizedSelector(nil) == nil)
        #expect(MessagesDatabase.normalizedSelector("   ") == nil)
        #expect(MessagesDatabase.normalizedSelector(" +39123 ") == "+39123")
        #expect(MessagesDatabase.normalizedSelector("iMessage;-;+39123") == "+39123")
        #expect(MessagesDatabase.normalizedSelector("any;+;chat123") == "chat123")
        #expect(MessagesDatabase.normalizedSelector("SMS;-;name@example.com") == "name@example.com")
        #expect(MessagesDatabase.normalizedSelector("chat123") == "chat123")
    }

    @Test
    func readsNanosecondAndLegacySecondDates() {
        let reference = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(MessagesDatabase.date(fromRaw: 800_000_000_000_000_000) == reference)
        #expect(MessagesDatabase.date(fromRaw: 800_000_000) == reference)
        #expect(MessagesDatabase.date(fromRaw: 0) == nil)
        #expect(MessagesDatabase.date(fromRaw: -5) == nil)
    }

    @Test
    func percentEncodesURIPaths() {
        #expect(MessagesDatabase.encodedPath("/Users/me/Library/Messages/chat.db") == "/Users/me/Library/Messages/chat.db")
        #expect(MessagesDatabase.encodedPath("/Users/me?x/a#b/100%/chat.db") == "/Users/me%3Fx/a%23b/100%25/chat.db")
        #expect(MessagesDatabase.encodedPath("/Users/mé/chat.db") == "/Users/m%C3%A9/chat.db")
    }
}

@Suite
struct AttributedBodyDecoderTests {
    /// Builds the typedstream archive Messages writes for an attributed string:
    /// the fixed header up to the `NSString` class and the `+` tag, the length
    /// in typedstream integer encoding, the UTF-8 payload, then the attribute
    /// dictionary trailer.
    private func typedstream(_ text: String) -> Data {
        var bytes: [UInt8] = [
            0x04, 0x0b, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64, 0x81, 0xe8, 0x03,
            0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12, 0x4e, 0x53, 0x41, 0x74, 0x74, 0x72, 0x69, 0x62, 0x75,
            0x74, 0x65, 0x64, 0x53, 0x74, 0x72, 0x69, 0x6e, 0x67, 0x00, 0x84, 0x84, 0x08, 0x4e, 0x53, 0x4f,
            0x62, 0x6a, 0x65, 0x63, 0x74, 0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08, 0x4e, 0x53, 0x53, 0x74,
            0x72, 0x69, 0x6e, 0x67, 0x01, 0x94, 0x84, 0x01, 0x2b,
        ]
        let payload = Array(text.utf8)
        switch payload.count {
        case 0 ..< 0x81:
            bytes.append(UInt8(payload.count))
        case 0x81 ... 0xFFFF:
            bytes.append(0x81)
            bytes.append(UInt8(payload.count & 0xFF))
            bytes.append(UInt8(payload.count >> 8))
        default:
            bytes.append(0x82)
            for shift in [0, 8, 16, 24] {
                bytes.append(UInt8((payload.count >> shift) & 0xFF))
            }
        }
        bytes.append(contentsOf: payload)
        bytes.append(contentsOf: [
            0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x1c, 0x92, 0x84, 0x84, 0x84, 0x0c, 0x4e, 0x53, 0x44, 0x69,
            0x63, 0x74, 0x69, 0x6f, 0x6e, 0x61, 0x72, 0x79, 0x00, 0x94, 0x84, 0x01, 0x69, 0x00, 0x86, 0x86,
        ])
        return Data(bytes)
    }

    @Test
    func extractsTheStringFromATypedstreamArchive() {
        #expect(AttributedBodyDecoder.text(from: typedstream("Ciao 😀, ci vediamo alle 10!")) == "Ciao 😀, ci vediamo alle 10!")
        #expect(AttributedBodyDecoder.text(from: typedstream("x")) == "x")
        let long = String(repeating: "long message ", count: 40)
        #expect(AttributedBodyDecoder.text(from: typedstream(long)) == long)
        let veryLong = String(repeating: "very long message ", count: 5_000)
        #expect(AttributedBodyDecoder.text(from: typedstream(veryLong)) == veryLong)
    }

    @Test
    func toleratesGarbageAndTruncatedPayloads() {
        #expect(AttributedBodyDecoder.text(from: Data()) == nil)
        #expect(AttributedBodyDecoder.text(from: Data("no marker here".utf8)) == nil)
        #expect(AttributedBodyDecoder.text(from: Data("NSString".utf8)) == nil)
        #expect(AttributedBodyDecoder.text(from: Data("NSString+".utf8)) == nil)
        // Declared length longer than the payload.
        #expect(AttributedBodyDecoder.text(from: Data("NSString\u{01}+\u{20}abc".utf8)) == nil)
        let truncated = typedstream("Ciao a tutti").prefix(40)
        _ = AttributedBodyDecoder.text(from: Data(truncated))
    }
}
