// reminders-mcp — local MCP server for Apple Reminders (macOS, EventKit).
//
// Design rules:
//  * Read-only by default. Write tools only exist when REMINDERS_MCP_WRITE enables them
//    (create, update, delete or all); without that setting they are not even offered.
//  * No storage: reminders only exist in memory while a single call is being answered.
//  * No content in logs: stderr only contains tool names, counts and durations.
//  * Transport: MCP over stdio (JSON-RPC 2.0, one JSON message per line).

import EventKit
import Foundation
import SQLite3

let serverName = "apple-reminders"
let serverVersion = "1.2.0"
let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

// MARK: - Helpers

func log(_ message: String) {
    FileHandle.standardError.write(Data("[reminders-mcp] \(message)\n".utf8))
}

struct ToolError: Error {
    let message: String
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

func jsonString(_ object: Any, pretty: Bool = true) -> String {
    var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .sortedKeys]
    if pretty { options.insert(.prettyPrinted) }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
          let text = String(data: data, encoding: .utf8)
    else { return "{}" }
    return text
}

func orNull(_ value: Any?) -> Any { value ?? NSNull() }

// MARK: - Time and "today"

/// Snapshot of the Mac's local time zone. Determined again on every call, so that a
/// time zone change (travel, daylight saving time) is also correct in a long-running process.
struct LocalTime {
    let timeZone: TimeZone
    let calendar: Calendar
    let now: Date

    init() {
        NSTimeZone.resetSystemTimeZone()
        timeZone = TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        calendar = cal
        now = Date()
    }

    var todayStart: Date { calendar.startOfDay(for: now) }

    func dayString(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func timeString(_ date: Date) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Accepts "YYYY-MM-DD", "vandaag"/"today", "morgen"/"tomorrow", "gisteren"/"yesterday".
    func parseDay(_ raw: String) throws -> Date {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        switch text {
        case "", "vandaag", "today": return todayStart
        case "morgen", "tomorrow": return calendar.date(byAdding: .day, value: 1, to: todayStart)!
        case "gisteren", "yesterday": return calendar.date(byAdding: .day, value: -1, to: todayStart)!
        default: break
        }
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, text.count == 10 else {
            throw ToolError(message: "Invalid date '\(raw)'. Use the format YYYY-MM-DD (e.g. 2026-11-23), or 'today' / 'tomorrow'.")
        }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        guard let date = calendar.date(from: comps), dayString(date) == text else {
            throw ToolError(message: "Date '\(raw)' does not exist in the calendar.")
        }
        return date
    }

    var timeZoneInfo: [String: Any] {
        let seconds = timeZone.secondsFromGMT(for: now)
        let sign = seconds < 0 ? "-" : "+"
        let offset = String(format: "%@%02d:%02d", sign, abs(seconds) / 3600, (abs(seconds) % 3600) / 60)
        return [
            "identifier": timeZone.identifier,
            "utc_offset": offset,
            "abbreviation": orNull(timeZone.abbreviation(for: now)),
            "source": "System time zone of this Mac, read again on every call",
        ]
    }
}

// MARK: - Access

let accessHelpSteps: [String] = [
    "Open System Settings > Privacy & Security > Reminders.",
    "Find the app that starts this server (e.g. Codex, Terminal, iTerm or 'reminders-mcp') and turn the switch on / choose 'Full Access'.",
    "Is the app not listed? Then run `tccutil reset Reminders` in Terminal and start the server again; macOS will then show the permission prompt again.",
    "Afterwards, restart the app that starts the MCP server so the new permission takes effect.",
]

let accessScopeNote =
    "EventKit has no separate read permission for Reminders: 'full access' is the smallest permission that allows reading. By default this server only reads; creating, editing and deleting are disabled unless the user enables them with REMINDERS_MCP_WRITE."

func statusName(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "full_access"
    case .writeOnly: return "write_only"
    @unknown default: return "authorized_legacy"
    }
}

func accessReport(_ status: EKAuthorizationStatus) -> [String: Any] {
    var report: [String: Any] = [
        "status": statusName(status),
        "permission_scope": accessScopeNote,
    ]
    switch status {
    case .fullAccess:
        report["can_read"] = true
        report["explanation"] = "Access to Reminders has been granted. The server can read reminders."
    case .notDetermined:
        report["can_read"] = false
        report["explanation"] = "No choice has been made yet. On the first read, macOS shows a permission prompt; choose 'Allow' / 'Full Access' there. If no prompt appears, follow the steps."
        report["steps"] = accessHelpSteps
    case .denied:
        report["can_read"] = false
        report["explanation"] = "Access to Reminders has been denied for the app that starts this server. macOS will not ask again; turn access on manually."
        report["steps"] = accessHelpSteps
    case .restricted:
        report["can_read"] = false
        report["explanation"] = "Access to Reminders is blocked on this Mac by a restriction (e.g. an employer's MDM profile or Screen Time). Only an administrator can lift this."
        report["steps"] = ["Check System Settings > Screen Time > Content & Privacy.", "Ask the administrator of this Mac whether a configuration profile blocks access to Reminders."]
    case .writeOnly:
        report["can_read"] = false
        report["explanation"] = "Only write access has been granted; reading is not possible with that. Choose 'Full Access' in System Settings."
        report["steps"] = accessHelpSteps
    @unknown default:
        report["can_read"] = true
        report["explanation"] = "Access granted (legacy permission type)."
    }
    return report
}

struct AccessDenied: Error {
    let report: [String: Any]
}

/// Returns a fresh EKEventStore (per call, so iCloud changes are always visible)
/// and requests permission once if needed.
func obtainStore(promptIfNeeded: Bool = true) throws -> EKEventStore {
    var status = EKEventStore.authorizationStatus(for: .reminder)
    if status == .notDetermined && promptIfNeeded {
        log("permission not determined yet; macOS permission prompt requested")
        let requester = EKEventStore()
        let done = DispatchSemaphore(value: 0)
        requester.requestFullAccessToReminders { granted, error in
            let code = (error as NSError?).map { "\($0.domain) \($0.code)" } ?? "no error"
            log("permission request finished: granted=\(granted) (\(code))")
            done.signal()
        }
        if done.wait(timeout: .now() + 120) == .timedOut {
            var report = accessReport(.notDetermined)
            report["explanation"] = "The macOS permission prompt was requested but not answered within 2 minutes (or macOS could not show it). Answer the prompt and try again."
            throw AccessDenied(report: report)
        }
        status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            var report = accessReport(.notDetermined)
            report["explanation"] = "macOS handled the permission request without showing a prompt and without granting access. This happens when the process is not allowed to show a permission prompt (e.g. started from a background process without a screen session). Run `reminders-mcp --check` once in Terminal and choose 'Allow'; after that the server also works from the agent."
            throw AccessDenied(report: report)
        }
    }
    let report = accessReport(status)
    guard report["can_read"] as? Bool == true else { throw AccessDenied(report: report) }
    return EKEventStore()
}

