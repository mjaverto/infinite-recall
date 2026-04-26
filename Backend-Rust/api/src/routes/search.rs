//! /v1/search — unified search across OCR (screenshots), audio (transcript
//! segments), and VLM-derived visual activity summaries.
//!
//! - `content_type=ocr`    → FTS5 query against `screenshots_fts`
//! - `content_type=audio`  → LIKE on `transcription_segments.text`
//! - `content_type=visual` → FTS5 query against `visual_activity_fts`
//!                           (visual summary + UI state + OCR snapshot, all from VLM pipeline)
//! - `content_type=both`   → ocr + audio + visual, merged
//!
//! The Swift app maintains FTS5 mirrors for screenshots and visual_activity;
//! transcript segments have no FTS table so we fall back to LIKE there.

use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::db::with_conn;
use crate::error::{ApiError, ApiResult};
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct SearchQuery {
    pub q: String,
    pub content_type: Option<String>,
    pub app: Option<String>,
    pub start: Option<String>,
    pub end: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Serialize)]
struct OcrHit {
    pub screenshot_id: i64,
    pub timestamp: Option<String>,
    pub app_name: String,
    pub window_title: Option<String>,
    pub snippet: String,
}

#[derive(Debug, Serialize)]
struct AudioHit {
    pub session_id: i64,
    pub segment_order: i64,
    pub speaker: i64,
    pub start_time: f64,
    pub end_time: f64,
    pub text: String,
}

#[derive(Debug, Serialize)]
struct VisualHit {
    pub visual_activity_id: i64,
    pub screenshot_id: i64,
    pub sampled_at: Option<String>,
    pub app_name: Option<String>,
    pub window_title: Option<String>,
    pub visual_summary: Option<String>,
    pub snippet: String,
}

pub async fn search(
    State(state): State<AppState>,
    Query(q): Query<SearchQuery>,
) -> ApiResult<Json<Value>> {
    if q.q.trim().is_empty() {
        return Err(ApiError::BadRequest("q is required".into()));
    }
    let kind = q.content_type.clone().unwrap_or_else(|| "both".into());
    let limit = q.limit.unwrap_or(50).clamp(1, 500);

    let want_ocr = kind == "ocr" || kind == "both";
    let want_audio = kind == "audio" || kind == "both";
    let want_visual = kind == "visual" || kind == "both";

    let qstr = q.q.clone();
    let app = q.app.clone();
    let start = q.start.clone();
    let end = q.end.clone();

    let result = with_conn(&state.pool, move |c| {
        let mut ocr_hits: Vec<OcrHit> = Vec::new();
        let mut audio_hits: Vec<AudioHit> = Vec::new();
        let mut visual_hits: Vec<VisualHit> = Vec::new();

        if want_ocr {
            // FTS5 MATCH; sanitize by quoting to treat as a phrase.
            let fts_query = format!("\"{}\"", qstr.replace('"', " "));
            let mut sql = String::from(
                "SELECT s.id, s.timestamp, s.appName, s.windowTitle,
                        snippet(screenshots_fts, 0, '<b>', '</b>', '…', 16)
                 FROM screenshots_fts
                 JOIN screenshots s ON s.rowid = screenshots_fts.rowid
                 WHERE screenshots_fts MATCH ?",
            );
            let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
            params.push(Box::new(fts_query));
            if let Some(a) = app.clone() {
                sql.push_str(" AND s.appName = ?");
                params.push(Box::new(a));
            }
            if let Some(s) = start.clone() {
                sql.push_str(" AND s.timestamp >= ?");
                params.push(Box::new(s));
            }
            if let Some(e) = end.clone() {
                sql.push_str(" AND s.timestamp < ?");
                params.push(Box::new(e));
            }
            sql.push_str(" ORDER BY s.timestamp DESC LIMIT ?");
            params.push(Box::new(limit));

            let mut stmt = c.prepare(&sql)?;
            let param_refs: Vec<&dyn rusqlite::ToSql> =
                params.iter().map(|p| p.as_ref() as &dyn rusqlite::ToSql).collect();
            let mut rows = stmt.query(rusqlite::params_from_iter(param_refs))?;
            while let Some(r) = rows.next()? {
                ocr_hits.push(OcrHit {
                    screenshot_id: r.get(0)?,
                    timestamp: r.get(1)?,
                    app_name: r.get(2)?,
                    window_title: r.get(3)?,
                    snippet: r.get(4)?,
                });
            }
        }

        if want_audio {
            let like = format!("%{}%", qstr);
            let mut stmt = c.prepare(
                "SELECT sessionId, segmentOrder, speaker, startTime, endTime, text
                 FROM transcription_segments
                 WHERE text LIKE ?
                 ORDER BY id DESC
                 LIMIT ?",
            )?;
            let mut rows = stmt.query(rusqlite::params![like, limit])?;
            while let Some(r) = rows.next()? {
                audio_hits.push(AudioHit {
                    session_id: r.get(0)?,
                    segment_order: r.get(1)?,
                    speaker: r.get(2)?,
                    start_time: r.get(3)?,
                    end_time: r.get(4)?,
                    text: r.get(5)?,
                });
            }
        }

        if want_visual {
            // FTS5 MATCH against the visual_activity FTS mirror. Same
            // phrase-quoting trick as the OCR branch to stay literal.
            let fts_query = format!("\"{}\"", qstr.replace('"', " "));
            let mut sql = String::from(
                "SELECT v.id, v.screenshotId, v.sampledAt, v.appName, v.windowTitle,
                        v.visualSummary,
                        snippet(visual_activity_fts, 0, '<b>', '</b>', '…', 16)
                 FROM visual_activity_fts
                 JOIN visual_activity v ON v.rowid = visual_activity_fts.rowid
                 WHERE visual_activity_fts MATCH ?",
            );
            let mut params: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();
            params.push(Box::new(fts_query));
            if let Some(a) = app.clone() {
                sql.push_str(" AND v.appName = ?");
                params.push(Box::new(a));
            }
            if let Some(s) = start.clone() {
                sql.push_str(" AND v.sampledAt >= ?");
                params.push(Box::new(s));
            }
            if let Some(e) = end.clone() {
                sql.push_str(" AND v.sampledAt < ?");
                params.push(Box::new(e));
            }
            sql.push_str(" ORDER BY v.sampledAt DESC LIMIT ?");
            params.push(Box::new(limit));

            let mut stmt = c.prepare(&sql)?;
            let param_refs: Vec<&dyn rusqlite::ToSql> =
                params.iter().map(|p| p.as_ref() as &dyn rusqlite::ToSql).collect();
            let mut rows = stmt.query(rusqlite::params_from_iter(param_refs))?;
            while let Some(r) = rows.next()? {
                visual_hits.push(VisualHit {
                    visual_activity_id: r.get(0)?,
                    screenshot_id: r.get(1)?,
                    sampled_at: r.get(2)?,
                    app_name: r.get(3)?,
                    window_title: r.get(4)?,
                    visual_summary: r.get(5)?,
                    snippet: r.get(6)?,
                });
            }
        }

        Ok::<_, anyhow::Error>(json!({
            "query": qstr,
            "content_type": kind,
            "ocr_hits": ocr_hits,
            "audio_hits": audio_hits,
            "visual_hits": visual_hits,
        }))
    })
    .await
    .map_err(ApiError::Internal)?;

    Ok(Json(result))
}
