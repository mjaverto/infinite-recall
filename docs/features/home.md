# Home

Home is the top-level container of Infinite Recall — the first screen you see after launching the app. It owns the app's navigation structure and hosts every other feature page within its main content area. Infinite Recall is local-first and account-free; there is no sign-in, no tier, and nothing gated behind a subscription.

## What you see

The Home view is divided into two main areas: a collapsible left sidebar and a main content area. The sidebar lists the seven feature sections — Home, Conversations, Memories, Tasks, Rewind, Apps, and Activity. Clicking a section swaps the main content area to that feature's page. Settings opens in a separate window, accessed from a gear icon, not from this sidebar. When the sidebar is collapsed, navigation icons remain visible so you can still move between sections without expanding it. There is no separate toolbar or top bar at the Home level; each feature page manages its own controls within the content area.

## What you can do

- Navigate to any feature by selecting it in the left sidebar.
- Collapse or expand the sidebar to reclaim horizontal space.
- Step through the onboarding flow on first launch, or skip it by passing `--skip-onboarding` at startup.

## States

- **Startup initialisation** — shown briefly while the app loads its local database and decides whether to present onboarding or the main content area. No interaction is possible until this completes. Typically a fraction of a second.
- **Onboarding view** — shown to new users before the main content is accessible. Can be skipped with the `--skip-onboarding` launch flag.
- **Main content area** — the normal working state after onboarding is complete; the sidebar and active feature page are both visible.

## Behind the scenes

On launch, `AppState` initialises the local stores (conversations, memories, tasks, rewind), reads persisted UI preferences, and checks whether the onboarding flow has been completed before. Everything is read from the local SQLite databases under `~/Library/Application Support/`; there is no remote session to restore.

Home owns the sidebar selection state. When you navigate to a different section, Home updates that state and routes you to the appropriate page view. Feature pages — Conversations, Memories, Tasks, and others — are slotted into the main content area as nested views under Home.

Per-page state is preserved across navigation. If you switch from Conversations to Memories and back, your selected conversation, applied filters, and scroll position are restored. This is managed at the Home level so each child page does not need to handle its own restoration.

The sidebar's collapsed or expanded state is written to persistent storage and restored on the next app launch.

## Source

- `Desktop/Sources/MainWindow/DesktopHomeView.swift`
- `Desktop/Sources/AppState.swift`
