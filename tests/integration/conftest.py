"""Session-scoped daemon fixture for /v1/_test/* introspection tests.

Builds the daemon binary once with `test_introspection` enabled, spins it
up in a TemporaryDirectory pointed at synthetic DB / token paths, polls
/v1/_test/build until ready, and tears down via SIGTERM (then SIGKILL).
"""
from __future__ import annotations

import os
import signal
import socket
import sqlite3
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import httpx
import pytest

# Repo layout: tests/integration/conftest.py -> repo root is two parents up.
REPO_ROOT = Path(__file__).resolve().parents[2]
BACKEND_DIR = REPO_ROOT / "Backend-Rust"
BIN_PATH = BACKEND_DIR / "target" / "debug" / "infinite-recall-api"


@dataclass
class Daemon:
    base_url: str
    bearer_token: str
    db_path: Path
    activity_db_path: Path
    tmp_dir: Path


def _seed_db(path: Path) -> None:
    """Create an empty SQLite DB at `path` in WAL mode.

    The daemon's read-only and read-write pools both fail-fast when the
    file is absent; the read-write pool also warns unless the file is in
    WAL journal mode. Real Swift app behavior creates this file during
    its first launch — for tests we synthesize it.
    """
    conn = sqlite3.connect(path)
    try:
        conn.execute("PRAGMA journal_mode=WAL")
        conn.commit()
    finally:
        conn.close()


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _ensure_binary() -> Path:
    """Build the daemon with `test_introspection` if the binary isn't present.

    The CI agent should pre-build to keep the fixture fast; this is a
    safety net for local runs.
    """
    if BIN_PATH.exists():
        return BIN_PATH
    subprocess.run(
        [
            "cargo",
            "build",
            "--quiet",
            "-p",
            "infinite-recall-api",
            "--features",
            "test_introspection",
        ],
        cwd=BACKEND_DIR,
        check=True,
    )
    return BIN_PATH


def _read_token(token_path: Path, deadline: float) -> str:
    while time.monotonic() < deadline:
        if token_path.exists():
            text = token_path.read_text().strip()
            if text:
                return text
        time.sleep(0.1)
    raise TimeoutError(f"token file never appeared at {token_path}")


def _wait_for_build(base_url: str, token: str, deadline: float) -> None:
    headers = {"Authorization": f"Bearer {token}"}
    last_err: Exception | None = None
    backoff = 0.1
    while time.monotonic() < deadline:
        try:
            r = httpx.get(f"{base_url}/v1/_test/build", headers=headers, timeout=2)
            if r.status_code == 200:
                return
            last_err = RuntimeError(f"status {r.status_code}: {r.text[:200]}")
        except httpx.HTTPError as e:
            last_err = e
        time.sleep(backoff)
        backoff = min(backoff * 1.5, 1.0)
    raise TimeoutError(f"daemon /v1/_test/build never returned 200: {last_err!r}")


@pytest.fixture(scope="session")
def daemon() -> Daemon:
    binary = _ensure_binary()

    tmp = tempfile.TemporaryDirectory(prefix="ir-integration-")
    tmp_path = Path(tmp.name)

    db_path = tmp_path / "Omi" / "users" / "anonymous" / "omi.db"
    activity_db_path = tmp_path / "InfiniteRecall" / "activity.db"
    token_path = tmp_path / "InfiniteRecall" / "api-token.txt"
    db_path.parent.mkdir(parents=True, exist_ok=True)
    activity_db_path.parent.mkdir(parents=True, exist_ok=True)

    # The daemon refuses to start if the main DB file is missing (it expects
    # the Swift app to have created it). Create an empty DB in WAL mode so
    # the read-only and read-write pools both open cleanly.
    _seed_db(db_path)

    port = _free_port()
    bind = f"127.0.0.1:{port}"

    env = {
        **os.environ,
        "INFINITE_RECALL_BIND": bind,
        "INFINITE_RECALL_DB": str(db_path),
        "INFINITE_RECALL_ACTIVITY_DB": str(activity_db_path),
        "INFINITE_RECALL_TOKEN_PATH": str(token_path),
        "IR_TEST_INTROSPECTION": "1",
        "RUST_LOG": "warn",
    }

    # start_new_session so SIGTERM hits the whole process group cleanly.
    proc = subprocess.Popen(
        [str(binary)],
        env=env,
        cwd=str(BACKEND_DIR),
        start_new_session=True,
    )

    try:
        deadline = time.monotonic() + 30.0
        token = _read_token(token_path, deadline)
        base_url = f"http://{bind}"
        _wait_for_build(base_url, token, deadline)

        yield Daemon(
            base_url=base_url,
            bearer_token=token,
            db_path=db_path,
            activity_db_path=activity_db_path,
            tmp_dir=tmp_path,
        )
    finally:
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait(timeout=5)
        tmp.cleanup()
