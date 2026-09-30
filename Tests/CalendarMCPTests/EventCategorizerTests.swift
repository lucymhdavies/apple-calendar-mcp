import XCTest

@testable import CalendarMCP

final class EventCategorizerTests: XCTestCase {
    func testConfigurationNormalizesDomainsAndExtractsMailtoAddress() throws {
        let configuration = EventCategoryConfiguration(
            internalEmailDomains: [" @Internal.Example ", "invalid", ""])

        XCTAssertEqual(configuration.internalEmailDomains, ["internal.example"])
        XCTAssertEqual(
            EventCategoryConfiguration.domain(
                fromEmailURL: try XCTUnwrap(URL(string: "mailto:person@Internal.Example"))),
            "internal.example")
        XCTAssertNil(
            EventCategoryConfiguration.domain(
                fromEmailURL: URL(string: "https://person@external.example/path")))
    }

    func testMissingConfigurationFileReturnsEmptyConfiguration() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)

        XCTAssertTrue(EventCategoryConfiguration.load(from: url).internalEmailDomains.isEmpty)
    }

    func testPersonalAbsenceMarkersAreOutOfOffice() {
        for title in ["OOO", "PTO", "Annual Leave", "Sick Leave", "Off Sick", "Holiday"] {
            XCTAssertEqual(categorize(title: title), .outOfOffice, title)
        }
        XCTAssertEqual(
            categorize(title: "PTO", isAllDay: true, otherParticipantCount: 4),
            .outOfOffice)
    }

    func testTeammateAbsenceAndPublicHolidayAreNotOutOfOffice() {
        XCTAssertEqual(
            categorize(
                title: "Teammate OOO", isAllDay: true, isCurrentUserOrganizer: false,
                hasOrganizer: true, otherParticipantCount: 1),
            .uncategorized)
        XCTAssertEqual(
            categorize(
                title: "Public Holiday", isAllDay: true, isCalendarWritable: false,
                isCurrentUserOrganizer: false, hasOrganizer: false),
            .uncategorized)
    }

    func testTravelMarkersTakePrecedence() {
        XCTAssertEqual(categorize(title: "Flight to conference"), .travel)
        XCTAssertEqual(categorize(title: "Train travel"), .travel)
    }

    func testFocusAndAdminRequirePersonalEvent() {
        XCTAssertEqual(categorize(title: "Focus time"), .focusTime)
        XCTAssertEqual(categorize(title: "General admin"), .focusTime)
        XCTAssertEqual(categorize(title: "End of Week Admin"), .focusTime)
        XCTAssertEqual(
            categorize(title: "Admin review", otherParticipantCount: 2),
            .uncategorized)
    }

    func testHoldUsesTitleRegardlessOfAttendeeCount() {
        XCTAssertEqual(categorize(title: "Lunch blocker", otherParticipantCount: 3), .hold)
        XCTAssertEqual(categorize(title: "Hold for planning"), .hold)
    }

    func testOneOnOneUsesMarkersOrExactlyOneOtherAttendee() {
        XCTAssertEqual(categorize(title: "Weekly 1:1", otherParticipantCount: 4), .oneOnOne)
        XCTAssertEqual(categorize(title: "Weekly one-on-one", otherParticipantCount: 4), .oneOnOne)
        XCTAssertEqual(categorize(title: "Weekly one on one", otherParticipantCount: 4), .oneOnOne)
        XCTAssertEqual(categorize(title: "Catch up", otherParticipantCount: 1), .oneOnOne)
        XCTAssertEqual(categorize(title: "Project 11 review", otherParticipantCount: 4), .uncategorized)
        XCTAssertEqual(
            categorize(
                title: "Teammate PTO", isAllDay: true,
                isCurrentUserOrganizer: false, otherParticipantCount: 1),
            .uncategorized)
        XCTAssertEqual(
            categorize(
                title: "Teammate OOO", isCurrentUserOrganizer: false,
                otherParticipantCount: 1),
            .uncategorized)
    }

    func testGroupEventMarkersSuppressAttendeeCountInference() {
        for title in [
            "Enablement session", "Working sessions", "Technology talks", "Product Q&A",
            "Team kickoff", "Community call", "All-hands", "Customer workshops",
            "Monthly social hours",
        ] {
            XCTAssertEqual(
                categorize(title: title, otherParticipantCount: 1),
                .uncategorized,
                title)
        }
        XCTAssertEqual(
            categorize(title: "Workshop 1:1", otherParticipantCount: 1),
            .oneOnOne)
    }

    func testDomainClassificationRequiresCurrentUserDomainEvidence() {
        XCTAssertEqual(
            categorize(
                title: "Project review", otherParticipantCount: 2,
                attendeeDomains: ["internal.example", "external.example"],
                currentUserDomains: ["internal.example"]),
            .external)
        XCTAssertEqual(
            categorize(
                title: "Team meeting", otherParticipantCount: 2,
                attendeeDomains: ["internal.example"],
                currentUserDomains: ["internal.example"]),
            .internal)
        XCTAssertEqual(
            categorize(
                title: "Unknown meeting", otherParticipantCount: 2,
                attendeeDomains: ["external.example"]),
            .uncategorized)
        XCTAssertEqual(
            categorize(
                title: "Internal event", otherParticipantCount: 2,
                attendeeDomains: ["internal.example", "meetings.internal.example"],
                currentUserDomains: ["internal.example"]),
            .internal)
        XCTAssertEqual(
            categorize(
                title: "External customer event", otherParticipantCount: 2,
                attendeeDomains: ["internal.example", "external.example"],
                currentUserDomains: ["internal.example"]),
            .external)
    }

    private func categorize(
        title: String,
        isAllDay: Bool = false,
        isCalendarWritable: Bool = true,
        isCurrentUserOrganizer: Bool = true,
        hasOrganizer: Bool = true,
        otherParticipantCount: Int = 0,
        attendeeDomains: Set<String> = [],
        currentUserDomains: Set<String> = []
    ) -> EventCategory {
        EventCategorizer.categorize(
            EventCategorizationContext(
                title: title,
                isAllDay: isAllDay,
                isCalendarWritable: isCalendarWritable,
                isCurrentUserOrganizer: isCurrentUserOrganizer,
                hasOrganizer: hasOrganizer,
                otherParticipantCount: otherParticipantCount,
                attendeeDomains: attendeeDomains,
                currentUserDomains: currentUserDomains))
    }
}