// MARK: - Fetching (read-only)

func reminderCalendars(_ store: EKEventStore, filter: [String]?) throws -> [EKCalendar] {
    let all = store.calendars(for: .reminder)
    guard let filter, !filter.isEmpty else { return all }
    var selected: [EKCalendar] = []
    var unknown: [String] = []
    for name in filter {
        let matches = all.filter { $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if matches.isEmpty { unknown.append(name) } else { selected.append(contentsOf: matches) }
    }
    if !unknown.isEmpty {
        let available = all.map { $0.title }.sorted().joined(separator: ", ")
        throw ToolError(message: "Unknown list(s): \(unknown.joined(separator: ", ")). Available lists: \(available)")
    }
    return selected
}

func fetchOpenReminders(_ store: EKEventStore, calendars: [EKCalendar]) -> [EKReminder] {
    if calendars.isEmpty { return [] }
    let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
    let result = Box<[EKReminder]>([])
    let done = DispatchSemaphore(value: 0)
    store.fetchReminders(matching: predicate) { reminders in
        result.value = reminders ?? []
        done.signal()
    }
    done.wait()
    return result.value.filter { !$0.isCompleted }
}

// MARK: - Due date

struct Due {
    let instant: Date
    let allDay: Bool
    let originalTimeZone: TimeZone?
}

func resolveDate(_ components: DateComponents?, local: LocalTime) -> Due? {
    guard let c = components, let year = c.year, let month = c.month, let day = c.day else { return nil }
    let allDay = c.hour == nil
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    var cal = local.calendar
    if !allDay {
        comps.hour = c.hour; comps.minute = c.minute ?? 0; comps.second = c.second ?? 0
        // A time with a time zone is a fixed instant; without a time zone it is a "floating" local time.
        if let tz = c.timeZone { cal.timeZone = tz }
    }
    guard let instant = cal.date(from: comps) else { return nil }
    return Due(instant: instant, allDay: allDay, originalTimeZone: allDay ? nil : c.timeZone)
}

func dateJSON(_ due: Due, local: LocalTime) -> [String: Any] {
    [
        "date": local.dayString(due.instant),
        "time": due.allDay ? NSNull() : local.timeString(due.instant) as Any,
        "all_day": due.allDay,
        "iso": due.allDay ? local.dayString(due.instant) : local.iso(due.instant),
        "original_time_zone": orNull(due.originalTimeZone?.identifier),
    ]
}

// MARK: - Recurrence, priority, alarms

let weekdayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
let monthNames = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

func recurrenceJSON(_ reminder: EKReminder, local: LocalTime) -> [String: Any] {
    guard reminder.hasRecurrenceRules, let rules = reminder.recurrenceRules, !rules.isEmpty else {
        return ["is_recurring": false]
    }
    var out: [[String: Any]] = []
    var summaries: [String] = []
    for rule in rules {
        let (code, singular, plural): (String, String, String)
        switch rule.frequency {
        case .daily: (code, singular, plural) = ("daily", "day", "days")
        case .weekly: (code, singular, plural) = ("weekly", "week", "weeks")
        case .monthly: (code, singular, plural) = ("monthly", "month", "months")
        case .yearly: (code, singular, plural) = ("yearly", "year", "years")
        @unknown default: (code, singular, plural) = ("unknown", "period", "periods")
        }
        var item: [String: Any] = ["frequency": code, "interval": rule.interval]
        var summary = rule.interval == 1 ? "every \(singular)" : "every \(rule.interval) \(plural)"
        if code == "yearly" && rule.interval == 1 { summary = "every year" }

        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let labels = days.map { d -> String in
                let name = weekdayNames[min(max(d.dayOfTheWeek.rawValue, 0), 7)]
                return d.weekNumber == 0 ? name : "#\(d.weekNumber) \(name)"
            }
            item["days_of_week"] = labels
            summary += " on " + labels.joined(separator: ", ")
        }
        if let days = rule.daysOfTheMonth, !days.isEmpty {
            item["days_of_month"] = days.map { $0.intValue }
            summary += " on day " + days.map { $0.stringValue }.joined(separator: ", ")
        }
        if let months = rule.monthsOfTheYear, !months.isEmpty {
            let labels = months.map { monthNames[min(max($0.intValue, 0), 12)] }
            item["months"] = labels
            summary += " in " + labels.joined(separator: ", ")
        }
        if let positions = rule.setPositions, !positions.isEmpty {
            item["set_positions"] = positions.map { $0.intValue }
        }
        if let end = rule.recurrenceEnd {
            if let endDate = end.endDate {
                item["ends_on"] = local.dayString(endDate)
                summary += " until \(local.dayString(endDate))"
            } else if end.occurrenceCount > 0 {
                item["ends_after_occurrences"] = end.occurrenceCount
                summary += end.occurrenceCount == 1 ? ", once" : ", \(end.occurrenceCount) times"
            }
        } else {
            item["ends_on"] = NSNull()
        }
        item["summary"] = summary
        summaries.append(summary)
        out.append(item)
    }
    return ["is_recurring": true, "summary": summaries.joined(separator: "; "), "rules": out]
}

func priorityJSON(_ value: Int) -> [String: Any] {
    let label: String
    switch value {
    case 0: label = "none"
    case 1...4: label = "high"
    case 5: label = "medium"
    default: label = "low"
    }
    return ["value": value, "label": label, "scale": "0 = none, 1-4 = high, 5 = medium, 6-9 = low"]
}

func alarmsJSON(_ reminder: EKReminder, local: LocalTime) -> [[String: Any]] {
    guard reminder.hasAlarms, let alarms = reminder.alarms else { return [] }
    return alarms.map { alarm in
        if let location = alarm.structuredLocation {
            let proximity: String
            switch alarm.proximity {
            case .enter: proximity = "on arrival"
            case .leave: proximity = "on departure"
            default: proximity = "unknown"
            }
            return ["type": "location", "location": orNull(location.title), "trigger": proximity]
        }
        if let date = alarm.absoluteDate {
            return ["type": "time", "at": local.iso(date)]
        }
        return ["type": "relative", "offset_seconds": Int(alarm.relativeOffset)]
    }
}

// MARK: - Subtasks (optional, via the local Reminders database)

let subtasksEventKitNote =
    "EventKit does not return a parent/child relationship between reminders. Subtasks are included in the results, but as ordinary, separate reminders without a reference to their parent task."

struct SubtaskLookup {
    /// child id -> parent id (ids as EventKit knows them)
    var parentOf: [String: String] = [:]
    var status: String = "unavailable"
    var note: String = subtasksEventKitNote
}

