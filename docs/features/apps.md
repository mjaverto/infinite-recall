# Apps

The Apps page is how you connect Infinite Recall to other data sources on your Mac. By default, Infinite Recall only sees what you give it directly — but most useful context lives elsewhere: in your calendar, your notes, your existing tools. Apps lets you bring that context in so the rest of the app (Tasks, Memories, Focus, chat) can draw on it. It also surfaces export destinations when integrations support writing data back.

## What you see

- A search bar at the top for filtering by name or category.
- A **Featured apps** section. In local-first builds the remote catalog is empty by design — most users will see this section blank. It is a placeholder for a future marketplace.
- A **My Apps** section listing connectors you have already configured locally.
- Category filters and infinite scroll for browsing available apps.
- Tapping any app opens its detail view: a full description, configuration controls, and any active toggles.
- Export destinations appear here when an integration supports writing data back (for example, creating a note for a daily summary).

## What you can do

- Search apps by name or keyword.
- Filter the list by category.
- Tap into any app to read its description and configure it.
- Set up local integrations — Apple Notes and Google Calendar are the primary two — so their data feeds into Tasks, Memories, and Focus.
- Configure export destinations for features like daily summaries.

## States

- **Loading shimmer** while the catalog is fetching on first open.
- **Filter loading state** when a category filter is being applied.
- **Empty state** when the remote catalog returns nothing (the expected state in local-first mode).
- **No results** when a search or filter combination yields no matches.

## Behind the scenes

**Local-first by design.** Infinite Recall does not talk to a remote app marketplace. The Featured section exists for a future catalog; in the current build it is always empty. The real work happens in My Apps — the local connectors you configure here.

**Apple Notes integration.** `AppleNotesReaderService` opens a read-only connection to the macOS Notes SQLite store and queries notes by folder. Those notes become context available across the app: the Task extraction pipeline can surface a project deadline mentioned in a note as a task with `external_system` origin, and the chat panel can reference recent notes directly.

**Google Calendar integration.** `CalendarReaderService` reads your Google Calendar events by decrypting your existing browser cookies — no separate OAuth flow or credential entry required. A small Python helper extracts upcoming events and caches them locally. Calendar events are a primary source of `calendar_driven` tasks: when the extraction pipeline sees an event that implies a commitment or deadline, it creates or updates the corresponding task automatically.

**Where the data goes.** Configured integrations are not siloed on this page. Their data is wired into the rest of the app's context pipeline. The Focus and Task assistants (see [tasks.md](tasks.md)) include calendar events and recent notes when querying the local LLM for action items. The chat panel can reference them in responses.

**Export destinations.** When an integration supports writing back — for example, creating an Apple Note for the day's summary — it registers itself as an export destination and appears in this section.

## Source

- `Desktop/Sources/MainWindow/Pages/AppsPage.swift`
- `Desktop/Sources/AppleNotesReaderService.swift`
- `Desktop/Sources/CalendarReaderService.swift`
