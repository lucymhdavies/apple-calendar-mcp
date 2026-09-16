import MCP
import XCTest
@testable import CalendarMCP

final class MainTests: XCTestCase {
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

    func testRESTConfigurationRequiresTokenForNonLoopbackHost() {
        XCTAssertThrowsError(try RESTConfiguration.fromEnvironment([
            "REST_HOST": "192.168.1.10",
            "REST_PORT": "8765"
        ]))
    }

    func testRESTConfigurationAcceptsLongTokenForNonLoopbackHost() throws {
        let configuration = try RESTConfiguration.fromEnvironment([
            "REST_HOST": "192.168.1.10",
            "REST_PORT": "8765",
            "REST_TOKEN": "0123456789abcdef"
        ])

        XCTAssertEqual(configuration.host, "192.168.1.10")
        XCTAssertEqual(configuration.token, "0123456789abcdef")
    }
}