/// Reads only id pairs (child, parent) from the local Reminders database. No title, note or
/// other content is read from the database. Only active with
/// REMINDERS_MCP_SUBTASKS=sqlite; requires Full Disk Access for the app that starts the server.
func loadSubtaskLookup() -> SubtaskLookup {
    var lookup = SubtaskLookup()
    guard ProcessInfo.processInfo.environment["REMINDERS_MCP_SUBTASKS"]?.lowercased() == "sqlite" else {
        lookup.note = subtasksEventKitNote + " Optionally the server can read the relationship from the local Reminders database (set REMINDERS_MCP_SUBTASKS=sqlite; requires Full Disk Access). This is currently disabled."
        return lookup
    }
    let storesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
    guard let files = try? FileManager.default.contentsOfDirectory(at: storesURL, includingPropertiesForKeys: nil) else {
        lookup.status = "sqlite_no_access"
        lookup.note = subtasksEventKitNote + " The database enrichment is enabled, but the folder containing the Reminders database is not readable. Give the app that starts this server Full Disk Access (System Settings > Privacy & Security > Full Disk Access) or turn REMINDERS_MCP_SUBTASKS off."
        return lookup
    }
    var databasesRead = 0
    for file in files where file.pathExtension == "sqlite" {
        var db: OpaquePointer?
        guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            continue
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)

        var columns = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(ZREMCDREMINDER)", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let name = sqlite3_column_text(stmt, 1) { columns.insert(String(cString: name)) }
            }
        }
        sqlite3_finalize(stmt)
        guard columns.contains("ZPARENTREMINDER") else { continue }
        let deletedClause = columns.contains("ZMARKEDFORDELETION") ? " AND IFNULL(c.ZMARKEDFORDELETION, 0) = 0" : ""

        for idColumn in ["ZDACALENDARITEMUNIQUEIDENTIFIER", "ZCKIDENTIFIER"] where columns.contains(idColumn) {
            let sql = "SELECT c.\(idColumn), p.\(idColumn) FROM ZREMCDREMINDER c JOIN ZREMCDREMINDER p ON c.ZPARENTREMINDER = p.Z_PK WHERE c.ZPARENTREMINDER IS NOT NULL\(deletedClause)"
            var query: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &query, nil) == SQLITE_OK {
                while sqlite3_step(query) == SQLITE_ROW {
                    guard sqlite3_column_type(query, 0) == SQLITE_TEXT, sqlite3_column_type(query, 1) == SQLITE_TEXT,
                          let child = sqlite3_column_text(query, 0), let parent = sqlite3_column_text(query, 1)
                    else { continue }
                    lookup.parentOf[String(cString: child)] = String(cString: parent)
                }
            }
            sqlite3_finalize(query)
        }
        databasesRead += 1
    }
    if databasesRead == 0 {
        lookup.status = "sqlite_schema_unsupported"
        lookup.note = subtasksEventKitNote + " The database enrichment is enabled, but the (undocumented) database schema of this macOS version is not recognized. Subtask relationships are therefore not available."
    } else {
        lookup.status = "sqlite_ok"
        lookup.note = "Subtask relationships were added from the local Reminders database (only ids read, undocumented schema, may stop working after a macOS update). Only open subtasks are shown; completed subtasks are not."
    }
    return lookup
}

// MARK: - Reminder -> JSON

struct Item {
    let reminder: EKReminder
    let due: Due?
    var keys: [String] { [reminder.calendarItemExternalIdentifier, reminder.calendarItemIdentifier].compactMap { $0 } }
}

func sortItems(_ items: [Item]) -> [Item] {
    func rank(_ p: Int) -> Int { p == 0 ? 10 : p }
    return items.sorted { a, b in
        switch (a.due, b.due) {
        case let (x?, y?) where x.instant != y.instant: return x.instant < y.instant
        case (_?, nil): return true
        case (nil, _?): return false
        default: break
        }
        if rank(a.reminder.priority) != rank(b.reminder.priority) { return rank(a.reminder.priority) < rank(b.reminder.priority) }
        return (a.reminder.title ?? "").localizedCaseInsensitiveCompare(b.reminder.title ?? "") == .orderedAscending
    }
}

struct Renderer {
    let local: LocalTime
    let includeNotes: Bool
    let lookup: SubtaskLookup
    let byKey: [String: Item]
    let childrenOf: [String: [Item]]

    init(items: [Item], local: LocalTime, includeNotes: Bool, lookup: SubtaskLookup) {
        self.local = local
        self.includeNotes = includeNotes
        self.lookup = lookup
        var byKey: [String: Item] = [:]
        for item in items { for key in item.keys { byKey[key] = item } }
        var children: [String: [Item]] = [:]
        if !lookup.parentOf.isEmpty {
            for item in items {
                guard let parentKey = item.keys.compactMap({ lookup.parentOf[$0] }).first,
                      let parent = byKey[parentKey] else { continue }
                children[parent.reminder.calendarItemIdentifier, default: []].append(item)
            }
        }
        self.byKey = byKey
        self.childrenOf = children
    }

    func dueFields(_ item: Item) -> [String: Any] {
        var out: [String: Any] = [:]
        if let due = item.due {
            out["has_due_date"] = true
            out["due"] = dateJSON(due, local: local)
            let overdue = due.allDay ? due.instant < local.todayStart : due.instant < local.now
            out["is_overdue"] = overdue
            if due.instant < local.todayStart {
                let days = local.calendar.dateComponents([.day], from: local.calendar.startOfDay(for: due.instant), to: local.todayStart).day ?? 0
                out["days_overdue"] = days
            }
        } else {
            out["has_due_date"] = false
            out["due"] = NSNull()
            out["due_note"] = "No due date set."
            out["is_overdue"] = false
        }
        return out
    }

