# ScreenRecall source rules

Keep preferences, capture libraries, catalogs, build products and signing material
outside this source tree. Use synthetic fixtures for tests and documentation media.
Never capture or publish real user screens for validation. Preserve the installed
bundle identity and explicit data location when updating an existing app.

Build: `./script/build_and_run.sh --build-only` (signs; no install or launch).
`--demo` opens a separate synthetic app. `--verify` installs and launches; saved
recording intent may resume. Review that boundary before using it.

Before sharing, stage named source paths and run
`deno run --allow-run=git script/check_public.ts`. The check reads the Git index and
all reachable history. New binary documentation/dependency assets need reviewed
hashes in public-source.json. Keep all third-party notices and license scopes.

User images, catalog annotations and view state are durable data. Never delete,
move or bulk-reencode a real capture library without explicit owner authority.
Never copy a live SQLite main file alone: use SQLite's Backup API or a stopped,
checkpointed copy with the required sidecars accounted for.

Tests use synthetic disposable libraries. No-recording validation excludes
`sleepSuspensionStopsTheLoopButKeepsActiveIntent`,
`displaySleepWaitsForAnAwakeDisplayWithoutLosingRecordingIntent` and
`displaySleepEndsBurstAndKeepsPriorDailyIntent`; these use active observer intent.
Do not describe that subset as complete recording or UI acceptance.
