//
//  SubscriptionUsageParsingTests.swift
//  ZenCODE
//
//  Verifies daily/weekly subscription usage parsing for the ChatGPT and Anthropic clients.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct SubscriptionUsageParsingTests {
    @Test
    func chatGPTParsesRateLimitsWithWindowMinutes() throws {
        let object: [String: Any] = [
            "type": "token_count",
            "rate_limits": [
                "primary": [
                    "used_percent": 12.5,
                    "window_minutes": 300,
                    "resets_in_seconds": 3_600
                ],
                "secondary": [
                    "used_percent": 47.0,
                    "window_minutes": 10_080,
                    "resets_in_seconds": 86_400
                ]
            ]
        ]

        let usage = try #require(
            ChatGPTSubscriptionGenerationClient.subscriptionUsage(from: object)
        )
        #expect(usage.provider == "ChatGPT")
        #expect(usage.dailyUsedPercent == 12.5)
        #expect(usage.weeklyUsedPercent == 47.0)
        #expect(usage.dailyResetsInSeconds == 3_600)
        #expect(usage.weeklyResetsInSeconds == 86_400)
    }

    @Test
    func chatGPTClassifiesSingleWeeklyPrimaryWindowByDuration() throws {
        let object: [String: Any] = [
            "type": "codex.rate_limits",
            "rate_limits": [
                "primary": [
                    "used_percent": 42.0,
                    "window_minutes": 10_080,
                    "resets_in_seconds": 86_400
                ]
            ]
        ]

        let usage = try #require(
            ChatGPTSubscriptionGenerationClient.subscriptionUsage(from: object)
        )
        #expect(usage.dailyUsedPercent == nil)
        #expect(usage.weeklyUsedPercent == 42.0)
        #expect(usage.dailyResetsInSeconds == nil)
        #expect(usage.weeklyResetsInSeconds == 86_400)
    }

    @Test
    func chatGPTFallsBackToPrimarySecondaryOrderingWithoutWindows() throws {
        let object: [String: Any] = [
            "rate_limits": [
                "primary": ["used_percent": 8.0],
                "secondary": ["used_percent": 33.0]
            ]
        ]

        let usage = try #require(
            ChatGPTSubscriptionGenerationClient.subscriptionUsage(from: object)
        )
        #expect(usage.dailyUsedPercent == 8.0)
        #expect(usage.weeklyUsedPercent == 33.0)
    }

    @Test
    func chatGPTReturnsNilWhenNoRateLimits() {
        let object: [String: Any] = ["type": "token_count", "usage": ["input_tokens": 10]]
        #expect(ChatGPTSubscriptionGenerationClient.subscriptionUsage(from: object) == nil)
    }

    @Test
    func chatGPTConvertsAbsoluteResetAtIntoRelativeSeconds() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let object: [String: Any] = [
            "type": "codex.rate_limits",
            "rate_limits": [
                "primary": [
                    "used_percent": 12.5,
                    "window_minutes": 300,
                    "reset_at": 1_000_000 + 3_600
                ],
                "secondary": [
                    "used_percent": 47.0,
                    "window_minutes": 10_080,
                    "reset_at": 1_000_000 + 86_400
                ]
            ]
        ]

        let usage = try #require(
            ChatGPTSubscriptionGenerationClient.subscriptionUsage(from: object)
        )
        #expect(usage.dailyUsedPercent == 12.5)
        #expect(usage.weeklyUsedPercent == 47.0)

        let dailyPrimary = try #require(object["rate_limits"] as? [String: Any])
        let dailyWindow = try #require(dailyPrimary["primary"] as? [String: Any])
        let weeklyWindow = try #require(dailyPrimary["secondary"] as? [String: Any])
        #expect(
            ChatGPTSubscriptionGenerationClient.resetsInSeconds(
                fromWindow: dailyWindow,
                now: now
            ) == 3_600
        )
        #expect(
            ChatGPTSubscriptionGenerationClient.resetsInSeconds(
                fromWindow: weeklyWindow,
                now: now
            ) == 86_400
        )
    }

    @Test
    func chatGPTParsesUsageFromCodexResponseHeaders() throws {
        let headers = RemoteHTTPHeaders([
            RemoteHTTPHeader(name: "x-codex-primary-used-percent", value: "4.0"),
            RemoteHTTPHeader(name: "x-codex-primary-window-minutes", value: "300"),
            RemoteHTTPHeader(name: "x-codex-secondary-used-percent", value: "1.0"),
            RemoteHTTPHeader(name: "x-codex-secondary-window-minutes", value: "10080")
        ])

        let usage = try #require(
            ChatGPTSubscriptionGenerationClient.subscriptionUsage(fromHeaders: headers)
        )
        #expect(usage.provider == "ChatGPT")
        #expect(usage.dailyUsedPercent == 4.0)
        #expect(usage.weeklyUsedPercent == 1.0)
    }

    @Test
    func chatGPTReturnsNilWithoutCodexUsageHeaders() throws {
        let headers = RemoteHTTPHeaders([
            RemoteHTTPHeader(name: "content-type", value: "text/event-stream")
        ])
        #expect(
            ChatGPTSubscriptionGenerationClient.subscriptionUsage(fromHeaders: headers) == nil
        )
    }

    @Test
    func anthropicParsesUtilizationHeadersAsPercentages() throws {
        let headers = RemoteHTTPHeaders([
            RemoteHTTPHeader(
                name: "anthropic-ratelimit-unified-5h-utilization",
                value: "0.25"
            ),
            RemoteHTTPHeader(
                name: "anthropic-ratelimit-unified-7d-utilization",
                value: "0.6"
            )
        ])

        let usage = try #require(
            AnthropicSubscriptionGenerationClient.subscriptionUsage(fromHeaders: headers)
        )
        #expect(usage.provider == "Anthropic")
        #expect(usage.dailyUsedPercent == 25.0)
        #expect(usage.weeklyUsedPercent == 60.0)
    }

    @Test
    func anthropicReturnsNilWithoutUsageHeaders() throws {
        let headers = RemoteHTTPHeaders([
            RemoteHTTPHeader(name: "content-type", value: "application/json")
        ])
        #expect(AnthropicSubscriptionGenerationClient.subscriptionUsage(fromHeaders: headers) == nil)
    }

    @Test
    func resetFormatterUsesAbsoluteLocalTimeForRelativeSeconds() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 1
        components.hour = 12
        components.minute = 15
        let calendar = Calendar.current
        let now = calendar.date(from: components)!

        let date = try #require(
            SubscriptionLimitResetFormatter.resetDate(
                fromSecondsValue: 2 * 3_600 + 15 * 60,
                now: now
            )
        )
        let text = SubscriptionLimitResetFormatter.resumeTimeText(
            for: date,
            now: now,
            calendar: calendar
        )
        #expect(text == "14:30")
    }

    @Test
    func resetFormatterHandlesAbsoluteUnixTimestamp() {
        let timestamp: Double = 1_900_000_000
        let resetDate = SubscriptionLimitResetFormatter.resetDate(fromSecondsValue: timestamp)
        #expect(resetDate == Date(timeIntervalSince1970: timestamp))
    }

    @Test
    func anthropicLimitMessageUsesSoonestResetHeader() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 1
        components.hour = 9
        components.minute = 0
        let now = Calendar.current.date(from: components)!

        let headers = RemoteHTTPHeaders([
            RemoteHTTPHeader(
                name: "anthropic-ratelimit-unified-5h-reset",
                value: "3600"
            ),
            RemoteHTTPHeader(
                name: "anthropic-ratelimit-unified-7d-reset",
                value: "86400"
            )
        ])
        let message = try #require(
            AnthropicSubscriptionGenerationClient.limitReachedMessage(
                fromHeaders: headers,
                now: now
            )
        )
        #expect(message.contains("Anthropic"))
        #expect(message.contains("10:00"))
    }

    @Test
    func chatGPTEnrichesUsageLimitOutputWithResetTime() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 1
        components.hour = 8
        components.minute = 30
        let now = Calendar.current.date(from: components)!

        let output = "{\"error\":{\"message\":\"Usage limit reached\",\"resets_in_seconds\":1800}}"
        let enriched = ChatGPTSubscriptionResponsesClient.enrichedLimitOutput(
            status: 429,
            output: output,
            headers: RemoteHTTPHeaders(),
            now: now
        )
        #expect(enriched.contains("ChatGPT"))
        #expect(enriched.contains("09:00"))
        #expect(enriched.contains("Usage limit reached"))
    }

    @Test
    func chatGPTLeavesNonLimitOutputUnchanged() throws {
        let output = "{\"error\":{\"message\":\"Internal error\"}}"
        let enriched = ChatGPTSubscriptionResponsesClient.enrichedLimitOutput(
            status: 500,
            output: output,
            headers: RemoteHTTPHeaders()
        )
        #expect(enriched == output)
    }
}