    func render(_ item: Item) -> [String: Any] {
        let r = item.reminder
        var out: [String: Any] = dueFields(item)
        out["id"] = r.calendarItemIdentifier
        out["title"] = r.title ?? ""
        out["list"] = orNull(r.calendar?.title)
        out["account"] = orNull(r.calendar?.source?.title)
        out["priority"] = priorityJSON(r.priority)
        out["recurrence"] = recurrenceJSON(r, local: local)
        out["alarms"] = alarmsJSON(r, local: local)
        if let start = resolveDate(r.startDateComponents, local: local) { out["start"] = dateJSON(start, local: local) }
        if let url = r.url { out["url"] = url.absoluteString }
        if let created = r.creationDate { out["created_at"] = local.iso(created) }
        if let modified = r.lastModifiedDate { out["modified_at"] = local.iso(modified) }

        let notes = r.hasNotes ? r.notes : nil
        out["has_notes"] = !(notes ?? "").isEmpty
        if includeNotes { out["notes"] = orNull((notes ?? "").isEmpty ? nil : notes) }

        if lookup.status == "sqlite_ok" {
            let children = sortItems(childrenOf[r.calendarItemIdentifier] ?? [])
            out["subtasks"] = children.map { child -> [String: Any] in
                var c = dueFields(child)
                c["id"] = child.reminder.calendarItemIdentifier
                c["title"] = child.reminder.title ?? ""
                return c
            }
            if let parentKey = item.keys.compactMap({ lookup.parentOf[$0] }).first {
                out["is_subtask"] = true
                if let parent = byKey[parentKey] {
                    out["parent"] = ["id": parent.reminder.calendarItemIdentifier, "title": parent.reminder.title ?? ""]
                } else {
                    out["parent"] = NSNull()
                    out["parent_note"] = "Parent task is completed or falls outside the requested lists."
                }
            } else {
                out["is_subtask"] = false
            }
        } else {
            out["subtasks"] = NSNull()
        }
        return out
    }
}

func fieldAvailability(_ lookup: SubtaskLookup) -> [String: Any] {
    [
        "available_via_eventkit": ["title", "list", "account", "due date/time", "start date", "notes", "priority", "recurrence", "alarms (time and location)", "created/modified"],
        "subtasks": ["status": lookup.status, "note": lookup.note],
        "not_available_via_eventkit": [
            "tags": "Tags (#) are not returned by EventKit.",
            "flagged": "The flag is not available.",
            "sections_and_columns": "Sections/columns within a list are not available.",
            "smart_lists": "Smart lists (Today, Scheduled, custom smart lists) do not exist in EventKit; this server computes the daily overview itself.",
            "attachments": "Images and attachments are not available.",
            "url_field": "The URL field from the Reminders app usually does not come through via EventKit; 'url' is then missing.",
            "assignee": "Assignment in shared lists is not available.",
            "early_reminder_and_messaging": "'Early Reminder' and 'When Messaging' are not (reliably) available.",
        ],
    ]
}

// MARK: - Tools

func loadItems(_ store: EKEventStore, lists: [String]?, local: LocalTime) throws -> [Item] {
    let calendars = try reminderCalendars(store, filter: lists)
    return fetchOpenReminders(store, calendars: calendars).map {
        Item(reminder: $0, due: resolveDate($0.dueDateComponents, local: local))
    }
}

func stringArray(_ value: Any?) -> [String]? {
    if let array = value as? [String] { return array }
    if let single = value as? String, !single.isEmpty { return [single] }
    return nil
}

func toolDailyOverview(_ args: [String: Any]) throws -> [String: Any] {
    let local = LocalTime()
    let target = try local.parseDay(args["date"] as? String ?? "today")
    let targetEnd = local.calendar.date(byAdding: .day, value: 1, to: target)!
    let includeOverdue = args["include_overdue"] as? Bool ?? true
    let includeUndated = args["include_undated"] as? Bool ?? false
    let includeNotes = args["include_notes"] as? Bool ?? true

    let store = try obtainStore()
    let items = try loadItems(store, lists: stringArray(args["lists"]), local: local)
    let renderer = Renderer(items: items, local: local, includeNotes: includeNotes, lookup: loadSubtaskLookup())

    let overdueBefore = min(target, local.todayStart)
    var dueOnDate: [Item] = [], overdue: [Item] = [], undated: [Item] = []
    for item in items {
        guard let due = item.due else { undated.append(item); continue }
        if due.instant >= target && due.instant < targetEnd { dueOnDate.append(item) }
        else if due.instant < overdueBefore { overdue.append(item) }
    }

    let dateText = local.dayString(target)
    let isToday = target == local.todayStart
    var result: [String: Any] = [
        "date": dateText,
        "is_today": isToday,
        "generated_at": local.iso(local.now),
        "time_zone": local.timeZoneInfo,
        "definition": [
            "day": "The requested day is the calendar day \(dateText) from 00:00 to 24:00 in the local time zone of this Mac (\(local.timeZone.identifier)). Without 'date' that is the day of 'generated_at'.",
            "due_on_date": "Open reminders whose due date falls on that day. Reminders with a time zone are first converted to local time; all-day reminders count on their calendar date. A time that has already passed today stays here, with is_overdue = true.",
            "overdue": "Open reminders with a due date before 00:00 on \(local.dayString(overdueBefore)) (the earlier of the requested day and today). Separate from 'due_on_date'.",
            "undated": "Open reminders without a due date; only included with include_undated = true.",
            "scope": "Only incomplete reminders from all accounts that sync with Reminders on this Mac (iCloud and any others).",
        ],
        "due_on_date": sortItems(dueOnDate).map(renderer.render),
        "counts": [
            "due_on_date": dueOnDate.count,
            "overdue": overdue.count,
            "undated": undated.count,
            "open_total": items.count,
        ],
        "field_availability": fieldAvailability(renderer.lookup),
        "read_only": true,
    ]
    if includeOverdue { result["overdue"] = sortItems(overdue).map(renderer.render) }
    else { result["overdue_note"] = "Overdue reminders have been omitted (include_overdue = false); see counts.overdue." }
    if includeUndated { result["undated"] = sortItems(undated).map(renderer.render) }
    else if !undated.isEmpty { result["undated_note"] = "\(undated.count) open reminder(s) without a due date are not included. Use include_undated = true or reminders_list_open." }
    log("reminders_daily_overview: due_on_date=\(dueOnDate.count) overdue=\(overdue.count) undated=\(undated.count)")
    return result
}

func toolListOpen(_ args: [String: Any]) throws -> [String: Any] {
    let local = LocalTime()
    let from = try (args["due_from"] as? String).map { try local.parseDay($0) }
    let toDay = try (args["due_to"] as? String).map { try local.parseDay($0) }
    let toEnd = toDay.map { local.calendar.date(byAdding: .day, value: 1, to: $0)! }
    let includeUndated = args["include_undated"] as? Bool ?? true
    let includeNotes = args["include_notes"] as? Bool ?? true
    let limit = (args["limit"] as? NSNumber)?.intValue

    let store = try obtainStore()
    let items = try loadItems(store, lists: stringArray(args["lists"]), local: local)
    let renderer = Renderer(items: items, local: local, includeNotes: includeNotes, lookup: loadSubtaskLookup())

    var selected = sortItems(items.filter { item in
        guard let due = item.due else { return includeUndated }
        if let from, due.instant < from { return false }
        if let toEnd, due.instant >= toEnd { return false }
        return true
    })
    let matched = selected.count
    if let limit, limit > 0, selected.count > limit { selected = Array(selected.prefix(limit)) }

    log("reminders_list_open: returned=\(selected.count) matched=\(matched)")
    return [
        "generated_at": local.iso(local.now),
        "time_zone": local.timeZoneInfo,
        "filter": [
            "due_from": orNull(from.map(local.dayString)),
            "due_to": orNull(toDay.map(local.dayString)),
            "include_undated": includeUndated,
            "note": "due_from and due_to are calendar days (inclusive) in the local time zone of this Mac.",
        ],
        "counts": [
            "returned": selected.count,
            "matched": matched,
            "truncated": selected.count < matched,
            "open_total": items.count,
            "without_due_date": selected.filter { $0.due == nil }.count,
        ],
        "sort": "By due date (oldest first), then priority; reminders without a due date come last.",
        "reminders": selected.map(renderer.render),
        "field_availability": fieldAvailability(renderer.lookup),
        "read_only": true,
    ]
}

