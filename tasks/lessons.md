# Lessons

- For non-trivial build requests, create/update `tasks/todo.md` with checkable items before implementation and keep it current as work progresses.
- When the user asks for delegated review/fixes, do not continue patching in the main thread; aggregate reviewer consensus and delegate the implementation work to a worker.
- After correcting diarization/identity logic, delegate a focused regression-review pass and add narrow DB-backed tests that lock the bug class (segment-scoped assignment, atomic merges, and conservative training-sample flags).
