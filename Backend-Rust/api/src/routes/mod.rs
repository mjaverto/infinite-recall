//! HTTP route surface — Omi-shaped. Read-only by default; the
//! `/v1/action-items` family is the only mutation surface (see
//! `action_items.rs`).

use axum::{
    middleware,
    routing::{get, patch, post},
    Router,
};
use tower_http::trace::TraceLayer;

use crate::auth::require_bearer;
use crate::state::AppState;

mod action_items;
mod activity;
mod conversations;
mod health;
mod memories;
mod people;
mod scores;
mod search;

pub fn router(state: AppState) -> Router {
    // Authenticated routes — the bulk of the surface.
    let authed = Router::new()
        .route("/v1/conversations", get(conversations::list))
        .route("/v1/conversations/:id", get(conversations::get_one))
        .route("/v3/memories", get(memories::list))
        .route("/v3/memories/:id", get(memories::get_one))
        // Action items: list (GET) and create (POST) share the collection URL;
        // PATCH / soft-delete share the item URL; complete is its own POST.
        .route(
            "/v1/action-items",
            get(action_items::list).post(action_items::create),
        )
        .route(
            "/v1/action-items/:id",
            patch(action_items::update).delete(action_items::delete),
        )
        .route(
            "/v1/action-items/:id/complete",
            post(action_items::complete),
        )
        .route("/v1/people", get(people::list))
        .route("/v1/people/:id", get(people::get_one))
        .route("/v1/search", get(search::search))
        .route("/v1/scores", get(scores::scores))
        // === activity:A ===
        .route("/v1/activity/snapshot", get(activity::snapshot))
        .route("/v1/activity/pause", post(activity::pause))
        .route("/v1/activity/resume", post(activity::resume))
        .route("/v1/activity/_internal/inflight", post(activity::inflight))
        .route(
            "/v1/activity/_internal/queue-depth",
            post(activity::internal_queue_depth),
        )
        // === /activity:A ===
        // === activity:32 ===
        // Swift→Rust loopback for the processing gate (issue #32).
        .route(
            "/v1/activity/_internal/gate-state",
            post(activity::gate_state),
        )
        // === /activity:32 ===
        .route_layer(middleware::from_fn_with_state(
            state.clone(),
            require_bearer,
        ));

    // Public — health/version are unauthenticated so launchd & monitors can poll.
    let public = Router::new()
        .route("/v1/health", get(health::health))
        .route("/v1/version", get(health::version));

    Router::new()
        .merge(public)
        .merge(authed)
        .with_state(state)
        .layer(TraceLayer::new_for_http())
}
