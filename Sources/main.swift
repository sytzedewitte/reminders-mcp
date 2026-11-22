// reminders-mcp — lokale MCP-server voor Apple Herinneringen (macOS, EventKit).
//
// Ontwerpregels:
//  * Standaard alleen-lezen. Schrijftools bestaan alleen als REMINDERS_MCP_WRITE ze aanzet
//    (create, update, delete of all); zonder die instelling worden ze niet eens aangeboden.
//  * Geen opslag: herinneringen bestaan alleen in het geheugen tijdens het beantwoorden van één aanroep.
//  * Geen inhoud in logs: stderr bevat alleen toolnamen, aantallen en doorlooptijden.
//  * Transport: MCP over stdio (JSON-RPC 2.0, één JSON-bericht per regel).

import EventKit
import Foundation
import SQLite3

let serverName = "apple-reminders"
let serverVersion = "1.1.0"
let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

// MARK: - Hulpfuncties

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

// MARK: - Tijd en "vandaag"

/// Momentopname van de lokale tijdzone van de Mac. Wordt bij elke aanroep opnieuw bepaald,
/// zodat een tijdzonewissel (reizen, zomertijd) ook in een lang draaiend proces klopt.
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

    /// Accepteert "YYYY-MM-DD", "vandaag"/"today", "morgen"/"tomorrow", "gisteren"/"yesterday".
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
            throw ToolError(message: "Ongeldige datum '\(raw)'. Gebruik het formaat YYYY-MM-DD (bijv. 2026-11-23), of 'vandaag' / 'morgen'.")
        }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        guard let date = calendar.date(from: comps), dayString(date) == text else {
            throw ToolError(message: "Datum '\(raw)' bestaat niet in de kalender.")
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
            "source": "Systeemtijdzone van deze Mac, bij elke aanroep opnieuw uitgelezen",
        ]
    }
}

// MARK: - Toegang

let accessHelpSteps: [String] = [
    "Open Systeeminstellingen > Privacy en beveiliging > Herinneringen.",
    "Zoek de app die deze server start (bijv. Codex, Terminal, iTerm of 'reminders-mcp') en zet de schakelaar aan / kies 'Volledige toegang'.",
    "Staat de app er niet tussen? Voer dan in Terminal `tccutil reset Reminders` uit en start de server opnieuw; macOS toont dan opnieuw het toestemmingsvenster.",
    "Herstart daarna de app die de MCP-server start, zodat de nieuwe toestemming actief wordt.",
]

let accessScopeNote =
    "EventKit kent voor Herinneringen geen aparte leestoestemming: 'volledige toegang' is de kleinste toestemming waarmee lezen mogelijk is. Deze server leest standaard alleen; aanmaken, wijzigen en verwijderen staan uit tenzij de gebruiker ze zelf aanzet met REMINDERS_MCP_WRITE."

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
        report["explanation"] = "Toegang tot Herinneringen is verleend. De server kan herinneringen lezen."
    case .notDetermined:
        report["can_read"] = false
        report["explanation"] = "Er is nog geen keuze gemaakt. Bij de eerste leesactie toont macOS een toestemmingsvenster; kies daar 'Sta toe' / 'Volledige toegang'. Verschijnt er geen venster, volg dan de stappen."
        report["steps"] = accessHelpSteps
    case .denied:
        report["can_read"] = false
        report["explanation"] = "Toegang tot Herinneringen is geweigerd voor de app die deze server start. macOS vraagt dit niet opnieuw; zet de toegang handmatig aan."
        report["steps"] = accessHelpSteps
    case .restricted:
        report["can_read"] = false
        report["explanation"] = "Toegang tot Herinneringen is op deze Mac geblokkeerd door een beperking (bijv. een MDM-profiel van de werkgever of Schermtijd). Dit kan alleen een beheerder opheffen."
        report["steps"] = ["Controleer Systeeminstellingen > Schermtijd > Materiaal en privacy.", "Vraag de beheerder van deze Mac of een configuratieprofiel de toegang tot Herinneringen blokkeert."]
    case .writeOnly:
        report["can_read"] = false
        report["explanation"] = "Er is alleen schrijftoegang verleend; lezen is daarmee niet mogelijk. Kies 'Volledige toegang' in de systeeminstellingen."
        report["steps"] = accessHelpSteps
    @unknown default:
        report["can_read"] = true
        report["explanation"] = "Toegang verleend (oude toestemmingsvorm)."
    }
    return report
}

struct AccessDenied: Error {
    let report: [String: Any]
}

