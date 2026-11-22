# reminders-mcp

Local MCP server for Apple Reminders on macOS, **read-only by default**. Works through Apple's EventKit
with the reminders that macOS itself syncs with iCloud. Writing (creating, editing, deleting) is
something you enable yourself, per capability. No iCloud login, no password, no
scraping, no network traffic: the server only talks over stdio to the agent that starts it.

## Installation

Requires: macOS 14 or newer and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh install
```

This builds a single binary and puts it in `~/.local/bin/reminders-mcp`. Then grant permission once:

```bash
~/.local/bin/reminders-mcp --check
```

macOS shows the prompt "reminders-mcp would like to access your reminders". Choose **Allow**. The output
then shows `"status": "full_access"`.

## Connecting to Codex

```bash
codex mcp add apple-reminders -- ~/.local/bin/reminders-mcp
```

Or manually in `~/.codex/config.toml`:

```toml
[mcp_servers.apple-reminders]
command = "/Users/YOURNAME/.local/bin/reminders-mcp"
```

Codex starts the server itself when a session or automation begins; nothing needs to run in the
background. Example prompt for the 7:00 planning:

> Call `reminders_daily_overview` and make my plan for the day. Keep `due_on_date` (today) and
> `overdue` separate.

Other MCP clients work the same way: command `~/.local/bin/reminders-mcp`, transport stdio, no arguments.

## Tools

| Tool | Purpose |
| --- | --- |
| `reminders_daily_overview` | Daily overview for today or another `date` (YYYY-MM-DD, `today`, `tomorrow`). Separate groups `due_on_date` and `overdue`; optionally `undated`. |
| `reminders_list_open` | Full list of all open reminders, optionally filtered by list and due date range. |
| `reminders_lists` | All lists with account and number of open reminders. |
| `reminders_access_status` | Permission status, time zone and the date that counts as "today". Does not open a prompt. |

Per reminder: `title`, `list`, `account`, `has_due_date`, `due` (`date`, `time`, `all_day`, `iso`),
`is_overdue`, `days_overdue`, `notes`, `priority`, `recurrence`, `alarms`, `created_at`, `modified_at`
and `subtasks`. Every response contains `field_availability` with what EventKit does and does not provide.

### Calendar tools (read-only)

| Tool | Purpose |
| --- | --- |
| `calendar_events` | Events for today, another `date`, or a range (`from`/`to`, max 62 days). `all_day` and `timed` are returned separately, in local time, with location, notes, attendees and your own response. Declined events are left out unless `include_declined` is true. |
| `calendar_calendars` | All calendars with account and type. |

These read every calendar that is set up in the macOS Calendar app on this Mac (iCloud, Google,
Exchange, subscriptions). A calendar that only exists in another app, for example Outlook, is not
visible until its account is added under System Settings > Internet Accounts with Calendars turned on.

Calendar access is a separate macOS permission. Grant it once with:

```bash
~/.local/bin/reminders-mcp --check-calendar
```

There are no calendar write tools: events cannot be created, changed or deleted.

### Write tools (off by default)

Without any setting the server only offers the four read tools. The environment variable
`REMINDERS_MCP_WRITE` enables writing; combine values with commas or use `all`.

The setting is read from the first of these that is present:

1. the argument `--write=create,update`
2. the environment variable `REMINDERS_MCP_WRITE`
3. the file `~/.config/reminders-mcp/write` (one line, e.g. `create,update`)

Use the file when a client does not pass configured environment variables to the server. The Codex
side of the ChatGPT desktop app was seen starting the server without them, which left it read-only.
`reminders_access_status` reports which source is in effect (`write_setting_source`).

| Value | Tools | What it does |
| --- | --- | --- |
| `create` | `reminders_create`, `reminders_create_list` | Create a reminder with title, list, due date/time, note, priority and recurrence; create an empty list. |
| `update` | `reminders_update` | Change fields, move to another list, complete or reopen. |
| `delete` | `reminders_delete` | Delete permanently; requires the exact title in `confirm_title`. |

For Codex, for example creating and updating only:

```bash
codex mcp remove apple-reminders
```

```bash
codex mcp add apple-reminders --env REMINDERS_MCP_WRITE=create,update -- ~/.local/bin/reminders-mcp
```

A due date with a time automatically gets an alarm at that moment. Lists cannot be renamed or
deleted. Subtasks, tags and the flag cannot be set (EventKit does not offer that).

### How "today" is determined

- **Today** = the calendar day from 00:00 to 24:00 in the Mac's system time zone, read again on
  every call. Every response states `time_zone`, `generated_at` and the definition used.
- **`due_on_date`** = open reminders with a due date on that day. A time with its own time zone is
  first converted to local time; "all day" counts on the calendar date. If the time has already
  passed today, the reminder stays here with `is_overdue: true`.
- **`overdue`** = open reminders with a due date before 00:00 today (for a date in the
  past: before that day).
- No due date → `has_due_date: false`, `due: null` and `due_note`. In the daily overview only
  included with `include_undated: true`; in `reminders_list_open` by default.

## Access and privacy

- **Permission:** Reminders only. EventKit has no separate read permission for Reminders;
  "full access" is the smallest permission that allows reading. Write tools only exist when
  `REMINDERS_MCP_WRITE` enables them; otherwise they are not offered and are refused.
- **Denied or missing:** every tool then returns `reminders_access_missing` with an explanation and steps
  (System Settings > Privacy & Security > Reminders > turn on `reminders-mcp`). To be asked
  again: `tccutil reset Reminders` and then `reminders-mcp --check`.
- **No copies:** reminders only exist in memory during a single call. No cache, no files.
- **Logs:** to stderr only, and only tool name, counts and duration. Never titles, notes or list names.
- What the agent does with the response (e.g. keeping it in its own session log) is outside this server's control.

## Limitations (honest)

- **Subtasks:** EventKit does not provide a parent/child relationship. Subtasks are included in the results, but as
  separate reminders; `subtasks` is then `null`. Optional, off by default: with
  `REMINDERS_MCP_SUBTASKS=sqlite` the server reads only the id pairs (child → parent task) from the local
  Reminders database. That requires **Full Disk Access** for `reminders-mcp`, relies on an
  undocumented schema that can change per macOS version, and is **not tested** on this Mac (no
  disk access while building). If the server does not recognize the schema, it reports that instead of guessing.
- **Not available via EventKit:** tags, flag, sections/columns, smart lists, list groups,
  attachments, assignment in shared lists, early reminders; the URL field usually not.
- **Recurrence:** you see the rule and the next open occurrence, not future occurrences. What happens
  when you complete a recurring reminder via `reminders_update` (whether or not the next occurrence
  is created) is **not tested**.
- **Ids:** the `id` of a reminder can change after an iCloud sync. Fetch a
  reminder again right before you update or delete it.
- **`reminders_create_list`** is built but not tested.
- **Freshness:** the server reads what macOS has synced locally. If the Mac was asleep or
  offline, the 7:00 overview can miss changes from your iPhone. The Mac must be on and
  logged in; the server cannot force an iCloud sync itself.
- **Permission is tied to the binary:** it is ad-hoc signed. After rebuilding or
  moving it, macOS may ask for permission again; run `reminders-mcp --check` in that case.
- **Own responsible process:** normally macOS ties the permission to the launching app (Codex,
  Terminal). From such an app, no permission prompt appeared during testing. That is why the server
  restarts itself once via `responsibility_spawnattrs_setdisclaim`, so that the permission belongs to
  `reminders-mcp` itself. This is a non-public macOS function (also used by Chromium, among others);
  if it goes away, the server keeps working under the launching app's permission. To disable:
  `REMINDERS_MCP_NO_DISCLAIM=1`.

## Manual testing

```bash
~/.local/bin/reminders-mcp --overview
```

Prints today's daily overview as JSON (including content, so only use it in your own terminal).

## License

MIT, see [LICENSE](LICENSE).
