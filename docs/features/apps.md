# Apps

The Apps page is how you connect Infinite Recall to other data sources on your Mac. By default, Infinite Recall only sees what you give it directly — but most useful context lives elsewhere: in your calendar, your notes, your existing tools. Apps lets you bring that context in so the rest of the app (Tasks, Memories, Focus, chat) can draw on it. It also surfaces export destinations when integrations support writing data back.

## What you see

- A search bar at the top for filtering by name or category.
- A **Featured apps** section. The remote catalogue is empty in this build by design — Infinite Recall is local-first and does not talk to a remote app marketplace. The section is a placeholder for a future catalogue.
- An **Imports** section with six built-in connectors (Calendar, Email/Gmail, Local files, Apple Notes, ChatGPT, Claude) — these import data from outside the app into the local memory store.
- A **My Apps** section listing the local export integrations you have configured (webhook destinations and filesystem export folders).
- Category filters and infinite scroll for browsing available apps.
- Tapping any connector opens its detail sheet: a description, the connect/sync action, current status, latched error state when a previous read failed, and a Disconnect button when the connector has any persisted state.

## What you can do

- Search apps by name or keyword.
- Filter the list by category.
- Tap into any connector to read its description and configure it.
- Set up Imports — Calendar, Gmail, Apple Notes, Local files, ChatGPT, Claude — so their data feeds into Tasks, Memories, and Focus.
- Configure local export destinations (webhooks and filesystem folders) under My Apps so your captured memories can flow out to the rest of your toolchain.
- Disconnect a connector to clear its persisted state and remove it from the connected list.

## States

- **Loading shimmer** while the catalog is fetching on first open.
- **Filter loading state** when a category filter is being applied.
- **Empty state** when the remote catalog returns nothing (the expected state in local-first mode).
- **No results** when a search or filter combination yields no matches.
- **Error / re-grant** state on a connector card when the most recent read failed (for example, Apple Notes after the user revoked Full Disk Access). The card surfaces the error message and switches the action to Reconnect.

## Behind the scenes

**Local-first by design.** Infinite Recall does not talk to a remote app marketplace. The Featured section exists for a future catalog; in the current build it is always empty. The real work happens in Imports and My Apps. Every memory that an Imports connector creates is written to the local GRDB store via `MemoryStorage.insertLocalMemory` first; if you have My Apps export destinations configured (webhook URLs or filesystem folders), the local write can then be mirrored to those user-chosen destinations. Nothing is sent to a marketplace, telemetry endpoint, or Anthropic/Google/Apple cloud — only to the destinations you explicitly enable.

### Imports connectors

**Calendar (Google Calendar).** `CalendarReaderService` reads your Google Calendar events by decrypting your existing browser cookies — no separate OAuth flow or credential entry required. A small Python helper extracts upcoming events and caches them locally. Calendar events are a primary source of `calendar_driven` tasks: when the extraction pipeline sees an event that implies a commitment or deadline, it creates or updates the corresponding task automatically.

**Email (Gmail).** `GmailReaderService` follows the same browser-cookie + SAPISID auth pattern as Calendar — it decrypts Chromium cookies via Keychain and uses them to read up to 365 days of email through the Gmail HTTP endpoints, no Google OAuth required. This is the most invasive integration in the catalog: it scans every Chromium-based browser profile on the machine looking for valid Gmail sessions. Each email becomes a memory tagged `gmail`/`email` with the subject as the headline.

**Local files.** Always available on this device. Hooks into the on-device file indexer (`FileIndexerService` and friends) to rescan documents, code, and working folders. Indexed files become searchable context — they are not stored as discrete memories but the indexer is part of the same local subsystem the memory store uses.

**Apple Notes.** `AppleNotesReaderService` opens a read-only connection to the macOS Notes SQLite store at `~/Library/Group Containers/group.com.apple.notes/NoteStore.sqlite` and queries notes by folder. Requires Full Disk Access or an explicit folder grant. Notes become memories tagged `apple_notes`/`note`/`import`. If the read fails (schema migration, file moved, permission revoked), the card switches to a Reconnect state and surfaces the underlying error instead of falsely reporting "Connected".

**ChatGPT memory paste.** Manual import flow via `OnboardingMemoryLogImportService`. The connector opens ChatGPT, copies a memory-export prompt to the clipboard, and provides a text area where the user pastes the response. The local LLM then extracts durable memories from the pasted conversation.

**Claude memory paste.** Same `OnboardingMemoryLogImportService` flow as ChatGPT, but targeting Claude's web UI.

### Disconnect flow

Every connector except Local files exposes a Disconnect button in its detail sheet. Disconnect calls `ImportConnectorStatusStore.clear(connectorID:)` which removes every UserDefaults key the store ever wrote for that connector — source counts, memory counts, sync timestamps, delta counts, plus connector-specific extras (Apple Notes folder grant, legacy onboarding paste counts). After disconnecting, the card renders the same as a fresh install. Memories already saved from a connector are not retroactively deleted; they keep their `source` tag so the user can prune them from the Memories page if they want.

### My Apps (local export integrations)

The My Apps section is separate from Imports — it covers data flowing **out** of Infinite Recall to local destinations:

- **Webhook destinations.** A user-configured HTTP endpoint that receives a JSON payload every time a memory is created. Backed by `LocalIntegrationStorage` (config) and `LocalIntegrationDrainService` (delivery + retry). Useful for piping memories into Obsidian, a personal Slack, a homelab logger, etc.
- **Filesystem export folders.** A user-configured directory that receives a file per memory. Same backend — `LocalIntegrationStorage` keeps the destination, `LocalIntegrationDrainService` writes the files and retries on transient errors.

Both export types are dispatched fire-and-forget from `MemoryStorage.insertLocalMemory` so they never block the memory write path.

**Where the data goes.** Imports data lands in the local memory store and is wired into the rest of the app's context pipeline. The Focus and Task assistants (see [tasks.md](tasks.md)) include calendar events, recent notes, and Gmail history when querying the local LLM for action items. The chat panel can reference them in responses.

## Source

- `Desktop/Sources/MainWindow/Pages/AppsPage.swift`
- `Desktop/Sources/AppleNotesReaderService.swift`
- `Desktop/Sources/CalendarReaderService.swift`
- `Desktop/Sources/GmailReaderService.swift`
- `Desktop/Sources/OnboardingMemoryLogImportService.swift`
- `Desktop/Sources/MainWindow/Pages/LocalIntegrations/MyAppsSection.swift`
- `Desktop/Sources/LocalIntegrations/LocalIntegrationStorage.swift`
- `Desktop/Sources/LocalIntegrations/LocalIntegrationDrainService.swift`
- `Desktop/Sources/Rewind/Core/MemoryStorage.swift`