/// Geeft een verse EKEventStore terug (per aanroep, zodat iCloud-wijzigingen altijd zichtbaar zijn)
/// en vraagt zo nodig eenmalig toestemming aan.
func obtainStore(promptIfNeeded: Bool = true) throws -> EKEventStore {
    var status = EKEventStore.authorizationStatus(for: .reminder)
    if status == .notDetermined && promptIfNeeded {
        log("toestemming nog niet bepaald; macOS-toestemmingsvenster aangevraagd")
        let requester = EKEventStore()
        let done = DispatchSemaphore(value: 0)
        requester.requestFullAccessToReminders { granted, error in
            let code = (error as NSError?).map { "\($0.domain) \($0.code)" } ?? "geen fout"
            log("toestemmingsverzoek afgerond: granted=\(granted) (\(code))")
            done.signal()
        }
        if done.wait(timeout: .now() + 120) == .timedOut {
            var report = accessReport(.notDetermined)
            report["explanation"] = "Het macOS-toestemmingsvenster is aangevraagd maar binnen 2 minuten niet beantwoord (of macOS kon het niet tonen). Beantwoord het venster en probeer opnieuw."
            throw AccessDenied(report: report)
        }
        status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .notDetermined {
            var report = accessReport(.notDetermined)
            report["explanation"] = "macOS heeft het toestemmingsverzoek afgehandeld zonder een venster te tonen en zonder toegang te verlenen. Dat gebeurt wanneer het proces geen toestemmingsvenster mag tonen (bijv. gestart vanuit een achtergrondproces zonder schermsessie). Voer eenmalig in Terminal `reminders-mcp --check` uit en kies 'Sta toe'; daarna werkt de server ook vanuit de agent."
            throw AccessDenied(report: report)
        }
    }
    let report = accessReport(status)
    guard report["can_read"] as? Bool == true else { throw AccessDenied(report: report) }
    return EKEventStore()
}

// MARK: - Ophalen (alleen lezen)

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
        throw ToolError(message: "Onbekende lijst(en): \(unknown.joined(separator: ", ")). Beschikbare lijsten: \(available)")
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

// MARK: - Vervaldatum

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
        // Een tijd mét tijdzone is een vast moment; zonder tijdzone is het een "zwevende" lokale tijd.
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

// MARK: - Herhaling, prioriteit, meldingen

let weekdayNames = ["", "zo", "ma", "di", "wo", "do", "vr", "za"]
let monthNames = ["", "jan", "feb", "mrt", "apr", "mei", "jun", "jul", "aug", "sep", "okt", "nov", "dec"]

