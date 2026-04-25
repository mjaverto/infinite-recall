//! HTTP route surface — Omi-shaped, read-only.

use axum::{
    middleware,
    routing::get,
    Router,
};
use tower_http::trace::TraceLayer;

use crate::auth::require_bearer;
use crate::state::AppState;

mod action_items;
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
        .route("/v1/action-items", get(action_items::list))
        .route("/v1/people", get(people::list))
        .route("/v1/people/:id", get(people::get_one))
        .route("/v1/search", get(search::search))
        .route("/v1/scores", get(scores::scores))
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