func toolLists(_ args: [String: Any]) throws -> [String: Any] {
    let local = LocalTime()
    let store = try obtainStore()
    let calendars = store.calendars(for: .reminder)
    let items = fetchOpenReminders(store, calendars: calendars)
    var openCount: [String: Int] = [:]
    for item in items { if let id = item.calendar?.calendarIdentifier { openCount[id, default: 0] += 1 } }
    let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
    let lists: [[String: Any]] = calendars
        .sorted { ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title) }
        .map { [
            "name": $0.title,
            "account": orNull($0.source?.title),
            "open_reminders": openCount[$0.calendarIdentifier] ?? 0,
            "is_default": $0.calendarIdentifier == defaultID,
        ] }
    log("reminders_lists: lists=\(lists.count)")
    return [
        "generated_at": local.iso(local.now),
        "lists": lists,
        "note": "Smart lists and list groups (folders) are not visible via EventKit.",
        "read_only": true,
    ]
}

func toolAccessStatus(_ args: [String: Any]) -> [String: Any] {
    let local = LocalTime()
    var report = accessReport(EKEventStore.authorizationStatus(for: .reminder))
    report["time_zone"] = local.timeZoneInfo
    report["today"] = local.dayString(local.now)
    report["read_only"] = !writeAccess.any
    report["write_tools"] = writeAccess.summary
    report["write_setting_source"] = writeAccess.source
    report["subtasks"] = ["note": subtasksEventKitNote, "sqlite_enrichment_enabled": ProcessInfo.processInfo.environment["REMINDERS_MCP_SUBTASKS"]?.lowercased() == "sqlite"]
    report["responsible_app_note"] = "macOS ties the permission to the app that starts this server (e.g. Codex or Terminal). So every launching app needs its own permission."
    return report
}

let listsProperty: [String: Any] = [
    "type": "array", "items": ["type": "string"],
    "description": "Optional: restrict to these list names (case-insensitive). Defaults to all lists.",
]
let notesProperty: [String: Any] = [
    "type": "boolean",
    "description": "Include notes (default true). With false only has_notes remains.",
]
let readOnlyAnnotations: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]

let readToolDefinitions: [[String: Any]] = [
    [
        "name": "reminders_daily_overview",
        "title": "Reminders daily overview",
        "description": "Read-only daily overview of open Apple Reminders on this Mac (including iCloud lists). Returns two separate groups: 'due_on_date' (actually scheduled for the requested day) and 'overdue' (open and overdue from earlier days). Without 'date' the day is today: the calendar day from 00:00 to 24:00 in the Mac's local time zone. Per reminder: title, list, account, due date and time, notes, priority, recurrence, alarms and (if available) subtasks. 'field_availability' states which fields EventKit does not provide. Use this tool for daily planning; it never changes anything.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "date": ["type": "string", "description": "Day in local time, format YYYY-MM-DD, or 'today' / 'tomorrow' / 'yesterday'. Defaults to today."],
                "include_overdue": ["type": "boolean", "description": "Include overdue open reminders in the separate group 'overdue' (default true)."],
                "include_undated": ["type": "boolean", "description": "Also include open reminders without a due date in the group 'undated' (default false)."],
                "include_notes": notesProperty,
                "lists": listsProperty,
            ],
            "additionalProperties": false,
        ],
        "annotations": readOnlyAnnotations,
    ],
    [
        "name": "reminders_list_open",
        "title": "All open reminders",
        "description": "Read-only: returns the full list of all open (incomplete) Apple Reminders, including overdue ones and reminders without a due date (those get has_due_date = false). Can optionally be filtered by list and by a range of due dates. Every reminder has is_overdue and the same fields as the daily overview. Use this when the daily overview is not enough, for example for weekly planning or a full inventory.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "due_from": ["type": "string", "description": "Only reminders with a due date on or after this day (YYYY-MM-DD, local time)."],
                "due_to": ["type": "string", "description": "Only reminders with a due date up to and including this day (YYYY-MM-DD, local time)."],
                "include_undated": ["type": "boolean", "description": "Include reminders without a due date (default true)."],
                "include_notes": notesProperty,
                "lists": listsProperty,
                "limit": ["type": "integer", "minimum": 1, "description": "Maximum number of results. No limit by default; counts.truncated reports whether the result was cut off."],
            ],
            "additionalProperties": false,
        ],
        "annotations": readOnlyAnnotations,
    ],
    [
        "name": "reminders_lists",
        "title": "Reminder lists",
        "description": "Read-only: shows all lists in Apple Reminders with account (e.g. iCloud) and the number of open reminders per list. Useful for finding list names for the 'lists' parameter.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": readOnlyAnnotations,
    ],
    [
        "name": "reminders_access_status",
        "title": "Reminders access status",
        "description": "Checks whether this server has permission from macOS to read Reminders, without opening a permission prompt itself. If access is missing or denied, returns the steps to allow it in System Settings, plus the time zone and date that count as 'today'.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": readOnlyAnnotations,
    ],
]

// MARK: - Writing (off by default)

/// Write tools are only offered when the user enables them via REMINDERS_MCP_WRITE.
struct WriteAccess {
    let create: Bool
    let update: Bool
    let delete: Bool
    let source: String
    var any: Bool { create || update || delete }