func recurrenceJSON(_ reminder: EKReminder, local: LocalTime) -> [String: Any] {
    guard reminder.hasRecurrenceRules, let rules = reminder.recurrenceRules, !rules.isEmpty else {
        return ["is_recurring": false]
    }
    var out: [[String: Any]] = []
    var summaries: [String] = []
    for rule in rules {
        let (code, singular, plural): (String, String, String)
        switch rule.frequency {
        case .daily: (code, singular, plural) = ("daily", "dag", "dagen")
        case .weekly: (code, singular, plural) = ("weekly", "week", "weken")
        case .monthly: (code, singular, plural) = ("monthly", "maand", "maanden")
        case .yearly: (code, singular, plural) = ("yearly", "jaar", "jaar")
        @unknown default: (code, singular, plural) = ("unknown", "periode", "perioden")
        }
        var item: [String: Any] = ["frequency": code, "interval": rule.interval]
        var summary = rule.interval == 1 ? "elke \(singular)" : "elke \(rule.interval) \(plural)"
        if code == "yearly" && rule.interval == 1 { summary = "elk jaar" }

        if let days = rule.daysOfTheWeek, !days.isEmpty {
            let labels = days.map { d -> String in
                let name = weekdayNames[min(max(d.dayOfTheWeek.rawValue, 0), 7)]
                return d.weekNumber == 0 ? name : "\(d.weekNumber)e \(name)"
            }
            item["days_of_week"] = labels
            summary += " op " + labels.joined(separator: ", ")
        }
        if let days = rule.daysOfTheMonth, !days.isEmpty {
            item["days_of_month"] = days.map { $0.intValue }
            summary += " op dag " + days.map { $0.stringValue }.joined(separator: ", ")
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
                summary += " tot en met \(local.dayString(endDate))"
            } else if end.occurrenceCount > 0 {
                item["ends_after_occurrences"] = end.occurrenceCount
                summary += ", \(end.occurrenceCount) keer"
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
    case 0: label = "geen"
    case 1...4: label = "hoog"
    case 5: label = "normaal"
    default: label = "laag"
    }
    return ["value": value, "label": label, "scale": "0 = geen, 1-4 = hoog, 5 = normaal, 6-9 = laag"]
}

func alarmsJSON(_ reminder: EKReminder, local: LocalTime) -> [[String: Any]] {
    guard reminder.hasAlarms, let alarms = reminder.alarms else { return [] }
    return alarms.map { alarm in
        if let location = alarm.structuredLocation {
            let proximity: String
            switch alarm.proximity {
            case .enter: proximity = "bij aankomst"
            case .leave: proximity = "bij vertrek"
            default: proximity = "onbekend"
            }
            return ["type": "location", "location": orNull(location.title), "trigger": proximity]
        }
        if let date = alarm.absoluteDate {
            return ["type": "time", "at": local.iso(date)]
        }
        return ["type": "relative", "offset_seconds": Int(alarm.relativeOffset)]
    }
}

// MARK: - Subtaken (optioneel, via de lokale Herinneringen-database)

let subtasksEventKitNote =
    "EventKit geeft geen ouder/kind-relatie tussen herinneringen terug. Subtaken staan wél in de resultaten, maar als gewone, losse herinneringen zonder verwijzing naar hun hoofdtaak."

struct SubtaskLookup {
    /// kind-id -> ouder-id (id's zoals EventKit ze kent)
    var parentOf: [String: String] = [:]
    var status: String = "unavailable"
    var note: String = subtasksEventKitNote
}

/// Leest uitsluitend id-paren (kind, ouder) uit de lokale Herinneringen-database. Er wordt geen
/// titel, notitie of andere inhoud uit de database gelezen. Alleen actief met
/// REMINDERS_MCP_SUBTASKS=sqlite; vereist Volledige schijftoegang voor de app die de server start.
func loadSubtaskLookup() -> SubtaskLookup {
    var lookup = SubtaskLookup()
    guard ProcessInfo.processInfo.environment["REMINDERS_MCP_SUBTASKS"]?.lowercased() == "sqlite" else {
        lookup.note = subtasksEventKitNote + " Optioneel kan de server de relatie uit de lokale Herinneringen-database lezen (zet REMINDERS_MCP_SUBTASKS=sqlite; vereist Volledige schijftoegang). Dat staat nu uit."
        return lookup
    }
    let storesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.reminders/Container_v1/Stores")
    guard let files = try? FileManager.default.contentsOfDirectory(at: storesURL, includingPropertiesForKeys: nil) else {
        lookup.status = "sqlite_no_access"
        lookup.note = subtasksEventKitNote + " De database-aanvulling staat aan, maar de map met de Herinneringen-database is niet leesbaar. Geef de app die deze server start Volledige schijftoegang (Systeeminstellingen > Privacy en beveiliging > Volledige schijftoegang) of zet REMINDERS_MCP_SUBTASKS uit."
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
        lookup.note = subtasksEventKitNote + " De database-aanvulling staat aan, maar het (ongedocumenteerde) databaseschema van deze macOS-versie wordt niet herkend. Subtaakrelaties zijn daarom niet beschikbaar."
    } else {
        lookup.status = "sqlite_ok"
        lookup.note = "Subtaakrelaties zijn aangevuld uit de lokale Herinneringen-database (alleen id's gelezen, ongedocumenteerd schema, kan na een macOS-update wegvallen). Alleen open subtaken worden getoond; voltooide subtaken niet."
    }
    return lookup
}

// MARK: - Herinnering -> JSON

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
            out["due_note"] = "Geen vervaldatum ingesteld."
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
                    out["parent_note"] = "Hoofdtaak is voltooid of valt buiten de opgevraagde lijsten."
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
        "available_via_eventkit": ["title", "list", "account", "due date/time", "start date", "notes", "priority", "recurrence", "alarms (tijd en locatie)", "created/modified"],
        "subtasks": ["status": lookup.status, "note": lookup.note],
        "not_available_via_eventkit": [
            "tags": "Tags (#) worden niet door EventKit teruggegeven.",
            "flagged": "De markering (vlag) is niet beschikbaar.",
            "sections_and_columns": "Secties/kolommen binnen een lijst zijn niet beschikbaar.",
            "smart_lists": "Slimme lijsten (Vandaag, Gepland, eigen slimme lijsten) bestaan niet in EventKit; deze server berekent het dagoverzicht zelf.",
            "attachments": "Afbeeldingen en bijlagen zijn niet beschikbaar.",
            "url_field": "Het URL-veld uit de Herinneringen-app komt doorgaans niet door via EventKit; 'url' ontbreekt dan.",
            "assignee": "Toewijzing in gedeelde lijsten is niet beschikbaar.",
            "early_reminder_and_messaging": "'Vroege herinnering' en 'Bij berichten sturen naar' zijn niet (betrouwbaar) beschikbaar.",
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
    let target = try local.parseDay(args["date"] as? String ?? "vandaag")
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
            "day": "De opgevraagde dag is de kalenderdag \(dateText) van 00:00 tot 24:00 in de lokale tijdzone van deze Mac (\(local.timeZone.identifier)). Zonder 'date' is dat de dag van 'generated_at'.",
            "due_on_date": "Open herinneringen waarvan de vervaldatum op die dag valt. Herinneringen met een tijdzone worden eerst naar lokale tijd omgerekend; herinneringen voor de hele dag tellen op hun kalenderdatum. Een tijdstip dat vandaag al voorbij is blijft hier staan, met is_overdue = true.",
            "overdue": "Open herinneringen met een vervaldatum vóór 00:00 van \(local.dayString(overdueBefore)) (de vroegste van de opgevraagde dag en vandaag). Apart van 'due_on_date'.",
            "undated": "Open herinneringen zonder vervaldatum; alleen meegegeven met include_undated = true.",
            "scope": "Alleen niet-voltooide herinneringen uit alle accounts die op deze Mac met Herinneringen synchroniseren (iCloud en eventuele andere).",
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
    else { result["overdue_note"] = "Achterstallige herinneringen zijn weggelaten (include_overdue = false); zie counts.overdue." }
    if includeUndated { result["undated"] = sortItems(undated).map(renderer.render) }
    else if !undated.isEmpty { result["undated_note"] = "\(undated.count) open herinnering(en) zonder vervaldatum zijn niet opgenomen. Gebruik include_undated = true of reminders_list_open." }
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
            "note": "due_from en due_to zijn kalenderdagen (inclusief) in de lokale tijdzone van deze Mac.",
        ],
        "counts": [
            "returned": selected.count,
            "matched": matched,
            "truncated": selected.count < matched,
            "open_total": items.count,
            "without_due_date": selected.filter { $0.due == nil }.count,
        ],
        "sort": "Op vervaldatum (oudste eerst), daarna prioriteit; herinneringen zonder vervaldatum staan achteraan.",
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
        "note": "Slimme lijsten en lijstgroepen (mappen) zijn niet zichtbaar via EventKit.",
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
    report["subtasks"] = ["note": subtasksEventKitNote, "sqlite_enrichment_enabled": ProcessInfo.processInfo.environment["REMINDERS_MCP_SUBTASKS"]?.lowercased() == "sqlite"]
    report["responsible_app_note"] = "macOS koppelt de toestemming aan de app die deze server start (bijv. Codex of Terminal). Elke startende app heeft dus zijn eigen toestemming nodig."
    return report
}

