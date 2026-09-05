import XCTest
@testable import CodexAwake

final class CodexUsageTests: XCTestCase {
    func testParserBuildsGeneralAndNamedRateLimitPresentations() throws {
        let response = """
        {
          "id": 2,
          "result": {
            "rateLimits": {
              "limitId": "codex",
              "primary": {
                "usedPercent": 5,
                "windowDurationMins": 10080,
                "resetsAt": 1788644701
              },
              "secondary": null,
              "credits": {
                "hasCredits": false,
                "unlimited": false,
                "balance": "0"
              },
              "planType": "pro",
              "rateLimitReachedType": null
            },
            "rateLimitsByLimitId": {
              "codex_bengalfox": {
                "limitId": "codex_bengalfox",
                "limitName": "GPT-5.3-Codex-Spark",
                "primary": {
                  "usedPercent": 0,
                  "windowDurationMins": 300,
                  "resetsAt": 1788094301
                },
                "secondary": {
                  "usedPercent": 0,
                  "windowDurationMins": 10080,
                  "resetsAt": 1788681101
                },
                "credits": null,
                "planType": "pro",
                "rateLimitReachedType": null
              },
              "codex": {
                "limitId": "codex",
                "primary": {
                  "usedPercent": 5,
                  "windowDurationMins": 10080,
                  "resetsAt": 1788644701
                },
                "secondary": null,
                "credits": {
                  "hasCredits": false,
                  "unlimited": false,
                  "balance": "0"
                },
                "planType": "pro",
                "rateLimitReachedType": null
              }
            },
            "rateLimitResetCredits": {
              "availableCount": 1,
              "credits": []
            }
          }
        }
        """

        let snapshot = try XCTUnwrap(
            CodexUsageResponseParser.parseResponseLine(Data(response.utf8))
        )
        let presentations = CodexUsageMenuPresentation.make(snapshot: snapshot)

        XCTAssertEqual(snapshot.availableResetCredits, 1)
        XCTAssertEqual(snapshot.limits.map(\.limitID), ["codex", "codex_bengalfox"])
        XCTAssertEqual(
            presentations.map(\.title),
            [
                "Codex · Weekly 95% left",
                "GPT-5.3-Codex-Spark · 5h 100% left"
            ]
        )
        XCTAssertTrue(presentations[1].details[0].title.hasPrefix("5h · 100% left · resets "))
        XCTAssertTrue(presentations[1].details[1].title.hasPrefix("Weekly · 100% left · resets "))
        XCTAssertEqual(presentations[1].details[2].title, "Plan · Pro")
        XCTAssertTrue(
            presentations[0].details.contains { $0.title == "1 limit reset available" }
        )
    }

    func testParserIgnoresUnrelatedAppServerMessages() throws {
        let notification = Data(
            #"{"method":"remoteControl/status/changed","params":{"status":"connected"}}"#.utf8
        )
        let initializeResponse = Data(
            #"{"id":1,"result":{"userAgent":"codex","codexHome":"/tmp","platformFamily":"unix","platformOs":"macos"}}"#.utf8
        )

        XCTAssertNil(try CodexUsageResponseParser.parseResponseLine(notification))
        XCTAssertNil(try CodexUsageResponseParser.parseResponseLine(initializeResponse))
    }

    func testParserSurfacesAppServerError() {
        let response = Data(
            #"{"id":2,"error":{"code":-32000,"message":"Sign in to Codex to view usage"}}"#.utf8
        )

        XCTAssertThrowsError(try CodexUsageResponseParser.parseResponseLine(response)) { error in
            XCTAssertEqual(
                error as? CodexUsageError,
                .requestFailed("Sign in to Codex to view usage")
            )
        }
    }

    func testRemainingPercentageIsClamped() {
        XCTAssertEqual(
            CodexUsageWindow(usedPercent: -5, windowDurationMins: 300, resetsAt: nil).remainingPercent,
            100
        )
        XCTAssertEqual(
            CodexUsageWindow(usedPercent: 125, windowDurationMins: 300, resetsAt: nil).remainingPercent,
            0
        )
    }
}
