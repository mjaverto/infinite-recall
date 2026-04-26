-- Stream B (issue #12, parent #9, contract 136f9faf6bafd199d98954393ede22c0d1998e2d).
-- Persistent absolute-time pause storage for the Activity tab.
--
-- One row per (target, id) pair currently paused. `resume_at` is the wall-time
-- (unix epoch seconds, UTC) at which the pause expires. Rows past that time
-- are treated as not-paused and may be deleted opportunistically.
--
-- target ∈ {'kind','capture'}
-- id     = WorkKind snake_case (e.g. 'transcribe','ocr',...) when target='kind'
--          OR 'audio'/'screen'                                when target='capture'

CREATE TABLE IF NOT EXISTS paused_work (
    target    TEXT    NOT NULL,
    id        TEXT    NOT NULL,
    resume_at INTEGER NOT NULL,
    PRIMARY KEY (target, id)
);