let listsProperty: [String: Any] = [
    "type": "array", "items": ["type": "string"],
    "description": "Optioneel: beperk tot deze lijstnamen (hoofdletterongevoelig). Standaard alle lijsten.",
]
let notesProperty: [String: Any] = [
    "type": "boolean",
    "description": "Notities meesturen (standaard true). Bij false blijft alleen has_notes over.",
]
let readOnlyAnnotations: [String: Any] = ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]

let readToolDefinitions: [[String: Any]] = [
    [
        "name": "reminders_daily_overview",
        "title": "Dagoverzicht Herinneringen",
        "description": "Alleen-lezen dagoverzicht van open Apple Herinneringen op deze Mac (inclusief iCloud-lijsten). Geeft twee gescheiden groepen: 'due_on_date' (echt gepland op de gevraagde dag) en 'overdue' (open en achterstallig van eerdere dagen). Zonder 'date' is de dag vandaag: de kalenderdag van 00:00 tot 24:00 in de lokale tijdzone van de Mac. Per herinnering: titel, lijst, account, vervaldatum en -tijd, notities, prioriteit, herhaling, meldingen en (indien beschikbaar) subtaken. 'field_availability' vermeldt welke velden EventKit niet levert. Gebruik deze tool voor de dagelijkse planning; wijzigt nooit iets.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "date": ["type": "string", "description": "Dag in lokale tijd, formaat YYYY-MM-DD, of 'vandaag' / 'morgen' / 'gisteren'. Standaard vandaag."],
                "include_overdue": ["type": "boolean", "description": "Achterstallige open herinneringen meegeven in de aparte groep 'overdue' (standaard true)."],
                "include_undated": ["type": "boolean", "description": "Ook open herinneringen zonder vervaldatum meegeven in de groep 'undated' (standaard false)."],
                "include_notes": notesProperty,
                "lists": listsProperty,
            ],
            "additionalProperties": false,
        ],
        "annotations": readOnlyAnnotations,
    ],
    [
        "name": "reminders_list_open",
        "title": "Alle open herinneringen",
        "description": "Alleen-lezen: geeft de volledige lijst van alle open (niet-voltooide) Apple Herinneringen, inclusief achterstallige en herinneringen zonder vervaldatum (die krijgen has_due_date = false). Optioneel te filteren op lijst en op een periode van vervaldatums. Elke herinnering heeft is_overdue en dezelfde velden als het dagoverzicht. Gebruik dit wanneer het dagoverzicht niet volstaat, bijvoorbeeld voor weekplanning of een volledige inventaris.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "due_from": ["type": "string", "description": "Alleen herinneringen met vervaldatum op of na deze dag (YYYY-MM-DD, lokale tijd)."],
                "due_to": ["type": "string", "description": "Alleen herinneringen met vervaldatum tot en met deze dag (YYYY-MM-DD, lokale tijd)."],
                "include_undated": ["type": "boolean", "description": "Herinneringen zonder vervaldatum meenemen (standaard true)."],
                "include_notes": notesProperty,
                "lists": listsProperty,
                "limit": ["type": "integer", "minimum": 1, "description": "Maximaal aantal resultaten. Standaard geen limiet; counts.truncated meldt of er is afgekapt."],
            ],
            "additionalProperties": false,
        ],
        "annotations": readOnlyAnnotations,
    ],
    [
        "name": "reminders_lists",
        "title": "Herinneringenlijsten",
        "description": "Alleen-lezen: toont alle lijsten in Apple Herinneringen met account (bijv. iCloud) en het aantal open herinneringen per lijst. Handig om lijstnamen te vinden voor de parameter 'lists'.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": readOnlyAnnotations,
    ],
    [
        "name": "reminders_access_status",
        "title": "Toegangsstatus Herinneringen",
        "description": "Controleert of deze server toestemming van macOS heeft om Herinneringen te lezen, zonder zelf een toestemmingsvenster te openen. Geeft bij ontbrekende of geweigerde toegang de stappen om dit in Systeeminstellingen toe te staan, plus de tijdzone en datum die als 'vandaag' gelden.",
        "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        "annotations": readOnlyAnnotations,
    ],
]