    init() {
        // Order: --write=... argument, then REMINDERS_MCP_WRITE, then ~/.config/reminders-mcp/write.
        // The file exists because some hosts start the server without passing configured env vars.
        let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--write=") }).map { String($0.dropFirst("--write=".count)) }
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/reminders-mcp/write")
        let fileValue = (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if let argument { raw = argument; source = "--write argument" }
        else if let env = ProcessInfo.processInfo.environment["REMINDERS_MCP_WRITE"] { raw = env; source = "REMINDERS_MCP_WRITE" }
        else if let fileValue { raw = fileValue; source = "~/.config/reminders-mcp/write" }
        else { raw = ""; source = "default" }
        let parts = Set(raw.lowercased().split(whereSeparator: { ", ;".contains($0) }).map(String.init))
        let all = parts.contains("all")
        create = all || parts.contains("create")
        update = all || parts.contains("update")
        delete = all || parts.contains("delete")
    }

    var summary: String {
        if !any { return "The server is read-only: creating, editing, completing and deleting are disabled." }
        var on: [String] = []
        if create { on.append("creating (reminders_create, reminders_create_list)") }
        if update { on.append("editing and completing (reminders_update)") }
        if delete { on.append("deleting (reminders_delete)") }
        return "Writing has been enabled by the user for: " + on.joined(separator: ", ") + ". Everything else is read-only."
    }
}

let writeAccess = WriteAccess()

func parseDueComponents(_ raw: String, local: LocalTime) throws -> DateComponents {
    let text = raw.trimmingCharacters(in: .whitespaces)
    var dayPart = text
    var hour: Int?
    var minute = 0
    if let split = text.lastIndex(where: { $0 == " " || $0 == "T" }), text[text.index(after: split)...].contains(":") {
        dayPart = String(text[..<split])
        let timeText = String(text[text.index(after: split)...])
        let pieces = timeText.split(separator: ":").map { Int($0) }
        guard timeText.allSatisfy({ $0.isNumber || $0 == ":" }), pieces.count >= 2,
              let h = pieces[0], let m = pieces[1], (0...23).contains(h), (0...59).contains(m) else {
            throw ToolError(message: "Invalid time in '\(raw)'. Use local time as YYYY-MM-DD HH:MM (e.g. 2026-11-23 09:30), without a time zone.")
        }
        hour = h; minute = m
    }
    let day = try local.parseDay(dayPart)
    let ymd = local.calendar.dateComponents([.year, .month, .day], from: day)
    var comps = DateComponents()
    comps.year = ymd.year; comps.month = ymd.month; comps.day = ymd.day
    if let hour {
        comps.hour = hour; comps.minute = minute; comps.second = 0
        comps.timeZone = local.timeZone
    }
    return comps
}

func parsePriority(_ value: Any) throws -> Int {
    if let number = value as? NSNumber, !(value is String), (0...9).contains(number.intValue) { return number.intValue }
    switch (value as? String)?.lowercased() {
    case "none", "geen", "": return 0
    case "high", "hoog": return 1
    case "medium", "normaal", "normal": return 5
    case "low", "laag": return 9
    default: throw ToolError(message: "Invalid priority. Use none, low, medium or high.")
    }
}

func parseRecurrence(_ dict: [String: Any], local: LocalTime) throws -> EKRecurrenceRule {
    let frequency: EKRecurrenceFrequency
    switch (dict["frequency"] as? String)?.lowercased() {
    case "daily", "dagelijks": frequency = .daily
    case "weekly", "wekelijks": frequency = .weekly
    case "monthly", "maandelijks": frequency = .monthly
    case "yearly", "jaarlijks": frequency = .yearly
    default: throw ToolError(message: "recurrence.frequency must be daily, weekly, monthly or yearly.")
    }
    let interval = (dict["interval"] as? NSNumber)?.intValue ?? 1
    guard interval >= 1 else { throw ToolError(message: "recurrence.interval must be 1 or higher.") }

    var days: [EKRecurrenceDayOfWeek]?
    if let names = stringArray(dict["days_of_week"]) {
        let map = ["su": 1, "zo": 1, "mo": 2, "ma": 2, "tu": 3, "di": 3, "we": 4, "wo": 4, "th": 5, "do": 5, "fr": 6, "vr": 6, "sa": 7, "za": 7]
        days = try names.map { name in
            guard let raw = map[String(name.lowercased().prefix(2))], let weekday = EKWeekday(rawValue: raw) else {
                throw ToolError(message: "Unknown weekday '\(name)'. Use mo, tu, we, th, fr, sa, su (or ma, di, wo, do, vr, za, zo).")
            }
            return EKRecurrenceDayOfWeek(weekday)
        }
    }
    var end: EKRecurrenceEnd?
    if let endText = dict["end_date"] as? String {
        let endDay = try local.parseDay(endText)
        end = EKRecurrenceEnd(end: local.calendar.date(byAdding: DateComponents(day: 1, second: -1), to: endDay)!)
    } else if let count = (dict["count"] as? NSNumber)?.intValue, count > 0 {
        end = EKRecurrenceEnd(occurrenceCount: count)
    }
    return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, daysOfTheWeek: days, daysOfTheMonth: nil,
                            monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
}

func writableList(_ store: EKEventStore, named name: String) throws -> EKCalendar {
    let matches = try reminderCalendars(store, filter: [name])
    guard matches.count == 1 else {
        throw ToolError(message: "There are \(matches.count) lists named '\(name)'; choose a unique list name.")
    }
    guard matches[0].allowsContentModifications else {
        throw ToolError(message: "The list '\(name)' is read-only and cannot be modified.")
    }
    return matches[0]
}

/// Applies only the fields present in `args`. JSON null clears a field (due, notes, recurrence).
func applyFields(_ reminder: EKReminder, _ args: [String: Any], store: EKEventStore, local: LocalTime) throws {
    if let title = args["title"] as? String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError(message: "title must not be empty.") }
        reminder.title = title
    }
    if let notes = args["notes"] {
        let text = notes as? String
        reminder.notes = (text ?? "").isEmpty ? nil : text
    }
    if let priority = args["priority"] { reminder.priority = try parsePriority(priority) }
    if let list = args["list"] as? String { reminder.calendar = try writableList(store, named: list) }
    if let due = args["due"] {
        // Time alarms belong to the due date and are replaced along with it; location alarms are kept.
        for alarm in reminder.alarms ?? [] where alarm.structuredLocation == nil { reminder.removeAlarm(alarm) }
        if let text = due as? String, !text.isEmpty {
            let comps = try parseDueComponents(text, local: local)
            reminder.dueDateComponents = comps
            if comps.hour != nil, let moment = local.calendar.date(from: comps) {
                reminder.addAlarm(EKAlarm(absoluteDate: moment))
            }
        } else {
            reminder.dueDateComponents = nil
        }
    }
    if let recurrence = args["recurrence"] {
        for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
        if let dict = recurrence as? [String: Any] { reminder.addRecurrenceRule(try parseRecurrence(dict, local: local)) }
    }
    if reminder.hasRecurrenceRules && reminder.dueDateComponents == nil {
        throw ToolError(message: "A recurring reminder needs a due date; provide 'due' or remove the recurrence.")
    }
    if let completed = args["completed"] as? Bool { reminder.isCompleted = completed }
}

func renderWritten(_ reminder: EKReminder, local: LocalTime) -> [String: Any] {
    let item = Item(reminder: reminder, due: resolveDate(reminder.dueDateComponents, local: local))
    var out = Renderer(items: [item], local: local, includeNotes: true, lookup: SubtaskLookup()).render(item)
    out["completed"] = reminder.isCompleted
    out["subtasks"] = NSNull()
    return out
}

