# Home

Home is the top-level container of Infinite Recall — the first screen you see after signing in and completing onboarding. It owns the app's navigation structure and controls which features are accessible based on your subscription tier.

## What you see

The Home view is divided into two main areas: a collapsible left sidebar and a main content area. The sidebar lists all major sections — Conversations, Tasks, Memories, Rewind, Apps, Activity, and Settings. Clicking a section swaps the main content area to that feature's page. When the sidebar is collapsed, navigation icons remain visible so you can still move between sections without expanding it. There is no separate toolbar or top bar at the Home level; each feature page manages its own controls within the content area.

## What you can do

- Navigate to any feature by selecting it in the left sidebar.
- Collapse or expand the sidebar to reclaim horizontal space.
- Access tier-gated features once your subscription level includes them; locked sections are visible but require upgrading before use.
- Step through the onboarding flow on first launch, or skip it by passing `--skip-onboarding` at startup.

## States

- **Auth loading splash** — shown while the app restores your session from the macOS Keychain on launch. No interaction is possible until this completes.
- **Onboarding view** — shown to new users before the main content is accessible. Can be skipped with the `--skip-onboarding` launch flag.
- **Main content area** — the normal working state after onboarding is complete; the sidebar and active feature page are both visible.

## Behind the scenes

On launch, `AppState` is the first thing initialized. It calls `AuthService` to restore the saved Keychain session, checks your tier entitlements, and decides whether to present the onboarding flow or go straight to the main content area.

Home owns the sidebar selection state. When you navigate to a different section, Home updates that state and routes you to the appropriate page view. Feature pages — Conversations, Memories, Tasks, and others — are slotted into the main content area as nested views under Home.

Per-page state is preserved intentionally. If you switch from Conversations to Memories and back, your selected conversation, applied filters, and scroll position are restored. This is managed at the Home level so each child page does not need to handle its own restoration.

The sidebar's collapsed or expanded state is written to persistent storage and restored on the next app launch.

## Source

- `Desktop/Sources/MainWindow/DesktopHomeView.swift`
- `Desktop/Sources/AppState.swift`
- `Desktop/Sources/AuthService.swift`