// MARK: - Schrijven (standaard uit)

/// Schrijftools worden alleen aangeboden als de gebruiker ze zelf aanzet via REMINDERS_MCP_WRITE.
struct WriteAccess {
    let create: Bool
    let update: Bool
    let delete: Bool
    var any: Bool { create || update || delete }

    init() {
        let raw = ProcessInfo.processInfo.environment["REMINDERS_MCP_WRITE"] ?? ""
        let parts = Set(raw.lowercased().split(whereSeparator: { ", ;".contains($0) }).map(String.init))
        let all = parts.contains("all")
        create = all || parts.contains("create")
        update = all || parts.contains("update")
        delete = all || parts.contains("delete")
    }

    var summary: String {
        if !any { return "De server is alleen-lezen: aanmaken, wijzigen, voltooien en verwijderen staan uit." }
        var on: [String] = []
        if create { on.append("aanmaken (reminders_create, reminders_create_list)") }
        if update { on.append("wijzigen en voltooien (reminders_update)") }
        if delete { on.append("verwijderen (reminders_delete)") }
        return "Schrijven is door de gebruiker aangezet voor: " + on.joined(separator: ", ") + ". Al het andere is alleen-lezen."
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
            throw ToolError(message: "Ongeldige tijd in '\(raw)'. Gebruik lokale tijd als YYYY-MM-DD HH:MM (bijv. 2026-11-23 09:30), zonder tijdzone.")
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
    default: throw ToolError(message: "Ongeldige prioriteit. Gebruik none, low, medium of high.")
    }
}

