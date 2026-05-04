# Tasks

Tasks is a to-do list built from your activity. Infinite Recall watches your conversations and screen, extracts actionable items automatically, and adds them to your list. You can also create tasks by hand. Every task carries a priority, category, due date, and origin so you can slice and filter the list however you need.

## What you see

Tasks are grouped into four due-date buckets: **Today**, **Tomorrow**, **Later**, and **No Deadline**. Each bucket has an inline create row at the top so you can add a task without opening a separate form — navigate to it with the keyboard, type, and press Return.

A filter sidebar or bar sits alongside the list with controls for every dimension the model tracks. On the right, an optional chat panel lets you ask questions about your tasks in plain language. The panel is resizable and its width is saved between sessions; close it when you do not need it and reopen it without losing your layout.

## What you can do

**Create tasks inline.** Click or keyboard-navigate to the create row inside any due-date bucket and start typing. Tab through the fields to set priority, category, and due date without leaving the row.

**Complete and uncomplete tasks.** Toggle the checkbox on any task. The task moves to the Done state and stays in your list so you have a record of what you finished.

**Delete tasks.** Remove a task permanently. The app tracks whether a task was removed by the AI or by you as separate filter states, so you can audit what the model discarded without mixing it with your own removals.

**Filter on multiple dimensions simultaneously.**

- Status: To Do, Done, Removed by AI, Removed by me
- Category: Personal, Work, Feature, Bug, Code, Research, Communication, Finance, Health, Other
- Priority: High, Medium, Low
- Source: Screen capture, Transcription Omi, Transcription Desktop, Manual, Analytics
- Date range: e.g., last 7 days
- Origin: Direct Request, Self-Generated, Calendar-Driven, Reactive, External System

**Save custom filters.** Combine any set of filter values and save the combination under a name. One click restores the full filter state later.

**Chat about your tasks.** Open the right-side chat panel and ask the local AI anything about your task list — "what's overdue?", "summarize my work tasks for today", or "which tasks are blocking the finance review?" The AI has direct read access to your tasks and answers without sending data off-device.

**Resize the chat panel.** Drag the divider between the task list and chat panel. The width persists across sessions. Close the panel entirely to reclaim the space.

## States

**Loading.** A shimmer appears over the task list while the initial fetch completes.

**Empty.** When you have no tasks at all, the view shows a prompt to create your first task or wait for the assistant to extract one.

**No results.** When active filters match nothing, the list shows a "no results" message with a nudge to adjust the filters. Your tasks are still there; nothing was deleted.

**Local AI unavailable.** A status banner appears at the top of the view when the local LLM is unreachable — for example, if the model process has not started or crashed. Automatic extraction pauses and the chat panel disables until the model comes back online.

## Behind the scenes

**Extraction trigger.** `TaskAssistant` wakes on two signals: a change to the active application and expiry of a configurable extraction-interval timer. When either fires, the assistant captures the current screen frame and gathers recent task history, then sends both to the local LLM in JSON mode.

**Tool calls the model uses.** The model works through a small toolkit rather than generating free-form text.

- `search_similar` — searches existing tasks for near-duplicates before creating anything new.
- `read_screenshot_ocr` — pulls readable text out of the current screen frame.
- `extract_task` — emits a new task with all inferred fields.
- `reject_task` — signals that nothing actionable is present, ending the extraction pass cleanly.

**What the model infers.** For each task the model assigns a priority (1 = High, 2 = Medium, 3 = Low), a category from the fixed list, an origin label (`direct_request`, `self_generated`, `calendar_driven`, `reactive`, or `external_system`), and a due date parsed from natural language ("by Friday", "tomorrow morning"). When no date is mentioned, the model defaults to end-of-day.

**Deduplication and Goal promotion.** The `search_similar` call runs before any `extract_task` call. If a close match exists, the model updates the existing task rather than creating a duplicate. If the task aligns with an active Goal (configured in Settings > Advanced > Goals), it is promoted and linked to that goal so it appears in the Goals view as well.

**Staging.** Extracted tasks land in `StagedTaskStorage` first. They are visible in your list immediately, flagged as AI-generated. You can keep, edit, or remove them. Removing a staged task sets the "Removed by AI" state rather than deleting the record, so the filter can surface it later if you want to review what the model dropped.

**Calendar-driven tasks.** Tasks with `calendar_driven` origin come from the local Calendar integration reading your events directly. The LLM does not extract these from a transcript; they arrive through a separate pipeline and are labeled accordingly.

**Chat panel.** The right-side chat uses the same local AI provider configured in Settings > AI / Models. It reads your task list directly for context and generates responses on-device. No task data leaves the machine.

## Source

- `Desktop/Sources/MainWindow/Pages/TasksPage.swift`
- `Desktop/Sources/ProactiveAssistants/Assistants/TaskExtraction/TaskAssistant.swift`
- `Desktop/Sources/ProactiveAssistants/Assistants/TaskExtraction/TaskModels.swift`