func findReminder(_ store: EKEventStore, _ args: [String: Any]) throws -> EKReminder {
    guard let id = args["id"] as? String, !id.isEmpty else { throw ToolError(message: "Parameter 'id' is missing.") }
    guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
        throw ToolError(message: "No reminder found with this id. Ids can change after an iCloud sync; fetch the reminder again.")
    }
    return reminder
}

func saveError(_ error: Error) -> ToolError {
    let ns = error as NSError
    return ToolError(message: "macOS could not save the change (\(ns.domain) \(ns.code)).")
}

func toolCreate(_ args: [String: Any]) throws -> [String: Any] {
    let local = LocalTime()
    guard args["title"] is String else { throw ToolError(message: "Parameter 'title' is missing.") }
    let store = try obtainStore()
    let reminder = EKReminder(eventStore: store)
    if args["list"] == nil {
        guard let fallback = store.defaultCalendarForNewReminders() else {
            throw ToolError(message: "No default list is set; provide 'list'.")
        }
        reminder.calendar = fallback
    }
    try applyFields(reminder, args, store: store, local: local)
    do { try store.save(reminder, commit: true) } catch { throw saveError(error) }
    log("reminders_create: 1 reminder created")
    return ["created": true, "reminder": renderWritten(reminder, local: local),
            "id_note": "The id can change after the first iCloud sync."]
}

func toolUpdate(_ args: [String: Any]) throws -> [String: Any] {
    let local = LocalTime()
    let store = try obtainStore()
    let reminder = try findReminder(store, args)
    let fields = ["title", "notes", "priority", "list", "due", "recurrence", "completed"].filter { args[$0] != nil }
    guard !fields.isEmpty else { throw ToolError(message: "No fields to change were provided.") }
    try applyFields(reminder, args, store: store, local: local)
    do { try store.save(reminder, commit: true) } catch { throw saveError(error) }
    log("reminders_update: 1 reminder updated (\(fields.joined(separator: ",")))")
    return ["updated": true, "changed_fields": fields, "reminder": renderWritten(reminder, local: local)]
}

func toolDelete(_ args: [String: Any]) throws -> [String: Any] {
    let store = try obtainStore()
    let reminder = try findReminder(store, args)
    guard let confirm = args["confirm_title"] as? String, confirm == (reminder.title ?? "") else {
        throw ToolError(message: "confirm_title does not exactly match the title of this reminder. Nothing was deleted.")
    }
    do { try store.remove(reminder, commit: true) } catch { throw saveError(error) }
    log("reminders_delete: 1 reminder deleted")
    return ["deleted": true, "note": "Permanently deleted; this cannot be undone via this server."]
}

func toolCreateList(_ args: [String: Any]) throws -> [String: Any] {
    guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        throw ToolError(message: "Parameter 'name' is missing.")
    }
    let store = try obtainStore()
    let existing = store.calendars(for: .reminder)
    guard !existing.contains(where: { $0.title.compare(name, options: [.caseInsensitive]) == .orderedSame }) else {
        throw ToolError(message: "A list with this name already exists.")
    }
    guard let source = store.defaultCalendarForNewReminders()?.source else {
        throw ToolError(message: "No account found to create the list in.")
    }
    let list = EKCalendar(for: .reminder, eventStore: store)
    list.title = name
    list.source = source
    do { try store.saveCalendar(list, commit: true) } catch { throw saveError(error) }
    log("reminders_create_list: 1 list created")
    return ["created": true, "list": ["name": name, "account": orNull(source.title)]]
}

let writeFieldProperties: [String: Any] = [
    "title": ["type": "string", "description": "Title of the reminder."],
    "list": ["type": "string", "description": "Name of the list. When creating, defaults to the default list; when updating, this moves the reminder."],
    "due": ["type": ["string", "null"], "description": "Due date in local time: 'YYYY-MM-DD' (all day) or 'YYYY-MM-DD HH:MM' (with a time, automatically gets an alarm). Also 'today' / 'tomorrow', optionally with a time. null clears the due date."],
    "notes": ["type": ["string", "null"], "description": "Note. null or empty text clears the note."],
    "priority": ["type": "string", "enum": ["none", "low", "medium", "high"], "description": "Priority."],
    "recurrence": [
        "type": ["object", "null"],
        "description": "Recurrence; requires a due date. null removes the recurrence.",
        "properties": [
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"]],
            "interval": ["type": "integer", "minimum": 1, "description": "Every N periods (default 1)."],
            "days_of_week": ["type": "array", "items": ["type": "string"], "description": "E.g. [\"mo\", \"th\"]."],
            "end_date": ["type": "string", "description": "Last day (YYYY-MM-DD)."],
            "count": ["type": "integer", "minimum": 1, "description": "Number of occurrences, as an alternative to end_date."],
        ],
        "required": ["frequency"],
    ],
]

let writeToolDefinitions: [[String: Any]] = {
    var tools: [[String: Any]] = []
    let writeAnnotations: [String: Any] = ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
    if writeAccess.create {
        tools.append([
            "name": "reminders_create",
            "title": "Create reminder",
            "description": "Creates one new reminder in Apple Reminders (syncs via iCloud). Subtasks, tags and the flag cannot be set. Returns the created reminder.",
            "inputSchema": ["type": "object", "properties": writeFieldProperties, "required": ["title"], "additionalProperties": false],
            "annotations": writeAnnotations,
        ])
        tools.append([
            "name": "reminders_create_list",
            "title": "Create list",
            "description": "Creates a new, empty reminder list in the account of the default list. Lists cannot be renamed or deleted via this server.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string", "description": "Name of the new list."]], "required": ["name"], "additionalProperties": false],
            "annotations": writeAnnotations,
        ])
    }
    if writeAccess.update {
        var properties = writeFieldProperties
        properties["id"] = ["type": "string", "description": "The reminder's 'id' from a read tool."]
        properties["completed"] = ["type": "boolean", "description": "true completes the reminder; false sets it back to open."]
        tools.append([
            "name": "reminders_update",
            "title": "Update or complete reminder",
            "description": "Updates one existing reminder. Only the provided fields change; everything else is left as is. Use completed = true to complete it. A new 'due' also replaces the time alarm.",
            "inputSchema": ["type": "object", "properties": properties, "required": ["id"], "additionalProperties": false],
            "annotations": writeAnnotations,
        ])
    }
    if writeAccess.delete {
        tools.append([
            "name": "reminders_delete",
            "title": "Delete reminder",
            "description": "Permanently deletes one reminder. As a check, requires the exact title in confirm_title; on a mismatch nothing happens. Prefer completing it with reminders_update if the task is simply done.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "The reminder's 'id' from a read tool."],
                    "confirm_title": ["type": "string", "description": "The exact current title of the reminder, as confirmation."],
                ],
                "required": ["id", "confirm_title"], "additionalProperties": false,
            ],
            "annotations": ["readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false],
        ])
    }
    return tools
}()