func parseRecurrence(_ dict: [String: Any], local: LocalTime) throws -> EKRecurrenceRule {
    let frequency: EKRecurrenceFrequency
    switch (dict["frequency"] as? String)?.lowercased() {
    case "daily", "dagelijks": frequency = .daily
    case "weekly", "wekelijks": frequency = .weekly
    case "monthly", "maandelijks": frequency = .monthly
    case "yearly", "jaarlijks": frequency = .yearly
    default: throw ToolError(message: "recurrence.frequency moet daily, weekly, monthly of yearly zijn.")
    }
    let interval = (dict["interval"] as? NSNumber)?.intValue ?? 1
    guard interval >= 1 else { throw ToolError(message: "recurrence.interval moet 1 of hoger zijn.") }

    var days: [EKRecurrenceDayOfWeek]?
    if let names = stringArray(dict["days_of_week"]) {
        let map = ["su": 1, "zo": 1, "mo": 2, "ma": 2, "tu": 3, "di": 3, "we": 4, "wo": 4, "th": 5, "do": 5, "fr": 6, "vr": 6, "sa": 7, "za": 7]
        days = try names.map { name in
            guard let raw = map[String(name.lowercased().prefix(2))], let weekday = EKWeekday(rawValue: raw) else {
                throw ToolError(message: "Onbekende weekdag '\(name)'. Gebruik mo, tu, we, th, fr, sa, su (of ma, di, wo, do, vr, za, zo).")
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
        throw ToolError(message: "Er zijn \(matches.count) lijsten met de naam '\(name)'; kies een unieke lijstnaam.")
    }
    guard matches[0].allowsContentModifications else {
        throw ToolError(message: "De lijst '\(name)' is alleen-lezen en kan niet worden gewijzigd.")
    }
    return matches[0]
}

/// Past alleen de velden toe die in `args` voorkomen. JSON-null wist een veld (due, notes, recurrence).
func applyFields(_ reminder: EKReminder, _ args: [String: Any], store: EKEventStore, local: LocalTime) throws {
    if let title = args["title"] as? String {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError(message: "title mag niet leeg zijn.") }
        reminder.title = title
    }
    if let notes = args["notes"] {
        let text = notes as? String
        reminder.notes = (text ?? "").isEmpty ? nil : text
    }
    if let priority = args["priority"] { reminder.priority = try parsePriority(priority) }
    if let list = args["list"] as? String { reminder.calendar = try writableList(store, named: list) }
    if let due = args["due"] {
        // Tijdmeldingen horen bij de vervaldatum en worden mee vervangen; locatiemeldingen blijven staan.
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
        throw ToolError(message: "Een herhalende herinnering heeft een vervaldatum nodig; geef 'due' op of verwijder de herhaling.")
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
    guard let id = args["id"] as? String, !id.isEmpty else { throw ToolError(message: "Parameter 'id' ontbreekt.") }
    guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
        throw ToolError(message: "Geen herinnering gevonden met dit id. Id's kunnen na een iCloud-synchronisatie wijzigen; haal de herinnering opnieuw op.")
    }
    return reminder
}

func saveError(_ error: Error) -> ToolError {
    let ns = error as NSError
    return ToolError(message: "macOS kon de wijziging niet opslaan (\(ns.domain) \(ns.code)).")
}

func toolCreate(_ args: [String: Any]) throws -> [String: Any] {
    let local = LocalTime()
    guard args["title"] is String else { throw ToolError(message: "Parameter 'title' ontbreekt.") }
    let store = try obtainStore()
    let reminder = EKReminder(eventStore: store)
    if args["list"] == nil {
        guard let fallback = store.defaultCalendarForNewReminders() else {
            throw ToolError(message: "Er is geen standaardlijst ingesteld; geef 'list' op.")
        }
        reminder.calendar = fallback
    }
    try applyFields(reminder, args, store: store, local: local)
    do { try store.save(reminder, commit: true) } catch { throw saveError(error) }
    log("reminders_create: 1 herinnering aangemaakt")
    return ["created": true, "reminder": renderWritten(reminder, local: local),
            "id_note": "Het id kan na de eerste iCloud-synchronisatie wijzigen."]
}

func toolUpdate(_ args: [String: Any]) throws -> [String: Any] {
    let local = LocalTime()
    let store = try obtainStore()
    let reminder = try findReminder(store, args)
    let fields = ["title", "notes", "priority", "list", "due", "recurrence", "completed"].filter { args[$0] != nil }
    guard !fields.isEmpty else { throw ToolError(message: "Geen velden om te wijzigen opgegeven.") }
    try applyFields(reminder, args, store: store, local: local)
    do { try store.save(reminder, commit: true) } catch { throw saveError(error) }
    log("reminders_update: 1 herinnering gewijzigd (\(fields.joined(separator: ",")))")
    return ["updated": true, "changed_fields": fields, "reminder": renderWritten(reminder, local: local)]
}

func toolDelete(_ args: [String: Any]) throws -> [String: Any] {
    let store = try obtainStore()
    let reminder = try findReminder(store, args)
    guard let confirm = args["confirm_title"] as? String, confirm == (reminder.title ?? "") else {
        throw ToolError(message: "confirm_title komt niet exact overeen met de titel van deze herinnering. Er is niets verwijderd.")
    }
    do { try store.remove(reminder, commit: true) } catch { throw saveError(error) }
    log("reminders_delete: 1 herinnering verwijderd")
    return ["deleted": true, "note": "Definitief verwijderd; dit kan niet ongedaan worden gemaakt via deze server."]
}

func toolCreateList(_ args: [String: Any]) throws -> [String: Any] {
    guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
        throw ToolError(message: "Parameter 'name' ontbreekt.")
    }
    let store = try obtainStore()
    let existing = store.calendars(for: .reminder)
    guard !existing.contains(where: { $0.title.compare(name, options: [.caseInsensitive]) == .orderedSame }) else {
        throw ToolError(message: "Er bestaat al een lijst met deze naam.")
    }
    guard let source = store.defaultCalendarForNewReminders()?.source else {
        throw ToolError(message: "Geen account gevonden om de lijst in aan te maken.")
    }
    let list = EKCalendar(for: .reminder, eventStore: store)
    list.title = name
    list.source = source
    do { try store.saveCalendar(list, commit: true) } catch { throw saveError(error) }
    log("reminders_create_list: 1 lijst aangemaakt")
    return ["created": true, "list": ["name": name, "account": orNull(source.title)]]
}

