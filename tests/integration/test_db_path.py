"""Regression tests for the daemon's resolved DB path."""
from __future__ import annotations

import os

import httpx


def test_daemon_main_db_path_matches_user_dir(daemon):
    """Catch: daemon stays pinned to old DB path after directory swap.

    Asserts /v1/_test/db.main.path resolves to the env-configured location AND
    its inode matches os.stat — proving the daemon is reading from the file we
    think it is.
    """
    r = httpx.get(
        f"{daemon.base_url}/v1/_test/db",
        headers={"Authorization": f"Bearer {daemon.bearer_token}"},
        timeout=5,
    )
    r.raise_for_status()
    body = r.json()

    main = body["main"]
    assert main["path"] == str(daemon.db_path), (
        f"daemon resolved DB path {main['path']!r} but we configured {daemon.db_path!r}"
    )
    assert main["exists"] is True, "daemon-resolved DB file does not exist"
    on_disk_ino = os.stat(daemon.db_path).st_ino
    assert main["inode"] == on_disk_ino, (
        f"daemon's open DB inode ({main['inode']}) differs from on-disk inode "
        f"({on_disk_ino}) — daemon is pinned to a stale file handle"
    )


def test_build_endpoint_reports_test_feature(daemon):
    r = httpx.get(
        f"{daemon.base_url}/v1/_test/build",
        headers={"Authorization": f"Bearer {daemon.bearer_token}"},
        timeout=5,
    )
    r.raise_for_status()
    assert "test_introspection" in r.json()["features"]