let toolDefinitions: [[String: Any]] = readToolDefinitions + writeToolDefinitions

func callTool(name: String, arguments: [String: Any]) -> (payload: [String: Any], isError: Bool) {
    let started = Date()
    defer { log("tool \(name) done in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
    do {
        switch name {
        case "reminders_daily_overview": return (try toolDailyOverview(arguments), false)
        case "reminders_list_open": return (try toolListOpen(arguments), false)
        case "reminders_lists": return (try toolLists(arguments), false)
        case "reminders_access_status": return (toolAccessStatus(arguments), false)
        case "reminders_create" where writeAccess.create: return (try toolCreate(arguments), false)
        case "reminders_create_list" where writeAccess.create: return (try toolCreateList(arguments), false)
        case "reminders_update" where writeAccess.update: return (try toolUpdate(arguments), false)
        case "reminders_delete" where writeAccess.delete: return (try toolDelete(arguments), false)
        case "reminders_create", "reminders_create_list", "reminders_update", "reminders_delete":
            return (["error": "write_disabled", "message": "This write tool is disabled. The user can enable it with --write=..., the environment variable REMINDERS_MCP_WRITE, or the file ~/.config/reminders-mcp/write (values: create, update, delete or all), then restart the MCP client."], true)
        default: return (["error": "unknown_tool", "message": "Unknown tool: \(name)"], true)
        }
    } catch let denied as AccessDenied {
        log("tool \(name): no access to Reminders")
        return (["error": "reminders_access_missing", "access": denied.report], true)
    } catch let error as ToolError {
        return (["error": "invalid_request", "message": error.message], true)
    } catch {
        return (["error": "internal_error", "message": "Unexpected error while reading Reminders."], true)
    }
}

// MARK: - MCP over stdio

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func respond(id: Any, result: [String: Any]) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func respondError(id: Any, code: Int, message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func handle(_ message: [String: Any]) {
    guard let method = message["method"] as? String else { return } // ignore responses from the client
    let params = message["params"] as? [String: Any] ?? [:]
    guard let id = message["id"], !(id is NSNull) else { return } // notifications do not expect a response

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        let version = supportedProtocolVersions.contains(requested) ? requested : supportedProtocolVersions[0]
        respond(id: id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "title": "Apple Reminders", "version": serverVersion],
            "instructions": "Access to Apple Reminders on this Mac via EventKit. Use reminders_daily_overview for daily planning: 'due_on_date' are reminders for that day, 'overdue' are overdue ones; keep those groups apart. 'Today' is the calendar day in the Mac's local time zone. " + writeAccess.summary + " On error 'reminders_access_missing': pass the steps from 'access.steps' on to the user.",
        ])
    case "ping":
        respond(id: id, result: [:])
    case "tools/list":
        respond(id: id, result: ["tools": toolDefinitions])
    case "tools/call":
        guard let name = params["name"] as? String else {
            respondError(id: id, code: -32602, message: "Parameter 'name' is missing.")
            return
        }
        let outcome = callTool(name: name, arguments: params["arguments"] as? [String: Any] ?? [:])
        respond(id: id, result: [
            "content": [["type": "text", "text": jsonString(outcome.payload)]],
            "structuredContent": outcome.payload,
            "isError": outcome.isError,
        ])
    case "resources/list":
        respond(id: id, result: ["resources": [Any]()])
    case "prompts/list":
        respond(id: id, result: ["prompts": [Any]()])
    default:
        respondError(id: id, code: -32601, message: "Method not supported: \(method)")
    }
}

func runServer() {
    log("started (v\(serverVersion), \(writeAccess.any ? "write tools enabled" : "read-only"), stdio)")
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Invalid JSON."]])
            continue
        }
        if let message = json as? [String: Any] {
            handle(message)
        } else if let batch = json as? [[String: Any]] {
            batch.forEach(handle)
        }
    }
    log("stdin closed; stopped")
}

// MARK: - Own responsibility for the macOS permission

@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// macOS normally ties a privacy permission to the app that launches a program (Codex, Terminal, ...).
/// If that app launches from the background or lacks the right usage description, no prompt appears.
/// That is why the server re-executes itself once as its "own responsible process": the permission then
/// belongs to reminders-mcp itself and applies regardless of which app starts the server. Disable with REMINDERS_MCP_NO_DISCLAIM=1.
func reexecAsOwnResponsibleProcess() {
    let env = ProcessInfo.processInfo.environment
    guard env["REMINDERS_MCP_DISCLAIMED"] == nil, env["REMINDERS_MCP_NO_DISCLAIM"] == nil,
          let path = Bundle.main.executablePath else { return }
    var attr: posix_spawnattr_t?
    guard posix_spawnattr_init(&attr) == 0 else { return }
    defer { posix_spawnattr_destroy(&attr) }
    guard posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC)) == 0,
          responsibility_spawnattrs_setdisclaim(&attr, 1) == 0 else { return }
    var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
    argv.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
    envp.append(strdup("REMINDERS_MCP_DISCLAIMED=1"))
    envp.append(nil)
    // On success posix_spawn (SETEXEC) replaces this process; only on failure does the code below continue.
    _ = posix_spawn(nil, path, nil, &attr, argv, envp)
    log("re-exec as own responsible process failed; continuing under the launching app")
}

// MARK: - Start

reexecAsOwnResponsibleProcess()

let cliArguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("--write=") }
switch cliArguments.first {
case nil:
    runServer()
case "--check":
    // Requests the macOS permission prompt if needed and then shows the status (without content).
    do {
        _ = try obtainStore()
        print(jsonString(toolAccessStatus([:])))
    } catch let denied as AccessDenied {
        print(jsonString(denied.report))
        exit(1)
    } catch {
        exit(1)
    }
case "--overview":
    // One-off daily overview to stdout, e.g. `reminders-mcp --overview 2026-11-23`.
    var args: [String: Any] = [:]
    if cliArguments.count > 1 { args["date"] = cliArguments[1] }
    let outcome = callTool(name: "reminders_daily_overview", arguments: args)
    print(jsonString(outcome.payload))
    exit(outcome.isError ? 1 : 0)
case "--version":
    print("\(serverName) \(serverVersion)")
default:
    print("Usage: reminders-mcp            MCP server over stdio (default)\n       reminders-mcp --check    check / request access\n       reminders-mcp --overview [YYYY-MM-DD]\n       reminders-mcp --version")
}