let writeFieldProperties: [String: Any] = [
    "title": ["type": "string", "description": "Titel van de herinnering."],
    "list": ["type": "string", "description": "Naam van de lijst. Bij aanmaken standaard de standaardlijst; bij wijzigen verplaatst dit de herinnering."],
    "due": ["type": ["string", "null"], "description": "Vervaldatum in lokale tijd: 'YYYY-MM-DD' (hele dag) of 'YYYY-MM-DD HH:MM' (met tijd, krijgt automatisch een melding). Ook 'vandaag' / 'morgen', eventueel met tijd. null wist de vervaldatum."],
    "notes": ["type": ["string", "null"], "description": "Notitie. null of lege tekst wist de notitie."],
    "priority": ["type": "string", "enum": ["none", "low", "medium", "high"], "description": "Prioriteit."],
    "recurrence": [
        "type": ["object", "null"],
        "description": "Herhaling; vereist een vervaldatum. null verwijdert de herhaling.",
        "properties": [
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"]],
            "interval": ["type": "integer", "minimum": 1, "description": "Elke N perioden (standaard 1)."],
            "days_of_week": ["type": "array", "items": ["type": "string"], "description": "Bijv. [\"mo\", \"th\"]."],
            "end_date": ["type": "string", "description": "Laatste dag (YYYY-MM-DD)."],
            "count": ["type": "integer", "minimum": 1, "description": "Aantal keren, als alternatief voor end_date."],
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
            "title": "Herinnering aanmaken",
            "description": "Maakt één nieuwe herinnering aan in Apple Herinneringen (synchroniseert via iCloud). Subtaken, tags en de vlag kunnen niet worden gezet. Geeft de aangemaakte herinnering terug.",
            "inputSchema": ["type": "object", "properties": writeFieldProperties, "required": ["title"], "additionalProperties": false],
            "annotations": writeAnnotations,
        ])
        tools.append([
            "name": "reminders_create_list",
            "title": "Lijst aanmaken",
            "description": "Maakt een nieuwe, lege herinneringenlijst aan in het account van de standaardlijst. Lijsten hernoemen of verwijderen kan niet via deze server.",
            "inputSchema": ["type": "object", "properties": ["name": ["type": "string", "description": "Naam van de nieuwe lijst."]], "required": ["name"], "additionalProperties": false],
            "annotations": writeAnnotations,
        ])
    }
    if writeAccess.update {
        var properties = writeFieldProperties
        properties["id"] = ["type": "string", "description": "Het 'id' van de herinnering uit een leestool."]
        properties["completed"] = ["type": "boolean", "description": "true vinkt de herinnering af; false zet hem terug op open."]
        tools.append([
            "name": "reminders_update",
            "title": "Herinnering wijzigen of afvinken",
            "description": "Wijzigt één bestaande herinnering. Alleen de opgegeven velden veranderen; de rest blijft staan. Gebruik completed = true om af te vinken. Een nieuwe 'due' vervangt ook de tijdmelding.",
            "inputSchema": ["type": "object", "properties": properties, "required": ["id"], "additionalProperties": false],
            "annotations": writeAnnotations,
        ])
    }
    if writeAccess.delete {
        tools.append([
            "name": "reminders_delete",
            "title": "Herinnering verwijderen",
            "description": "Verwijdert één herinnering definitief. Vereist ter controle de exacte titel in confirm_title; bij een afwijking gebeurt er niets. Vink liever af met reminders_update als de taak gewoon klaar is.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Het 'id' van de herinnering uit een leestool."],
                    "confirm_title": ["type": "string", "description": "De exacte huidige titel van de herinnering, als bevestiging."],
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
    defer { log("tool \(name) klaar in \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
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
            return (["error": "write_disabled", "message": "Deze schrijftool staat uit. De gebruiker kan hem aanzetten met de omgevingsvariabele REMINDERS_MCP_WRITE (create, update, delete of all) in de MCP-configuratie."], true)
        default: return (["error": "unknown_tool", "message": "Onbekende tool: \(name)"], true)
        }
    } catch let denied as AccessDenied {
        log("tool \(name): geen toegang tot Herinneringen")
        return (["error": "reminders_access_missing", "access": denied.report], true)
    } catch let error as ToolError {
        return (["error": "invalid_request", "message": error.message], true)
    } catch {
        return (["error": "internal_error", "message": "Onverwachte fout bij het lezen van Herinneringen."], true)
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
    guard let method = message["method"] as? String else { return } // antwoorden van de client negeren
    let params = message["params"] as? [String: Any] ?? [:]
    guard let id = message["id"], !(id is NSNull) else { return } // notificaties vragen geen antwoord

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        let version = supportedProtocolVersions.contains(requested) ? requested : supportedProtocolVersions[0]
        respond(id: id, result: [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "title": "Apple Herinneringen", "version": serverVersion],
            "instructions": "Toegang tot Apple Herinneringen op deze Mac via EventKit. Gebruik reminders_daily_overview voor de dagplanning: 'due_on_date' zijn herinneringen voor die dag, 'overdue' zijn achterstallige; houd die groepen uit elkaar. 'Vandaag' is de kalenderdag in de lokale tijdzone van de Mac. " + writeAccess.summary + " Bij error 'reminders_access_missing': geef de stappen uit 'access.steps' door aan de gebruiker.",
        ])
    case "ping":
        respond(id: id, result: [:])
    case "tools/list":
        respond(id: id, result: ["tools": toolDefinitions])
    case "tools/call":
        guard let name = params["name"] as? String else {
            respondError(id: id, code: -32602, message: "Parameter 'name' ontbreekt.")
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
        respondError(id: id, code: -32601, message: "Methode niet ondersteund: \(method)")
    }
}

func runServer() {
    log("gestart (v\(serverVersion), alleen-lezen, stdio)")
    while let line = readLine(strippingNewline: true) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }
        guard let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Ongeldige JSON."]])
            continue
        }
        if let message = json as? [String: Any] {
            handle(message)
        } else if let batch = json as? [[String: Any]] {
            batch.forEach(handle)
        }
    }
    log("stdin gesloten; gestopt")
}

