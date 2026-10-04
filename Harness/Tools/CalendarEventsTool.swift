//
//  CalendarEventsTool.swift
//  Harness
//

import EventKit
import Foundation

/// Read-only access to the user's calendar events.
struct CalendarEventsTool: Tool {
    static let maxEvents = 200

    let name = "calendar_events"
    let description = """
        Read-only. Lists events from the user's calendars that overlap a date range. \
        Dates use ISO 8601: either a date (YYYY-MM-DD, a whole local day; 'end' is inclusive) \
        or a date-time (for example 2026-10-04T09:00:00-07:00). The range can be at most one year.
        """

    var parameters: JSONValue {
        [
            "type": "object",
            "properties": [
                "start": ["type": "string", "description": "Start of the range (ISO 8601 date or date-time)."],
                "end": ["type": "string", "description": "End of the range (ISO 8601 date or date-time)."],
            ],
            "required": ["start", "end"],
            "additionalProperties": false,
        ]
    }

    private struct Arguments: Decodable {
        let start: String
        let end: String
    }

    private struct EventOutput: Encodable {
        let title: String
        let start: String
        let end: String
        let allDay: Bool
        let calendar: String
        let location: String?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case title, start, end, calendar, location, notes
            case allDay = "all_day"
        }
    }

    private struct Output: Encodable {
        let timeZone: String
        let rangeStart: String
        let rangeEnd: String
        let count: Int
        let truncated: Bool
        let events: [EventOutput]

        enum CodingKeys: String, CodingKey {
            case count, truncated, events
            case timeZone = "time_zone"
            case rangeStart = "range_start"
            case rangeEnd = "range_end"
        }
    }

    func run(argumentsJSON: String) async throws -> String {
        let arguments = try decodeToolArguments(Arguments.self, from: argumentsJSON)
        guard let start = Self.parseDate(arguments.start, isEnd: false) else {
            throw ToolArgumentError(message: "Could not parse 'start' as an ISO 8601 date: \(arguments.start)")
        }
        guard let end = Self.parseDate(arguments.end, isEnd: true) else {
            throw ToolArgumentError(message: "Could not parse 'end' as an ISO 8601 date: \(arguments.end)")
        }
        guard end > start else {
            throw ToolArgumentError(message: "'end' must be after 'start'.")
        }
        guard end.timeIntervalSince(start) <= 366 * 24 * 60 * 60 else {
            throw ToolArgumentError(message: "The range can be at most one year.")
        }

        let store = try await CalendarAccess.authorizedStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        let output = Output(
            timeZone: TimeZone.current.identifier,
            rangeStart: Self.format(start, allDay: false),
            rangeEnd: Self.format(end, allDay: false),
            count: events.count,
            truncated: events.count > Self.maxEvents,
            events: events.prefix(Self.maxEvents).map { event in
                EventOutput(
                    title: event.title ?? "(No title)",
                    start: Self.format(event.startDate, allDay: event.isAllDay),
                    end: Self.format(event.endDate, allDay: event.isAllDay),
                    allDay: event.isAllDay,
                    calendar: event.calendar?.title ?? "",
                    location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                    notes: event.notes.flatMap { $0.isEmpty ? nil : String($0.prefix(500)) }
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(output), as: UTF8.self)
    }

    /// Accepts a full ISO 8601 date-time, a local date-time without offset, or a date.
    /// A date as `end` means the end of that day.
    static func parseDate(_ text: String, isEnd: Bool) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            iso.formatOptions = options
            if let date = iso.date(from: trimmed) { return date }
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }

        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: trimmed) else { return nil }
        let startOfDay = Calendar.current.startOfDay(for: day)
        return isEnd ? Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) : startOfDay
    }

    private static func format(_ date: Date, allDay: Bool) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = allDay ? [.withFullDate] : [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Owns the shared event store and requests read access on first use.
enum CalendarAccess {
    private static var store = EKEventStore()

    static func authorizedStore() async throws -> EKEventStore {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return store
        case .notDetermined:
            let granted = try await store.requestFullAccessToEvents()
            guard granted else { throw deniedError }
            // A store created before access was granted can return stale results; start fresh.
            store = EKEventStore()
            return store
        default:
            throw deniedError
        }
    }

    private static var deniedError: ToolError {
        ToolError(message: "Calendar access is not granted. The user can allow it in Settings > Privacy & Security > Calendars > Harness.")
    }
}
