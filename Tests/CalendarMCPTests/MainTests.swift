import MCP
import XCTest

@testable import CalendarMCP

final class MainTests: XCTestCase {
    func testRESTJSONEncoderIncludesNumericTimezoneOffset() throws {
        struct Timestamp: Encodable {
            let date: Date
        }

        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 3_600))
        let data = try restJSONEncoder(timeZone: timeZone).encode(
            Timestamp(date: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"date\":\"1970-01-01T01:00:00+01:00\"}")
    }

    func testDateArgumentParsesRFC3339() throws {
        let params = CallTool.Parameters(
            name: "list_events",
            arguments: ["from": "2026-09-16T12:00:00Z"])

        let date = try XCTUnwrap(dateArgument(params, key: "from"))

        XCTAssertEqual(date.timeIntervalSince1970, 1_789_560_000)
    }

    func testDateArgumentTreatsMissingAndBlankValuesAsNil() throws {
        let missing = CallTool.Parameters(name: "list_events")
        let blank = CallTool.Parameters(
            name: "list_events",
            arguments: ["from": "  "])

        XCTAssertNil(try dateArgument(missing, key: "from"))
        XCTAssertNil(try dateArgument(blank, key: "from"))
    }

    func testDateArgumentRejectsInvalidRFC3339() {
        let params = CallTool.Parameters(
            name: "list_events",
            arguments: ["from": "not-a-date"])

        XCTAssertThrowsError(try dateArgument(params, key: "from")) { error in
            guard case ServerError.invalidDate("from") = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testValidateRangeRejectsNonIncreasingRanges() {
        let date = Date(timeIntervalSince1970: 1_000)

        XCTAssertThrowsError(try validateRange(date, date))
        XCTAssertThrowsError(try validateRange(date, date.addingTimeInterval(-1)))
    }

    func testValidateRangeAcceptsIncreasingRange() {
        let from = Date(timeIntervalSince1970: 1_000)
        let to = Date(timeIntervalSince1970: 1_001)

        XCTAssertNoThrow(try validateRange(from, to))
    }

    func testRESTConfigurationDefaultsToLoopback() throws {
        let configuration = try RESTConfiguration.fromEnvironment([:])

        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.port, 8765)
        XCTAssertNil(configuration.token)
    }

    func testRESTConfigurationAcceptsValidPort() throws {
        XCTAssertEqual(try RESTConfiguration.port(from: "9000"), 9000)
    }

    func testRESTConfigurationRejectsInvalidPort() {
        XCTAssertThrowsError(try RESTConfiguration.port(from: "0"))
        XCTAssertThrowsError(try RESTConfiguration.port(from: "65536"))
        XCTAssertThrowsError(try RESTConfiguration.port(from: "not-a-port"))
    }

    func testRESTConfigurationRequiresTokenForNonLoopbackHost() {
        XCTAssertThrowsError(
            try RESTConfiguration.fromEnvironment([
                "REST_HOST": "192.168.1.10",
                "REST_PORT": "8765",
            ]))
    }

    func testRESTConfigurationAcceptsLongTokenForNonLoopbackHost() throws {
        let configuration = try RESTConfiguration.fromEnvironment([
            "REST_HOST": "192.168.1.10",
            "REST_PORT": "8765",
            "REST_TOKEN": "0123456789abcdef",
        ])

        XCTAssertEqual(configuration.host, "192.168.1.10")
        XCTAssertEqual(configuration.token, "0123456789abcdef")
    }

    func testRESTConfigurationSupportsLANBindingWithToken() throws {
        let configuration = try RESTConfiguration.fromEnvironment([
            "REST_HOST": "0.0.0.0",
            "REST_PORT": "8765",
            "REST_TOKEN": "0123456789abcdef",
        ])

        XCTAssertFalse(configuration.isLoopback)
        XCTAssertEqual(configuration.host, "0.0.0.0")
        XCTAssertEqual(configuration.token, "0123456789abcdef")
    }

    func testCalendarAccessDeniedErrorIsDistinctFromUndeterminedAccess() {
        XCTAssertEqual(
            CalendarBackendError.accessDenied.errorDescription,
            "Calendar access was denied")
        XCTAssertNotEqual(
            CalendarBackendError.accessDenied.errorDescription,
            CalendarBackendError.accessNotDetermined.errorDescription)
    }

    func testEventOccurrenceIdentifierRoundTripsEventAndStart() throws {
        let start = Date(timeIntervalSince1970: 1_789_560_000.25)
        let identifier = EventOccurrenceIdentifier.make(eventIdentifier: "series-id", start: start)

        let parsed = try XCTUnwrap(EventOccurrenceIdentifier.parse(identifier))

        XCTAssertEqual(parsed.eventIdentifier, "series-id")
        XCTAssertEqual(parsed.start, start)
    }

    func testEventOccurrenceIdentifierRejectsLegacyAndMalformedIDs() {
        XCTAssertNil(EventOccurrenceIdentifier.parse("series-id"))
        XCTAssertNil(EventOccurrenceIdentifier.parse("@occurrence:1789560000"))
        XCTAssertNil(EventOccurrenceIdentifier.parse("series-id#occurrence:not-a-timestamp"))
        XCTAssertNil(EventOccurrenceIdentifier.parse("series-id@occurrence:nan"))
    }
}