// MARK: - Eigen verantwoordelijkheid voor de macOS-toestemming

@_silgen_name("responsibility_spawnattrs_setdisclaim")
func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32

/// macOS koppelt een privacytoestemming normaal aan de app die een programma start (Codex, Terminal, ...).
/// Start die app vanuit de achtergrond of mist ze de juiste toestemmingstekst, dan verschijnt er geen venster.
/// Daarom herstart de server zichzelf één keer als "eigen verantwoordelijke": de toestemming hoort dan bij
/// reminders-mcp zelf en geldt ongeacht welke app de server start. Uit te zetten met REMINDERS_MCP_NO_DISCLAIM=1.
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
    // Bij succes vervangt posix_spawn (SETEXEC) dit proces; alleen bij een fout loopt de code hierna door.
    _ = posix_spawn(nil, path, nil, &attr, argv, envp)
    log("herstart als eigen verantwoordelijke mislukt; ga verder onder de startende app")
}

// MARK: - Start

reexecAsOwnResponsibleProcess()

let cliArguments = Array(CommandLine.arguments.dropFirst())
switch cliArguments.first {
case nil:
    runServer()
case "--check":
    // Vraagt zo nodig het macOS-toestemmingsvenster aan en toont daarna de status (zonder inhoud).
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
    // Eenmalig dagoverzicht naar stdout, bijv. `reminders-mcp --overview 2026-11-23`.
    var args: [String: Any] = [:]
    if cliArguments.count > 1 { args["date"] = cliArguments[1] }
    let outcome = callTool(name: "reminders_daily_overview", arguments: args)
    print(jsonString(outcome.payload))
    exit(outcome.isError ? 1 : 0)
case "--version":
    print("\(serverName) \(serverVersion)")
default:
    print("Gebruik: reminders-mcp            MCP-server over stdio (standaard)\n         reminders-mcp --check    toegang controleren / aanvragen\n         reminders-mcp --overview [YYYY-MM-DD]\n         reminders-mcp --version")
}
