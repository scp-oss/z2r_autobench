# CLAUDE.md

Operational notes for Claude sessions working on this repo — dense, for an
agent, not prose for an external reader (that's what README.md is for).
Do not put server names, individual people's names, or unpublished/draft
project names here — same public-repo constraint as README.md.

## Workflow constraints

- Designated branch: `main`. Changed 2026-08-26 from a long-running
  feature branch (`claude/z2r-autobench-open-issues-hq8gjy`) — see
  "Feature branch merged into main" below for why. Never push elsewhere
  without explicit permission.
- `git push` to GitHub now works directly from this sandbox (confirmed
  working as of this note) — no more format-patch/SendUserFile/git-am
  handoff needed. Earlier in this engagement it 403'd (both raw `git push`
  and the GitHub API `push_files`/`create_repository`); that restriction
  lifted at some point without an explicit announcement, so if push starts
  403ing again, fall back to: commit locally → `git format-patch` →
  `SendUserFile` → user runs `git am <patch> && git push` on the
  deployment box → verify with `git fetch`/`git log` afterward.
- No execution access to the deployment box itself (no SSH, no remote-exec
  tool) — only git. Anything that needs to actually run there (sandbox
  setup, the orchestrator, systemctl, iptables) has to be handed to the
  user as exact commands; it can't be run from here even though pushing
  the code that defines those commands now can be.
- Before generating a patch (only relevant if push is 403ing again), if
  there's any chance earlier patches were already applied, fetch and check
  the real remote HEAD first — format-patching against a stale local HEAD
  produces `git am` conflicts that look like real problems but are just
  base drift. Recovery: fetch, diff old local commit vs new remote tip for
  content parity (should be empty), `git checkout -B tmp <remote-tip>`,
  `git cherry-pick <local-commit>`, patch just that.
- Never assume the deployment box's checkout is on the right branch after
  a bootstrap/reinstall — a plain `git clone` with no branch arg lands on
  the repo's default branch. Confirm via `git branch --show-current`
  before trusting `git log` output from there.
- All entry-point `*.sh` scripts are tracked `100755` (executable) in git
  as of 2026-08-23 — `rank_strategies.sh` and several others were `100644`
  before that, meaning every fresh clone/pull needed a manual `chmod +x`
  before it could run at all (`sudo ./script.sh` fails with a misleading
  "команда не найдена", not "Permission denied"). `z2r_autobench_lib.sh`
  is the one deliberate exception — it's sourced, never executed directly,
  so it stays `100644`. When adding a new top-level script meant to be run
  directly, `chmod +x` it before `git add`, or the mode won't stick.

## Feature branch merged into main (2026-08-26) — three weeks of fixes never reached any server

- Live incident: this whole engagement's work (Aug 3 onward, 95 commits)
  sat on an open PR (`claude/z2r-autobench-open-issues-hq8gjy` → `main`,
  #2) that never got merged. `autoupdate.sh` deliberately tracks `main`
  only, never the checked-out branch (see its own comment: "продакшена
  должно идти от того, что реально смержено в main, не от feature-
  ветку") — so **every server running autoupdate.sh silently never
  received any of this session's fixes**, the whole time, including the
  very `_z2r_detect_base()` fix that this file's own "/opt/zapret2 vs
  /opt/zator" section documents as already resolved. Surfaced two ways
  in the same sitting: (1) a `z0r-panel` checkout on Server A turned out
  to be on its own unmerged feature branch (`claude/realtime-db-api`,
  no open PR, just never fast-forwarded to `main`) — `git pull` silently
  reported "already up to date" because it was up to date with its own
  stale branch, not with reality; (2) once that got sorted and
  `z0r-panel` switched to `main`, the `/controls` page's profile-status
  table showed "ошибка чтения" for all 9 profiles — `set_strategy_cli.sh`
  on Server A was still hitting the exact `/opt/zapret2/z2r_lib/config.sh
  не найден` error that `_z2r_detect_base()` was supposed to have fixed
  weeks earlier, because that fix was sitting in the unmerged PR the
  whole time.
- Fixed by merging the PR into `main` directly (`git merge`, not the
  GitHub UI — same effect, PR auto-closed as merged once its head commit
  became reachable from `main`). Verified before merging that it was a
  clean fast-forward relationship with zero divergent functional work —
  `main` only had 2 small independent commits the branch lacked (both
  tiny README/z0r wording tweaks from Aug 4), resolved as trivial
  conflicts. Confirmed live afterward: `set_strategy_cli.sh get 1 tls`
  on Server A returned a real strategy number instead of the config.sh
  error.
- **Same root-cause class as the Server B chain elsewhere in this file**:
  a stale assumption (checked-out branch == what's actually deployed)
  baked into tooling (`autoupdate.sh` correctly assumes `main` is where
  merged work lives, but nothing enforced that open PRs against `main`
  ever actually get merged) let three weeks of real fixes sit invisible
  and undeployed. Lesson: when a "should already be fixed" bug reappears
  on a live server, check which branch the checkout is actually on and
  whether the fix in question ever reached `main` specifically — don't
  assume "the fix exists in git" means "the fix is deployed".
- `z0r-panel`'s `claude/realtime-db-api` had no open PR at all — its
  work had been pushed straight to `main` at some point, so merging
  wasn't needed there, just switching Server A's checkout off the stale
  branch (`git checkout main && git pull origin main`).
- Both now-fully-merged branches (`z2r_autobench`'s
  `claude/z2r-autobench-open-issues-hq8gjy`, `z0r-panel`'s
  `claude/realtime-db-api`) were left in place on GitHub rather than
  deleted — `git push origin --delete` 403'd (same class of restriction
  as the historical `git push` 403 noted above, apparently scoped to ref
  deletion specifically), and no GitHub API tool available in-session
  covers branch deletion either. Harmless to leave — fully merged,
  nothing references them, safe for a human to delete manually via the
  GitHub web UI whenever convenient.

## zapret1 vs zapret2 — do not mix syntax

- This project targets **zapret2** (`nfqws2`, `--lua-desync=`,
  `--filter-tcp=`/`--filter-l7=`/`--payload=` gates). **zapret1**
  (`nfqws`, `--dpi-desync=`) is a different, incompatible engine/CLI —
  `nfqws2` rejects `--dpi-desync=` outright ("unrecognized option").
- `--new` separates independent rule blocks. Forgetting it before a new
  block merges the new flags into the *preceding* block — invalid
  duplicate/conflicting flags, `nfqws2` refuses to start. Always
  `grep -n -B1 -A6` the edited region and review before restarting a live
  `zapret2`.

## Strategy numbering

- `config_profile_max_strategy()` (from z2r's own `lib/config.sh`) returns
  the **max** `strategy=N` found in a profile's block, not a count. All
  tooling here (`rank_strategies.sh`, `autotune_daemon.sh`, etc.) loops
  `1..max_strat` contiguously. Never introduce a numbering gap (e.g.
  jumping straight to 100+ for newly generated strategies) — every tool
  silently wastes cycles on the nonexistent numbers and can pollute
  results. Keep new strategy numbers contiguous after the current max;
  tag provenance with a comment above the block instead of a numeric range.
- `tls_client_hello_clone:blob=*` strategies (31-36,38,39,41,42 in the
  current config) need a blob captured from a real live handshake to that
  exact domain through `nfqws2` — if never captured, they silently no-op
  (packet passed unmodified) and can falsely rank as "working" if the ISP
  isn't blocking that URL at that moment. Excluded from
  `rank_strategies.sh` by default; `--include-clone-strategies` to
  override. Caused a real production outage once.

## Ban / rate-limit avoidance (actively designed around, not solved)

- Heavy DPI middleboxes can escalate/tighten inspection against an IP that
  sends a lot of failed-handshake noise in a short window — a stronger and
  more dangerous failure mode than a single test domain's own WAF banning,
  since it can degrade real production traffic, not just the test.
  `--funnel` mode partially mitigates this by narrowing candidates fast
  instead of exhaustively hammering every strategy every pass.
- Any future generator/brute-forcer needs adaptive backoff plus a circuit
  breaker (correlated failure across many *different* strategies on one
  target = suspected escalation, not "no working strategy") from day one,
  not bolted on later.

## autotune_daemon.sh — per-profile processes (since 2026-08-18)

- Live incident that forced this: a `systemctl restart autotune-daemon`
  landed mid-sweep of a GV_TLS (profile 2) retune, killing it before its
  cleanup ran and leaving `locked.tsv` stuck on a random mid-perebor
  candidate for hours — but the deeper problem was architectural: ALL
  profiles shared one sequential loop, so one profile's expensive retune
  blocked health-check *cadence* for every other profile in the same cycle.
- Fix: `autotune_daemon.sh --profile N` (N=1..6) runs as an independent
  process via systemd template unit `autotune-profile@N.service` — own
  health-check timer, own log (`autotune_state/daemon_profile_N.log`), own
  status file (`autotune_state/status_profile_N.txt`). The legacy no-arg
  mode (`autotune-daemon.service`) still exists but is now scoped to ONLY
  8/9 (FB_TLS/FB_HTTP, permanently in `SKIP_PROFILES` there) — those two
  are near-permanently skipped anyway (wrong test channel, see below), not
  worth a dedicated process each.
- Retunes (the actual strategy sweep) are still serialized across ALL
  profiles via the shared `TUNE_LOCK_FILE` — `locked.tsv` is one TSV file
  for every profile, so concurrent writes from independent processes risk
  a file-level race even when touching different rows/profiles. Only the
  health-check *cadence* is parallel; only one retune runs system-wide at
  a time, same safety guarantee as before.
- GV_TLS (profile 2) depends on YT_TLS (profile 1): `get_gv_test_url()`/
  `resolve_googlevideo_url()` resolve the real videoplayback URL via
  `yt-dlp` against youtube.com. If YT_TLS is currently down, GV_TLS's own
  test is doomed regardless of its own strategy — `--profile 2`'s process
  reads `failcount_profile_1` directly (plain file read, no coordination
  needed) before its own cycle and skips with a clear log line if YT_TLS
  has unresolved failures, instead of wasting an expensive retune and
  misattributing the failure to GV_TLS's strategy.
- VOICE_UDP (profile 6) has no `curl`-based health-check — real signal is
  "does joining a Discord voice channel work." `z2r_test-voice-bot`
  (separate repo) already exposes `POST 127.0.0.1:8765/probe` for Zenith's
  own genome testing; extended it to also accept `{"strategy_n": N}`
  (reuses the bot's own `extract_strategy_lines()` against the live
  `/opt/zapret2/config`) so `check_profile_voice()`/`rank_voice.sh` can
  drive it without touching Discord at all. Same sandbox-only guarantee as
  the bot's existing Discord commands (`/voice_test` etc., see that repo's
  README "Песочница, не прод") — never touches the live `/opt/zapret2`
  directly; only the winning strategy gets applied to the real profile 6
  via the same `set_strategy()` path every other profile uses.
- `probe_url()` in `z2r_autobench_lib.sh` now requires BOTH TLS 1.2 and
  1.3 to succeed by default (`PROBE_REQUIRE_BOTH_TLS=1`) — was OR-logic
  before. Live incident: DS_TLS strategy=29 answered on TLS1.3 but timed
  out on TLS1.2 for hours while health-check stayed green (OR-logic), and
  the real (TLS1.2-dependent) Discord client stayed broken the whole time.
  Override to `0` per-run only if a profile's real server genuinely
  doesn't serve TLS1.2 at all (not a block, a protocol version the origin
  doesn't offer) — AND would otherwise falsely fail that profile forever.
- `rank_strategies.sh`/`rank_quic.sh` now `trap` TERM/INT/EXIT to always
  revert `locked.tsv` to the entry strategy, whether the run finishes
  normally or gets killed from outside (e.g. a daemon restart mid-sweep,
  the exact incident above) — `rank_voice.sh` doesn't need this (never
  touches `locked.tsv`, sandbox-only).

## All six `autotune-profile@N.service` silently dead for 5 days (found 2026-08-31)

- Live incident on Server A: while chasing a recurring "YouTube 'no
  network' on WebOS" report (worked on strategy 63 a few days earlier,
  broke again after some time; same pattern repeated on strategy 61),
  `systemctl list-units 'autotune*'` showed `autotune-profile@1` through
  `@6` ALL in `failed` state — only the legacy no-arg `autotune-daemon`
  (scoped to 8/9, FB_TLS/FB_HTTP, see "per-profile processes" above) was
  actually running. `journalctl -u autotune-profile@1` showed the cause:
  right after a reboot on 2026-08-26 20:55, it crashed instantly with
  `Не найден /opt/zapret2/z2r_lib/config.sh — прерываю` (the exact
  `_z2r_detect_base()` split-base error documented elsewhere in this
  file), hit systemd's default restart-rate-limit within seconds
  ("Start request repeated too quickly"), landed in permanent `failed`,
  and NEVER recovered or alerted anyone for the next 5 days.
- Root cause of the crash itself lines up with the "Feature branch merged
  into main" incident elsewhere in this file, same date (2026-08-26): the
  reboot most likely landed in the narrow window before that day's PR
  merge actually reached this box's checkout, so the daemon started once
  against pre-fix code, crash-looped, and by the time `main` genuinely had
  the fix, the unit was already stuck in `failed` — a `git pull` alone
  never restarts a crashed systemd unit.
- **Impact, the real point of this entry**: for those 5 days, the
  health-check-every-300s → retune-after-3-fails self-healing loop
  (see "per-profile processes" above) did not exist AT ALL for YT_TLS,
  GV_TLS, RKN_TLS, DS_TLS, or profile 6 — only `zenith-promoter` (Zenith,
  separate repo) was still touching those profiles' strategies, and it
  has no equivalent behavior: it doesn't reactively detect "the currently
  live strategy just stopped working," it only tries to push its own next
  best-scoring genome forward on a fixed schedule and rolls back if THAT
  specific attempt fails its live check. With the daemon dead, a strategy
  that degraded over time (ISP-side DPI updates, see "Ban / rate-limit
  avoidance" above) had nothing to catch it — it just stayed broken until
  a human noticed and intervened, then degraded again later with the same
  silence. This is almost certainly the real explanation for the
  "worked, then broke again after time, repeatedly, on different
  strategies (63, then 61)" pattern that prompted this investigation —
  not a bad strategy choice each time, but a dead safety net.
- Fixed by a plain `systemctl restart autotune-profile@1 ... @6` — all six
  came back `active running` immediately (no re-crash), confirming
  `/opt/z2r_autobench`'s checkout genuinely has the `_z2r_detect_base()`
  fix now, the crash was purely a stale-boot-timing artifact, not a
  still-open bug.
- **Open gap, not yet addressed**: nothing monitors these systemd units
  themselves — a unit silently sitting in `failed` for 5 days produced no
  alert, no log anyone was watching, nothing on any panel page. The
  existing `maybe_restart_zapret2()` self-healing in `autotune_daemon.sh`
  only watches `zapret2.service`, not its own sibling systemd units, and
  there is no "watchdog for the watchdogs" anywhere in this stack. Worth
  a `_daemon_do_check_updates`-style menu addition or a simple
  `systemctl is-failed autotune-profile@*` check surfaced somewhere
  (z0r menu item 14 status line, or a panel card) next time this area is
  touched — flagging here rather than building it ad hoc mid-incident.

## `/opt/zapret2` vs `/opt/zator` — two real directories, not a symlink pair (since 2026-08-23)

- Live incident on Server A: after a core-file recovery, `/opt/zapret2` and
  `/opt/zator` ended up as two independent real directories instead of the
  (apparent, pre-incident) symlink relationship. The live `config`'s
  `--lua-init=`/`--hostlist=`/`--blob=` arguments explicitly hardcode
  `/opt/zator/...` paths (that's baked into the config text itself, not a
  bug), while every z2r_autobench tool (`LIB_DIR`/`ORCH_DIR` in
  `z2r_autobench_lib.sh`) defaults to `/opt/zapret2/...`. Net effect: the
  daemon spent ~14 hours writing strategy changes to
  `/opt/zapret2/extra_strats/cache/orchestra/locked.tsv`, a file the live
  `nfqws2` process (loading `locked.lua` from `/opt/zator/lua/`, whose own
  `LOCKED_PATH` constant pointed at the zator-side file) never read —
  every retune that day was writing into a void, and a full 62-strategy
  `rank_strategies.sh` sweep failed 100% simply because none of its
  candidate switches ever reached production traffic.
- **The fix is narrow: only `extra_strats` needs to be a symlink**
  (`/opt/zapret2/extra_strats -> /opt/zator/extra_strats`) — that's where
  `locked.tsv`/`locked.manual.tsv`/hostlists actually live, and it's the
  only thing that needs to be shared between what the daemon writes and
  what the live `locked.lua` reads.
  **Do NOT also symlink `/opt/zapret2/lua`** — this was tried and caused a
  second, worse outage: the config's *base* `--lua-init=` args
  (`zapret-lib.lua`, `zapret-antidpi.lua`, `zapret-auto.lua`, the actual
  upstream zapret2 core) always load from the real `/opt/zapret2/lua/`,
  which has always had them; `/opt/zator/lua/` only ever contained
  `locked.lua`/`rst-guard.lua`/detector scripts, never the core library.
  Symlinking the whole `lua` directory hides those core files, and
  `nfqws2` refuses to start ("LUA file '.../zapret-lib.lua' ... not
  accessible") on its *next* restart — which can be hours later, triggered
  by something unrelated (e.g. a promoted-strategy apply/rollback via
  z0r-panel/Zenith calling `systemctl restart zapret2.service`), silently
  turning a config-path mistake into a multi-hour full outage with no
  DPI-bypass at all. Same reasoning applies to `/opt/zapret2/files` — the
  config's `--blob=` args already explicitly say `/opt/zator/files/...`,
  nothing references `/opt/zapret2/files/...` directly, so there's no need
  to touch it either.
- Before touching either directory again: `grep -n '/opt/za' /opt/zapret2/config`
  to see exactly which paths the *live* config actually references, and
  only symlink what's genuinely referenced from both sides (daemon writes
  vs. what `--lua-init=`/`--hostlist=`/`--blob=` load) — not the whole
  parent directory.
- **Correction, 2026-08-23 later same day: this is not specific to the
  Server A incident — it's the upstream z2r installer's standard layout.**
  A second server (fresh Provider B deploy, installed minutes earlier, never
  touched by any recovery) showed the identical split: `z2r_lib` exists
  only under `/opt/zator/z2r_lib`, `/opt/zapret2/z2r_lib` doesn't exist
  at all. `rank_strategies.sh` failed immediately with `Не найден
  /opt/zapret2/z2r_lib/config.sh — прерываю` — every fresh z2r install
  hits this same wall, not just recovered/incident boxes. Fixed at the
  code level instead of requiring a manual symlink on every install:
  `z2r_autobench_lib.sh` now auto-detects the base
  (`_z2r_detect_base()` — uses `/opt/zapret2` if `z2r_lib` exists there,
  else falls back to `/opt/zator`, else defaults to `/opt/zapret2` so the
  original clear "не найден" error still fires rather than a silent
  wrong path) instead of hardcoding `LIB_DIR=/opt/zapret2/z2r_lib`. This
  doesn't touch `blob_tune.sh`'s own separate hardcoded
  `FAKE_DIR=/opt/zapret2/files/fake` — same class of bug (fixed
  2026-08-24, see below).
- `z0r` (the top-level menu script) does **not** source
  `z2r_autobench_lib.sh` — it's a standalone script with its own
  `LOCKED_TSV`/`LOCKED_MANUAL_TSV`, previously hardcoded to
  `/opt/zapret2/extra_strats/...` independently of the fix above, so it
  never picked it up. Live symptom on Server B (Provider B): every profile showed
  `[#0]`/auto in the menu (item 111, manual strategy switch) even though
  `set_strategy_cli.sh` (which *does* source the lib) had genuinely locked
  real strategies — the display was silently reading a file that doesn't
  exist on this layout. Fixed 2026-08-23 by replicating the same tiny
  base-detection snippet inline in `z0r` rather than sourcing the whole
  lib (risk of name collisions with `z0r`'s own functions). Two more
  known instances of this exact class, found and **fixed 2026-08-24**:
  `test_custom_domain.sh` read `TCP_YT_list.txt`/`TCP_Discord.txt`/
  `TCP_RKN_list.txt`/`TCP_Custom.txt` from a hardcoded
  `/opt/zapret2/extra_strats/` (silently misclassified domains on a split
  install, no error) — now uses `$Z2R_BASE` from the already-sourced lib,
  same as everything else. `blob_tune.sh` had a second hardcoded path
  beyond `FAKE_DIR` (see above):
  `CFG_BACKUP_DIR=/opt/zapret2/extra_strats/cache/orchestra/config_backups`
  — now `$ORCH_DIR/config_backups`. `blob_tune.sh`'s `FAKE_DIR` and the
  `--blob=maxru:@.../fake/` prefix (used in three places: parsing the
  current blob, writing a new one, printing the final result) are no
  longer hardcoded to either base guess at all — parsed directly out of
  the live config's own `--blob=maxru:@` argument instead (the config
  itself is the ground truth for this one; CLAUDE.md already noted it
  explicitly points at `/opt/zator/files/...` on split installs, so
  reading it beats guessing). Falls back to `$Z2R_BASE/files/fake` with a
  loud warning only if the config isn't in `maxru` mode yet (e.g. before
  the first blob switch ever runs). Before trusting ANY tool's read of
  `locked.tsv`/hostlists/backups on a new box, grep it for a bare
  `/opt/zapret2/` path first — sourcing the lib isn't universal, some
  tools may still hardcode a path outside what's covered here.
- `zapret2.service` has **no self-healing** if it dies for an unrelated
  reason (crash, a bad config push, another tool restarting it into a
  broken state) — `autotune_daemon.sh` only detected "not running" and
  skipped its cycle forever, silently, with no restart attempt and no loud
  signal. Since 2026-08-23, both the legacy loop and the `--profile N`
  loop call `maybe_restart_zapret2()` (in `autotune_daemon.sh`) on every
  cycle where `zapret2_running` is false — tries `systemctl restart
  zapret2.service` at most once per `ZAPRET2_WATCHDOG_COOLDOWN` (default
  600s, shared across all per-profile processes via one state file, to
  avoid a restart storm if several profile daemons notice the same outage
  in the same cycle), and logs loudly either way (fixed vs. still broken
  — the latter points at `journalctl -u zapret2.service`, since a repeat
  failure after restart is a config/lua problem, not something more
  retries will fix).

## Test domains

- `MIN_BYTES_THRESHOLD=65536` (`probe_url`/`probe_http_url` in
  `z2r_autobench_lib.sh`) — a candidate test URL/path must actually serve
  ≥64KB or every probe reports false failure regardless of real DPI
  bypass. Check actual response size before adopting a new test domain.
- Domains rot over time and dense probing risks the *site's own* WAF, not
  just DPI/ISP blocking. Prefer CDN/static-asset endpoints over ordinary
  human-facing sites when picking new test targets.
- A profile's single `test_url` can be unrepresentative of what a real
  client actually needs — live case 2026-08-23: profile 1 (YT_TLS) only
  ever tested `https://www.youtube.com/` (the static HTML shell), and
  `rank_strategies.sh` picked a strategy that passed that check cleanly
  while `youtubei.googleapis.com` (the InnerTube API every real
  YouTube client — including mobile and TV — actually uses for
  feed/search/interface data) timed out completely under the same
  strategy. The site "worked" by every test the tooling ran; the app
  didn't load for any real user. Fixed via `PROFILE_EXTRA_URL`/
  `extra_check_ok()` in `z2r_autobench_lib.sh` — a lightweight
  reachability-only check (`probe_reachable()`, no byte threshold, just
  "not HTTP 000") layered on top of a profile's normal probe; a candidate
  only counts as working if *both* pass. Wired into `check_profile_tls()`
  (health-check), `rank_strategies.sh` (both funnel and full-sweep probe
  sites), and the shared `tune_profile()`/`tune_profile_exhaustive()` in
  the lib. Currently only profile 1 has an entry
  (`youtubei.googleapis.com`) — add more profiles here if the same
  "passes the site check, fails the client" pattern shows up elsewhere,
  rather than chasing it ad hoc per incident.
- `resolve_googlevideo_url()` (profile 2/GV_TLS, also used by profile
  5/QUIC and `shorts_probe.sh`) depends on `yt-dlp`'s own choice of
  YouTube "player client" to extract a `videoplayback` URL — this can
  itself be a false-failure source, separate from DPI/desync entirely.
  Live incident 2026-08-23: without an explicit `--extractor-args`,
  `yt-dlp` picked `ANDROID_VR`, and `googlevideo.com` returned an instant
  `403` for that client from this server's (datacenter, not residential)
  IP — reproduced even via `yt-dlp`'s own full downloader (correct
  headers for that client included), so it wasn't a missing-header
  problem in the separate `curl` probe step either. This produced 100%
  failure across every strategy in every profile-2 sweep for hours,
  looking exactly like "no working strategy" when the actual cause was
  test methodology. `web`/`mweb` clients don't work here either, but for
  an unrelated reason (no JS runtime on the server to solve YouTube's
  sig/n challenge — see the `EJS`/`PO-Token` warnings if you try them).
  `android` client works cleanly (verified: real file, full speed). Fixed
  via `YT_PLAYER_CLIENT` (default `android`) in `z2r_autobench_lib.sh`,
  passed as `--extractor-args "youtube:player_client=$YT_PLAYER_CLIENT"`.
  If `android` ever also starts getting blocked, override the env var
  rather than hardcoding a new client inline — and re-check with the
  same `yt-dlp -f 'best[height<=480]' -o test.mp4 --extractor-args
  "youtube:player_client=X" <url>` loop across clients before assuming
  it's DPI again.
- **`shorts_probe.sh` specifically cannot work right now, for anyone, on
  any server** — not a z2r_autobench bug, not DPI, not this box. Verified
  2026-08-23: regular long-form video extracts fine via the `android`
  fix above, but YouTube Shorts fail on *every* client tested (`android`,
  `android_vr`, `ios`, `web`, `web_embedded`, `mweb`) — `-v` output shows
  `youtube is forcing SABR streaming for this client` for Shorts
  specifically. SABR is a segmented streaming protocol, not a flat URL —
  `yt-dlp` doesn't support downloading it yet (tracked upstream:
  `yt-dlp/yt-dlp#12482`). Installing a JS runtime (`deno`, confirmed
  installed and working here) fixes the *unrelated* sig/n-challenge
  failure that `web`/`mweb` show for ordinary videos, but does not touch
  SABR-forcing at all — don't re-chase this by trying yet another
  `--extractor-args` client combination; it's a `yt-dlp` capability gap,
  wait for upstream SABR support. Re-test by rerunning `shorts_probe.sh`
  after a `yt-dlp` upgrade, not by touching strategies or z2r_autobench
  code.
- `quic_probe.py` originally printed only received-byte-count. Live
  incident 2026-08-23: with a fixed `--range-bytes`, a *successful*
  fetch always returns the exact same byte count regardless of
  strategy — so `rank_quic.sh`'s "Ср.байт" column couldn't distinguish
  a fast strategy from a slow one, only pass/fail. A profile-5 sweep of
  all 13 strategies came back 100%-success on every single one with
  identical byte counts, looking like "any strategy is equally fine"
  when actually nothing about speed had been measured at all. Fixed:
  `quic_probe.py` now times the fetch and prints `bytes\tms` on one
  stdout line instead of just `bytes`. **This changed the stdout
  contract for every caller** — `rank_quic.sh` (both probe loops +
  both aggregation `awk` blocks, now sorts by avg ms ascending instead
  of avg bytes descending within the same reliability tier),
  `quic_tune.sh` (probe loop + `LOG_FILE` header gained an `ms`
  column), and `check_profile_quic()` in `autotune_daemon.sh` (splits
  on the first `\t` to keep just the byte count for its threshold
  check) were all updated together — if you ever touch `quic_probe.py`'s
  output format again, grep for every caller first
  (`grep -rn quic_probe.py *.sh`), a stale caller silently breaks (bash
  arithmetic comparison on a two-field string doesn't error loudly, it
  just evaluates false and looks like every strategy failing).

## Zenith-TG (scp-oss/Zenith-TG)

- Separate repo: transparent Telegram access, not a zapret2 desync
  profile — tried that first (`zapret2/TG_MTPROTO.block.conf` still in
  that repo for reference), confirmed live on Server A that it does
  *not* help here: the block there is a curated IP blacklist of
  specific well-known Telegram DC addresses (SYN itself never
  completes), not a DPI signature `--lua-desync=` could fool. A
  different, less-public IP in the same `/20` (`149.154.167.220` —
  `Flowseal/tg-ws-proxy`'s own default `dc_redirects` target) answers
  cleanly instead.
- What actually works: `relay/transparent_relay.py` vendors
  `tg-ws-proxy`'s relay machinery (`relay/vendor/`, MIT, unmodified —
  WS pool to `.220`, Cloudflare-domain/worker fallback) but replaces
  its client-facing connector. MTProxy's secret is baked into the key
  derivation itself (`SHA256(prekey+secret)`), so a real MTProxy can
  never accept unconfigured clients — this connector instead decodes
  the incoming init using the same raw-key, no-secret semantics a
  genuine direct-connect Telegram client already uses. Combined with
  `iptables REDIRECT` on the Telegram CIDR list
  (`relay/setup_redirect.sh`), the whole thing is transparent: no
  MTProxy config in the client app, works for anything routing through
  the box (including VLESS-tunneled clients — Xray's outbound is an
  ordinary local `connect()`, so it hits the same `OUTPUT` chain).
  Confirmed working end-to-end on Server A with an unmodified Telegram
  client over the existing VLESS tunnel.
- Installed via z0r menu item 21 (manage)/31 (uninstall) (renumbered
  2026-08-28 when autotune-daemon moved to the main menu, was 20/30 — see
  "autotune-daemon moved to main menu" below; before that, 2026-08-24, see
  "z0r main menu renumbering"), same on-demand-clone pattern as Zenith's
  20/30 — but note its shipped
  `relay/tg-transparent-relay.service` hardcodes `/opt/Zenith-TG`
  (how it was first deployed by hand); `manage_tg_relay()` in `z0r`
  `sed`-rewrites that path to the real `$TGRELAY_DIR` before installing
  the unit, don't `cp` it as-is like `manage_panel` does.
- **First Provider B deploy (2026-08-24) hit two real bugs in that install path,
  both now fixed and confirmed working end-to-end on `Server B`:**
  1. `.service` has `User=tgrelay`/`Group=tgrelay`; the system user wasn't
     getting created reliably (or didn't survive an uninstall/reinstall
     cycle via the menu — root cause not fully pinned down, `useradd` run
     by hand worked fine every time), so `systemctl` failed with
     `status=217/USER` ("Failed to determine user credentials: No such
     process") and crash-looped on `Restart=on-failure` — 8000+ restarts
     before it was caught, `get_tg_relay_status()` just reports this as
     plain `OFF`, no hint that the real problem was a missing user, not
     "not started yet". Fixed: `ensure_tgrelay_user()` now runs
     unconditionally on every visit to `manage_tg_relay()` while
     Zenith-TG is installed (same self-healing pattern as
     `ensure_panel_runtime_grants`/`dnscrypt_wire_resolver`), not only
     during the original clone.
  2. Once the user existed, the service *still* failed to start, now with
     `status=226/NAMESPACE`. The `sed` rewrite above only covered
     `/opt/Zenith-TG/relay` and `/opt/Zenith-TG/.venv` — it missed a bare
     `ReadWritePaths=/opt/Zenith-TG` (no `/relay`/`/.venv` suffix) further
     down the same file. Combined with `ProtectSystem=strict`, systemd
     tried to bind-mount that literal (nonexistent on this layout) path
     read-write and failed to set up the mount namespace before Python
     ever started. Fixed: one general `s#/opt/Zenith-TG#$TGRELAY_DIR#g`
     substitution instead of two narrow ones, robust against any other
     directive in the unit that references the same base path.
  Both fixes are **unconditional on every menu visit**, not just at first
  install (`cmp`-compare the regenerated unit against the one on disk,
  same idiom as `install_zenith_service()`) — the already-broken unit
  file sitting on disk from the original install would never have picked
  up either fix otherwise, no matter how many times `git pull` ran.
  Also: install (clone+deps) and enable (systemd unit + iptables
  REDIRECT) used to require visiting menu item 20 twice in a row for a
  fresh install — merged into one visit (`tgrelay_enable()` called
  directly after a successful install), the `[y/N]` before applying
  REDIRECT stays since it's a live network change.
- **New open issue, found 2026-08-24 after the fixes above — service runs
  and REDIRECT is applied, but the connector itself is OS-dependent and
  not yet root-caused:** through the relay (over the existing VLESS
  tunnel, Server B/Provider B), Telegram connects fine on macOS and iOS but **fails
  on Android and Windows**. Meanwhile, connecting the same Telegram app
  directly via a real MTProxy (no relay, no VLESS) works on **every** OS
  tested — narrowing this specifically to `transparent_relay.py`'s own
  no-secret connector logic (see "What actually works" above — it decodes
  the client's initial packet using raw-key, no-secret semantics instead
  of real MTProxy's secret-derived key), not to network-level blocking or
  the REDIRECT/iptables setup, which is common to all OSes and evidently
  fine. Most likely explanation not yet confirmed: Android/Windows
  Telegram clients construct or obfuscate/pad their initial connection
  packet differently from the macOS/iOS clients, and the connector's
  packet parsing doesn't handle that variant — but this needs actual
  packet captures/comparison across clients to confirm, not guessed at
  further here. Next step when picked back up: capture the raw initial
  bytes each client sends (e.g. via the relay's own logging or a local
  packet dump) for a working (iOS) vs failing (Android) client hitting
  the same connector, diff them.

## autotune-daemon moved to main menu (2026-08-28)

- `manage_daemon()` (autotune-daemon control) had been living as item 5
  inside the Zenith submenu since 2026-08-23 (see "autotune-daemon vs
  Zenith" above) purely for UX convenience — but this was architecturally
  wrong: autotune-daemon works directly on z2r strategies
  (`rank_strategies.sh`/`rank_quic.sh` + `set_strategy_cli.sh`) and has no
  dependency on Zenith or its genome DB at all. Moved to the top-level
  main menu as its own item, next to the other strategy-selection tools
  (`Тест домена`/`Ручное переключение стратегии`/`Тест YouTube Shorts`),
  since that's the section it actually belongs to functionally.
- Removed item 5 from `zenith_menu()`'s own submenu entirely (was purely a
  navigational shortcut into the same `manage_daemon()` function — no
  behavior lost, just one fewer way to reach the same place).
- Inserted as new top-level item 14 (right after item 13, "Тест YouTube
  Shorts"), which pushed every subsequent top-level item up by exactly
  one. Old → new mapping (every in-script "пункт N" reference and
  comment in `z0r` was re-swept and updated in the same pass — grep
  `пункт [0-9]` in `z0r` before assuming a number if this note goes
  stale; the same sweep also caught and fixed now-stale "z0r пункт N"
  cross-references in `z0r-panel` (`.env.example`, `autoupdate_ctl.py`,
  `main.py`, `README.md`, `templates/nodes.html`,
  `templates/controls.html`) and in `zenith/README.md` — some of which
  were already stale from the *previous* (2026-08-24) renumbering and had
  never been caught until this pass, a reminder that a menu renumbering
  in `z0r` is not "done" until sibling repos referencing z0r item numbers
  by hand are swept too, not just `z0r` itself):
  ```
  (new) 14  autotune-daemon             (inserted here)
  14 -> 15  Запустить меню z2r
  15 -> 16  Проверка DNSCrypt на дырявость
  16 -> 17  Zapret сервис
  17 -> 18  zenith-promoter (быстрый доступ)
  18 -> 19  DNSCrypt-proxy
  19 -> 20  Zenith
  20 -> 21  Zenith-TG
  21 -> 22  Discord_bot
  22 -> 23  web_panel
  23 -> 24  Автообновление
  24 -> 25  Удалить z2r
  25 -> 26  Удалить autotune-daemon
  26 -> 27  Удалить Discord_bot
  27 -> 28  Удалить web_panel
  28 -> 29  Удалить z2r_autobench
  29 -> 30  Удалить Zenith
  30 -> 31  Удалить Zenith-TG
  31 -> 32  Удалить DNSCrypt-proxy
  ```
  Items `1-13` (profile IDs, число проходов, ручное переключение, тест
  YouTube Shorts) and `111`/`999`/`0` are unchanged, same rule as the
  2026-08-24 renumbering. Nested submenu numbering (Zenith's own `1-4`,
  its autonomy submenu's own `1-6`) is untouched — separate namespace,
  see the note above.

## blob_tune.sh wired into main menu (2026-08-31)

- Live finding: `blob_tune.sh` (TLS ClientHello blob perebor, see its own
  section elsewhere in this file) was never actually wired into anything
  — no menu item, no `autotune_daemon.sh` call, no systemd unit. It only
  existed as a standalone script, mentioned in README.md/CLAUDE.md as
  documentation. "Built and forgotten" — confirmed by grepping the whole
  repo for `blob_tune` outside its own file and finding nothing but docs.
  Added a menu entry (`run_blob_tune()`, prompts for
  candidates/profiles/budget with Enter-for-defaults, warns up front
  about the restart-per-candidate cost) so it's actually reachable.
- Inserted as new top-level item 19, right after 18 (`zenith-promoter`,
  end of the "Управление" block) per direct request — pushed every
  item ≥19 up by exactly one, same mechanical process as the
  2026-08-28 renumbering above (grep `пункт [0-9]` in `z0r` before
  assuming a number if this note goes stale; the same sweep this time
  also caught and fixed cross-references in `z0r-panel`
  (`README.md`, `.env.example`, `main.py`, `autoupdate_ctl.py`,
  `templates/nodes.html`, `templates/automation.html`), in
  `zenith/README.md`, and one already-stale reference in
  `zenith/zenith_autorun.sh` — that one said "z0r 22 -> 4" when the
  correct pre-this-change value was 20, never caught by the 2026-08-28
  sweep. Same lesson repeated a third time: a menu renumbering in `z0r`
  is not "done" until every sibling repo referencing z0r item numbers by
  hand is swept too, and a stale reference can silently survive more
  than one prior renumbering pass before anyone greps for it):
  ```
  (new) 19  blob_tune.sh                (inserted here)
  19 -> 20  DNSCrypt-proxy
  20 -> 21  Zenith
  21 -> 22  Zenith-TG
  22 -> 23  Discord_bot
  23 -> 24  web_panel
  24 -> 25  Автообновление
  25 -> 26  Удалить z2r
  26 -> 27  Удалить autotune-daemon
  27 -> 28  Удалить Discord_bot
  28 -> 29  Удалить web_panel
  29 -> 30  Удалить z2r_autobench
  30 -> 31  Удалить Zenith
  31 -> 32  Удалить Zenith-TG
  32 -> 33  Удалить DNSCrypt-proxy
  ```
  Items `1-18` and `111`/`999`/`0` unchanged, same rule as every prior
  renumbering. Nested submenu numbering untouched.

## z0r main menu renumbering (2026-08-24)

- Items `1-9` (profile IDs) and `111`/`999`/`0` are **never** renumbered —
  `1-9` are real profile numbers used throughout the whole system
  (`circular_locked:key=N` in the live config, `PROFILE_NUMBERS` in
  Zenith, `set_strategy_cli.sh` args), not just menu positions. Everything
  else was pure menu navigation, numbered historically in the order
  features got added (not grouped by section) — user asked for a clean
  sequential renumbering, grouped by section, after `28`/`30`/`31`
  landed on top of an already-messy sequence. Old → new mapping (every
  in-script "пункт N" reference, comment, and this file's own item
  references were updated in the same pass — grep `пункт [0-9]` in `z0r`
  before assuming a number if this note goes stale):
  ```
  13 (число проходов)        -> 11
  21 (ручное переключение)   -> 12
  27 (тест YouTube Shorts)   -> 13
  11 (запустить меню z2r)    -> 14
  30 (проверка DNSCrypt)     -> 15
  12 (Zapret сервис)         -> 16
  31 (zenith-promoter)       -> 17
  28 (DNSCrypt-proxy)        -> 18
  22 (Zenith)                -> 19
  24 (Zenith-TG)             -> 20
  14 (Discord_bot)           -> 21
  15 (web_panel)             -> 22
  26 (Автообновление)        -> 23
  16-20, 23, 25, 29          -> 24-31 (Удаление, same relative order)
  ```
  New section `=== Модули ===` (18-23: DNSCrypt-proxy/Zenith/Zenith-TG/
  Discord_bot/web_panel/Автообновление) split out of the old flat
  `=== Управление ===`, which now holds only the three items used most
  often for a quick check/toggle (DNSCrypt leak check, Zapret service
  restart, zenith-promoter quick toggle) — user's own ordering choice,
  not mine.
- Nested submenu numbering (Zenith's own `1-4` inside its top-level item,
  autonomy menu's own `1-6` inside that submenu's item 4) is a **separate
  namespace**, untouched by this or any later top-level renumbering — a
  comment saying "пункт 3" inside `zenith_menu`/`zenith_autonomy_menu`
  code means that submenu's own item 3, not a top-level item. (Zenith's
  own submenu item numbers, `1-4`, have stayed stable since this note was
  written even though the top-level item pointing at it moved from 19 to
  20 on 2026-08-28 — see "autotune-daemon moved to main menu" below.)

## autotune-daemon vs Zenith — two independent auto-tuners, not layers (since 2026-08-23)

- `autotune-daemon` (this repo, `autotune_daemon.sh`) and Zenith
  (`zenith-autorun`/`zenith-promoter`, separate repo, see below) are **two
  fully independent systems**, not parts of one another. From
  2026-08-23 to 2026-08-28 `manage_daemon()`'s control entry lived
  nested inside the Zenith submenu (originally menu item 13 → item 22 →
  5, then item 19 → 5 after the 2026-08-24 renumbering) purely for UX
  convenience ("one place for all auto-tuning"), explicitly NOT as a
  functional merge — but this was architecturally confusing precisely
  because autotune-daemon works on z2r strategies directly and has
  nothing to do with Zenith. Moved back out to the top-level main menu
  as its own item 2026-08-28 — see "autotune-daemon moved to main menu"
  below. Nothing about either system's actual behavior changed in either
  move; they still don't know about each other.
- `autotune-daemon` predates Zenith: it's the simpler, DB-less mechanism
  built into z2r_autobench itself — periodically reruns
  `rank_strategies.sh`/`rank_quic.sh` inside a single profile's own
  candidate list and applies the winner via `set_strategy_cli.sh`. Zenith
  is a separate MySQL-backed genome generator (mutation/crossover/UCB)
  with its own promotion pipeline (`auto_promoter.py`).
- **Both independently write `/opt/zapret2/config` and independently
  restart `zapret2.service` for the same profiles when both are
  enabled** — nothing coordinates or locks between them (they don't share
  `TUNE_LOCK_FILE`/`locked.tsv` semantics the way per-profile
  `autotune-daemon` processes do with each other). Running
  `autotune-daemon` and `zenith-promoter` for the *same profile*
  simultaneously is untested and not recommended — pick one per profile
  until this is actually verified safe, don't assume the menu grouping
  implies any safety coordination.

## Zenith (scp-oss/zenith)

- Separate repo/service: strategy *generator* (mutation/crossover/UCB over
  `--lua-desync=` parameters), not part of this repo. Talks to production
  only via `set_strategy_cli.sh set/get/max` — never touches
  `/opt/zapret2` directly. MySQL-backed (`db/schema.sql`), docker-compose
  based, no systemd. Installed via z0r menu item 20 (manage)/30
  (uninstall) (renumbered 2026-08-28 when autotune-daemon moved to the
  main menu, was 19/29 — see "autotune-daemon moved to main menu" below),
  same on-demand-clone pattern as item 22's Discord bot.
- Scaffold-only as of this writing — mutation/UCB/crossover logic not yet
  ported into it.
- 2026-08-27: added `GV_TLS` as a real, testable Zenith profile (real
  filter block sourced from a live prod config + dynamic per-round
  `yt-dlp` URL resolution, see `orchestrator/gv_resolver.py`) — not just
  a stub anymore. Deliberately kept OUT of `zenith_autorun.sh`'s default
  rotation (same yt-dlp-bypasses-the-sandbox dependency risk documented
  under "Test domains" for z2r's own profile 2/5) — opt-in only, via z0r
  19 → 4 → 5 (профили) after confirming `main.py --profile GV_TLS
  --rounds 5` works on that specific server first. Also added z0r 19 → 4
  → 6, a menu-driven way to set `ZENITH_AUTORUN_ROUNDS`/
  `ZENITH_AUTORUN_INTERVAL_MINUTES` via a systemd drop-in instead of
  hand-editing `zenith-autorun.service`.
- Production panel host (Server A) has its own `Zenith/` checkout on `main`,
  independently ahead in places (its own unrelated commits, e.g.
  `create_remote_db_user.sh` work) but *behind* our feature branches —
  migrations beyond `002_node_self_report.sql` (e.g.
  `003_promoted_strategy.sql`) are NOT there until someone deliberately
  pulls/merges them. Meanwhile `z0r-panel` on that same host DOES run our
  feature branch (`claude/realtime-db-api`) — the two sibling repos on one
  box can be on divergent lineages, don't assume they match. Live case
  2026-08-14: panel code shipped a `db.py` query referencing
  `genome_scores.promoted_strategy` before the migration reached that
  host's MySQL — instant 500 on `/overview` (`Unknown column`). Before
  shipping any panel change that depends on a new column/table, remember
  the migration has to independently reach the box's MySQL — a panel git
  pull does not do that by itself.
- MySQL on that host runs in Docker (`zenith-mysql` container, compose
  service name `mysql`), not a host package — there is no `mysql` CLI on
  the host itself. Run SQL via
  `docker compose exec -T -e MYSQL_PWD="$MYSQL_PASSWORD" mysql mysql -u"$MYSQL_USER" "$MYSQL_DATABASE" -e "..."`
  from `$ZENITH_DIR` (same pattern as `z0r`'s own `zenith_mysql_query()`),
  not a bare `mysql -u... -p...` — that fails with "команда не найдена".
- **`zenith_autorun.sh` never actually called `sync_client.py` — found
  2026-08-24 on Server B (Provider B, hub-and-spoke node).** README documents the
  hub-and-spoke design as "после `main.py` шлёт `sync_client.py push`",
  but that line only ever described the manual/cron workflow —
  `zenith_autorun.sh` (the only thing actually running on a schedule,
  via `zenith-autorun.service`) never called `sync_client.py` at all.
  Live symptom: panel showed **0 genomes** for the node for days while
  `main.py` ran perfectly healthily on schedule and genomes accumulated
  fine in the node's own local DB — nothing was ever being sent
  upstream, so the panel had no way to know the node was doing anything.
  Fixed: `zenith_autorun.sh` now calls `sync_client.py push --profile`
  right after each `main.py` round, gated on `ZENITH_DB_MODE=docker` +
  `PANEL_URL` set (hub-and-spoke specifically — an isolated node has
  nothing to sync, and api mode has no local DB to export from, `db.py`
  already writes straight to the panel per-call in that mode). If a
  remote node's genome count still isn't moving on the panel after this
  fix, check locally first (z0r item 19 → 2/3, or a direct DB query) to
  confirm generation itself is actually happening before assuming sync
  is broken again — the two failure modes look identical from the panel
  side alone.
- **The real reason Server B showed 0 genomes was deeper than the missing
  sync call above — found 2026-08-26.** `sandbox/setup_sandbox.sh`
  (one-time: creates `zenith-sandbox`/`zenith-voice-bot` users +
  NFQUEUE iptables rules) had been run, but `sandbox/start_sandbox.sh`
  (generates `nfqws2_sandbox.conf` from the template on first use) never
  had been — `orchestrator/sandbox_apply.py::apply_raw()` raised an
  unhandled `RuntimeError` on the very first genome (`seed`) of every
  TCP-profile round (YT_TLS/RKN_TLS/DS_TLS), crashing `main.py`
  immediately. `zenith_autorun.sh` never checked `main.py`'s exit code
  and unconditionally logged `"$profile завершён"` regardless — for
  days, the log looked like normal 20-round completions while zero
  genomes were ever generated or stored locally for any TCP profile
  (only VOICE_UDP, which doesn't hit this code path, actually ran).
  Fixed both ends: `sandbox_apply.py` now calls `start_sandbox.sh`
  itself when the conf is missing (its own docstring already says it's
  "cheap and safe to restart often" and it already knows how to
  bootstrap the conf from the template) instead of raising immediately
  — only errors out if `start_sandbox.sh` itself fails, which is the
  real signal that the one-time `setup_sandbox.sh` was never run (that
  one stays manual, deliberately not auto-triggered — it's a real
  iptables/user change). `zenith_autorun.sh` now checks `main.py`'s
  exit code and logs a loud warning with the code instead of pretending
  the profile finished normally when it crashed. **Lesson for next
  time:** a periodic automation script that never checks the exit code
  of the thing it's automating can mask a 100%-failure-rate bug for
  days behind cheerful-looking log lines — this is worth grepping for
  in any other `*.sh` loop that calls into a subprocess and always
  prints a "done" message unconditionally afterward.
- Separately noticed on the same Server B run: VOICE_UDP's control-genome
  check was *also* failing instantly (`0 bytes, 0ms`) alongside every
  mutated genome, tripping "ПОДОЗРЕНИЕ НА БАН ПОДТВЕРЖДЕНО" — instant
  zero-byte failures on literally everything including control look
  much more like `z2r_test-voice-bot`'s `/probe` endpoint being
  unreachable on that node (bot not installed/running) than a real
  Discord UDP block, but this wasn't confirmed live — check Discord_bot
  status (z0r item 14) before trusting a VOICE_UDP "ban" verdict from a
  node where the voice bot's own status hasn't been verified.
- **Third bug in the same chain, same Server B session:** once
  `setup_sandbox.sh` was finally run (it genuinely never had been —
  confirmed by the improved error text above naming the missing
  `queue_num` explicitly instead of the old silent crash), the sandbox
  still failed to start — now `nfqws2` itself errored with `cannot
  access file '/opt/zapret2/files/fake/tls_clienthello_max_ru.bin'`.
  `sandbox/nfqws2_sandbox.conf.template` hardcoded `/opt/zapret2/files/
  fake/...` in all 9 `--blob=` lines — same class of bug as
  `blob_tune.sh`'s `FAKE_DIR` (see "/opt/zapret2 vs /opt/zator" above),
  just in the *sandbox's own* template this time, not the production
  config. Fixed: template now uses a `__FAKE_DIR__` placeholder,
  resolved in `start_sandbox.sh` with the same prefer-zapret2-else-
  zator detection as `_z2r_detect_base()` — **first attempt at this
  checked `[ -d ".../files/fake" ]` (directory existence) and still
  picked the wrong side**, because on Server B `/opt/zapret2/files/fake`
  exists as an empty/incomplete directory — the exact same "cannot
  access file" error persisted even with the fix deployed. Corrected to
  probe for the specific file the template actually needs
  (`tls_clienthello_max_ru.bin`), not just the directory — a lesson for
  any future base-detection code in this codebase: prefer probing for
  the actual file/thing you need over a directory-existence check,
  since installers can leave stub/partial directories on the wrong
  side. **Caveat when picking this
  fix up on an already-broken node:** `start_sandbox.sh` only
  regenerates `nfqws2_sandbox.conf` from the template `if [ ! -f
  "$LIVE_CONF" ]` — a stale conf already written to disk from a
  previous failed attempt (with the old hardcoded path baked in) will
  NOT be regenerated by a `git pull` alone. Delete the stale
  `sandbox/nfqws2_sandbox.conf` (it's a generated artifact, safe to
  remove) before the next `start_sandbox.sh` run so it actually
  regenerates with the fix.
- **Fourth bug in the same chain, same Server B session, found 2026-08-26
  after the third bug's fix landed:** the sandbox stopped failing on
  missing blob files but every single genome for every TCP profile
  (YT_TLS/RKN_TLS/DS_TLS) still failed to apply, logging a generic
  "не удалось применить в песочнице (start_sandbox.sh вернул ошибку),
  пропуск" with no detail — `zenith/orchestrator/sandbox_apply.py`'s
  `apply_raw()` captured the final `start_sandbox.sh` subprocess's
  stderr/stdout but discarded it, returning only a bool; every caller
  (`main.py`, `compare_control.py`, `bootstrap.py`) printed the same
  content-free message. Fixed by stashing the captured output in a
  module-level `sandbox_apply.LAST_ERROR` and having all three callers
  include it — this immediately surfaced the real error: `cannot access
  hostlist file '/opt/zapret2/extra_strats/TCP_YT_list.txt'`. Root
  cause was the *same* `/opt/zapret2` vs `/opt/zator` split-brain class
  as everything else in this chain, but this time hardcoded in
  `zenith/orchestrator/genome.py`'s `PROFILE_FILTERS` (the sandbox's own
  copy of the real per-profile `--hostlist=`/`--payload=` filter lines,
  used to actually apply a genome for testing — separate from
  `auto_promoter.py`'s `_PROFILE_TARGETS_DEFAULTS`, which matches literal
  text in the live production config for promotion-anchor purposes and
  is a different, already-documented per-server-calibration concern, not
  touched here). Fixed the same way as the third bug: added
  `config.Z2R_BASE`, detected by probing for the actual
  `extra_strats/TCP_YT_list.txt` file (not directory existence, same
  stub-directory lesson as `FAKE_DIR`), and pointed the `extra_strats/`-
  prefixed hostlist paths at it. `lists/netrogat.txt` paths were left
  hardcoded to `/opt/zapret2` — `lists/` isn't part of what's documented
  to split, only `z2r_lib`/`extra_strats`/`files`. **Lesson reinforced
  yet again**: any code that swallows a subprocess's stderr behind a
  bare bool return turns every future failure in that path into an
  unsolvable mystery — this is now the second time this session a
  generic pass/fail signal (the first was `zenith_autorun.sh` never
  checking `main.py`'s exit code) hid a real, actionable, one-line error
  message for days.
- **Fifth bug in the same chain, found immediately after the fourth's fix
  deployed:** the `lists/netrogat.txt` "isn't part of what's documented
  to split" claim above was wrong — asserted from absence of contrary
  evidence, not from an actual check. The very next run on Server B
  failed identically on `/opt/zapret2/lists/netrogat.txt` (same "cannot
  access hostlist file", surfaced instantly thanks to the fourth bug's
  `LAST_ERROR` fix). Routed `lists/netrogat.txt` through `config.Z2R_BASE`
  too. **Confirmed resolved 2026-08-26**: after this fix, a direct query
  against Server B's `experiments` table showed 111 real rows with
  genuine byte counts (~875-881KB successes, matching a real YouTube
  page well above the 65536-byte threshold; 0-byte/~3000ms failures on
  genomes that didn't get through) — the full apply→probe→record pipeline
  works end-to-end on Server B for the first time since it was deployed.
  Root-cause chain across all five bugs: one filesystem-layout assumption
  (`/opt/zapret2` is never split) baked into three separate places
  (`genome.py`'s hostlist paths, the sandbox conf template's blob paths,
  `sandbox_apply.py`'s swallowed error) each had to be found and fixed
  independently before any of it actually worked — a single wrong
  assumption, made once, then copy-pasted forward, cost five separate
  rounds of "still broken" before the underlying premise itself was
  questioned instead of chasing each symptom in isolation.

## z2r core install — GitHub is not reliable from every provider

- Live case (Provider C, 2026-08-13): `raw.githubusercontent.com`/
  `api.github.com` were flaky/degraded for hours — sometimes the entry
  script fetched fine but a component file failed, sometimes DNS for the
  domain came back with a spoofed extra IP (`1.1.1.1` mixed into the real
  Fastly answers). Both `install_z2r()` mirrors (GitHub direct + the
  `git.px.rkn.quest` mirror) failed outright; the author's own script has
  an internal fallback path that can loop forever on partial failure
  (Ctrl+C kills the whole `sh z0r` process, including the not-yet-cloned
  `/opt/z2r_autobench` — re-run from a directory that still exists, decline
  the z2r prompt, let it clone the repo, then retry z2r separately).
- `sudo ./z0r --install-z2r-offline` is the escape hatch — the author
  publishes an offline archive (Google Drive, RAR5 password `zator`) for
  exactly this. Link rotates over time (author's own warning, not synced
  with git releases) — `Z2R_OFFLINE_ARCHIVE_LAST_KNOWN` in `z0r` is just a
  convenience default for Enter, not guaranteed current; the function
  prompts for a fresh one if the default 404s.
- `dns_looks_hijacked()`/`offer_doh_setup()` in `z0r` detect the DNS-spoof
  case specifically and offer DNS-over-TLS (systemd-resolved drop-in)
  before even trying the GitHub mirrors — but this only helps if at least
  one of the DoH cross-check providers (Google, then Cloudflare) is
  itself reachable; if both are also blocked, it can't tell and silently
  skips the offer.
- `uninstall_z2r()`/`uninstall_zenith()` MUST stop Zenith's sandbox
  `nfqws2` (`stop_zenith_sandbox_if_running()`, wraps
  `sandbox/teardown_sandbox.sh` + `pkill -9 nfqws2`) before `rm -rf
  /opt/zapret2` — that sandbox process is separate from `zapret2.service`
  and, left running, spins forever re-reading now-deleted hostlist files,
  flooding the terminal. Learned the hard way via item 999 on a live box.

## rkn_list_cli.sh — panel-facing view/add for the RKN_TLS production hostlist (since 2026-08-29)

- Added because `z0r-panel`'s new `/rkn` page needed a way to show and
  extend the actual production hostlist that `nfqws2` uses to route
  traffic through RKN_TLS — separate from Zenith's own tiny `domain_pool`
  seed rows (2 entries, only used to pick random test targets during
  genome tuning runs, never read by `nfqws2` itself). Confusing these two
  was a live risk: the panel's `/rkn` page originally only showed
  `domain_pool`, and a user reasonably assumed that WAS the RKN list.
- Same split `test_custom_domain.sh --add-to-rkn` already used:
  `$Z2R_BASE/extra_strats/TCP_RKN_list.txt` is the official list
  (read-only from this script — never appended to, it's maintained by
  the z2r installer/upstream source), `TCP_Custom.txt` is where manual
  additions go, same routing effect (both get matched via
  `detect_governing_profile()`'s hostlist grep — see that function). New
  script doesn't source `z2r_autobench_lib.sh` (that requires a live
  `config.sh`/`orchestra_state.sh`/`netcheck.sh` under `z2r_lib/`, far
  more than this needs) — inlines just the `_z2r_detect_base()` snippet,
  same idiom `z0r`'s own top-level menu already uses for the same reason
  (see "/opt/zapret2 vs /opt/zator" above) — keep both inline copies in
  sync if the detection logic in the real library ever changes.
- Sudoers grant added to `ensure_panel_runtime_grants()`'s existing
  literal-command allowlist (`list` takes no args so no trailing `*`;
  `add *` does, one domain argument) — panel calls it the same way it
  already calls `set_strategy_cli.sh`, no new privilege class introduced.
- `remove <domain>` added 2026-08-29 same day, right after `add` shipped
  (panel UX pass needed delete for the production list too) — deliberately
  ONLY touches `TCP_Custom.txt`, refuses with a clear message if the
  domain is only in the official `TCP_RKN_list.txt` (that file stays
  read-only from this script no matter what, see above). Live bug caught
  by testing before this reached a server: `grep -vxi "$d" "$CUSTOM_LIST"
  > "$CUSTOM_LIST.tmp" && mv ...` — `grep -v` returns exit code 1 when
  its output is empty (exactly the case where the domain being removed
  was the ONLY line in the file), so `&&` silently skipped the `mv` and
  the "removed" domain was still there afterward. Fixed by splitting into
  `grep ... || true` then an unconditional `mv`. Sudoers extended with
  `remove *` alongside `add *`.

## rank_strategies.sh --domain — funnel testing for an arbitrary domain (since 2026-08-29)

- Added because the panel's "Стратегии" page needed a way to run the
  existing `--funnel` mechanic (round 1 tests all strategies, round 2+
  tests only survivors — see the file's own header comment) against a
  single custom domain, not just the profile's hardcoded default URL
  (`https://www.youtube.com/`, `https://meduza.io`, etc., see the
  `case "$PROFILE" in` block). `test_custom_domain.sh` already accepted
  arbitrary `--domain` but never had funnel narrowing (flat exhaustive
  `for pass in 1..PASSES` testing ALL strategies every pass) — the two
  tools stayed separate rather than merging `--funnel` into
  `test_custom_domain.sh`, since that script's real reason to exist is
  multi-domain intersection testing (find one strategy that works for
  SEVERAL domains at once), a genuinely different job.
- `--domain example.com` **overrides `--profile` entirely** — the domain
  is routed through whichever real numeric profile actually governs it
  (by hostlist membership), not whatever `--profile` the caller happened
  to pass. Testing a domain through the "wrong" profile would be a false
  test — it wouldn't reflect how that domain is actually routed in
  production. `GV_ROTATE` (profile 2's per-pass googlevideo.com edge
  rotation) is unreachable in this mode since the detector never returns
  profile 2 for an arbitrary domain.
- The domain→profile routing logic (`z2r_detect_governing_profile()`) was
  **moved into `z2r_autobench_lib.sh`**, shared between this script and
  `test_custom_domain.sh` (which now just calls it) — it used to be a
  standalone copy inside `test_custom_domain.sh` only. Consolidating this
  now, before a second caller could silently drift from the first, is the
  direct lesson from the `/opt/zapret2`-vs-`/opt/zator` saga elsewhere in
  this file: that whole five-bug chain in Zenith was caused by the exact
  same filesystem-detection logic being copy-pasted into multiple files
  and each copy having to be independently found and fixed. One domain
  can register itself into `TCP_Custom.txt` as a side effect of this
  function (`add_to_rkn=1` param) — `rank_strategies.sh --domain` always
  passes `0` (never mutates hostlists as a side effect of a measurement
  run); only `test_custom_domain.sh --add-to-rkn` opts into that.
- Funnel mode now also prints a real-time stdout line per surviving
  candidate (`strategy=N -> OK (bytes, проход P/PASSES)`) **in addition
  to** the existing `RAW_FILE` TSV write — added purely for
  `z0r-panel/funnel_runner.py` to show working candidates as they're
  found instead of only at the end of a full pass. Non-funnel mode and
  `RAW_FILE`'s own format are untouched; nothing that captures this
  script's stdout via `$(...)` exists anywhere in this repo (verified by
  grep before adding the line — `autotune_daemon.sh` only redirects with
  `>>`, never captures), so this is a purely additive, non-breaking
  change for every existing caller.
- Panel wiring: `z0r-panel/funnel_runner.py` shells out to
  `rank_strategies.sh --domain X --funnel --passes N [--settle S]
  [--attempts A]` via `sudo -n bash`. **No extra `flock` wrapper needed**
  — unlike the panel's other launcher (`runner.py`, which starts Zenith's
  `orchestrator/main.py` and needed an external `RUN_LOCK_FILE` flock
  because `main.py` has no locking of its own) `rank_strategies.sh`
  already calls `acquire_tune_lock` internally (shared `TUNE_LOCK_FILE`
  with `autotune_daemon.sh`/`rank_quic.sh`/`rank_voice.sh`/
  `test_custom_domain.sh`) — a second launch while one is already running
  just gets a clear "кто-то ещё сейчас крутит стратегии" failure from the
  script itself. Sudoers grant in `z0r::ensure_panel_runtime_grants`:
  `/usr/bin/bash $INSTALL_DIR/rank_strategies.sh --domain *` — one
  trailing wildcard after `--domain` (same greedy-glob trick as
  `sudoers_run_cmd`, matches any combination of `--funnel`/`--passes`/
  `--settle`/`--attempts` that follows).

## custom_domain_cli.sh — exotic domains with their own independent strategy (since 2026-08-29)

- Different problem from the RKN list: under RKN_TLS (or any other
  profile), EVERY domain shares ONE locked strategy — that's the
  architecture (one hostlist → one `circular_locked` key). Live request:
  some domains need a strategy no shared profile's own works for, without
  affecting any other domain. There's no way to give one domain a truly
  independent, simultaneously-active strategy in this architecture except
  giving it its own hostlist + its own `circular_locked` key — i.e. its
  own small profile block in `/opt/zapret2/config`.
- **Never invents nfqws2 syntax from scratch.** Nobody working on this
  repo has ever seen a real, live `/opt/zapret2/config` — every existing
  tool here only *edits* an already-existing block (bump `strategy=`,
  read `circular_locked:key=N`) via generic text matching, never
  generates new directives. Guessing at `--filter-tcp=`/`--lua-desync=`
  syntax to fabricate a brand-new block risks a malformed config that
  fails `nfqws2` on its next restart, with no way to catch it here (no
  exec access to any server). Instead: **clone the real RKN_TLS block
  verbatim** (`circular_locked:key=3` — per `promote_apply_cli.sh`'s own
  docstring, RKN_TLS/YT_TLS are "TEMPLATE"-style: their own dispatcher
  block is tiny, just `--hostlist=`/`--import=z2r_tcp_tls_common`/
  `circular_locked:key=N`, no `strategy=` lines of its own, those live in
  the shared template) out of the live config, then patch exactly two
  things in the copy: the `--hostlist=` path (→ a new one-line,
  domain-only hostlist file) and `circular_locked:key=3` (→ a freshly
  allocated number). Whatever the real surrounding syntax is, it's
  copied, not guessed — and the new profile automatically inherits the
  full `z2r_tcp_tls_common` strategy catalog with its own independent
  lock, so `rank_strategies.sh --funnel`/`--domain` work against it with
  zero further changes needed there.
- Block boundaries are found by content, not a known header: scan for the
  ONE line matching `circular_locked:key=N` (word-boundary regex, so
  `key=3` never matches `key=30`), then walk backward/forward to the
  nearest `--new` line on each side (same "`--new` separates independent
  blocks" rule as everywhere else in this file). Refuses loudly if the
  key match isn't found exactly once — never guesses which block on an
  ambiguous match.
- New profile numbers are self-allocated, never hardcoded: max of (every
  `circular_locked:key=N` actually found in the live config) and (every
  number already in this tool's own registry), floor `20` — self-
  protecting against collision with the real 1-9 profiles or anything a
  human already added by hand in the 20+ range, without needing to know
  in advance what's really in the file.
- **`add` requires an explicit `--yes` to actually write** — without it,
  it's a pure preview (prints the exact new block, or the refusal reason,
  to stderr; touches nothing). This is the one piece of this whole
  engagement's tooling that structurally appends a brand-new block rather
  than editing an existing one — the preview gate exists specifically so
  a human reviews the generated text against the real donor block before
  it ever reaches the live file. Backup is still mandatory before the
  real write regardless (`config.custom_domain_backup.<ts>`, same idiom
  as `promote_apply_cli.sh`) — restart of `zapret2` afterward is a manual
  step (printed in the output), never automatic, same principle as
  `set_strategy_cli.sh set`.
- Shares its config-write lock file (`config.promote.lock`) with
  `promote_apply_cli.sh` on purpose — both structurally rewrite
  `/opt/zapret2/config` (not just flip a `strategy=N` inside an existing
  block), so a race between the two is worse than a race between two
  ordinary strategy switches.
- **Correction, same day, confirmed against a real live config**: the
  donor template was originally `key=3` (RKN_TLS) — wrong choice. On a
  real server, `circular_locked:key=3` appears TWICE: the normal
  hostlist-matched RKN_TLS block, and a SECOND block matching by
  substring (`include_substrings=.../TCP_RKN_domains_by_substring.txt`)
  that deliberately shares the same lock — plus a THIRD block (profile 8,
  Fallback_TLS) with `route_key=3` pointing at the same lock from yet
  another matching mechanism. `_find_block_by_key()`'s "exactly one match
  or refuse" safety check (working as intended) meant `add` always failed
  on this server. Switched the default donor to `key=1` (YT_TLS),
  confirmed on that same server to be a single, self-contained hostlist
  block. `--template-profile N` added as a manual override in case `key=1`
  is ever ambiguous on some other server too. Also generalized the
  hostlist-path substitution: it now finds whichever line(s) literally
  start with `--hostlist=` inside the donor block and rewrites those,
  instead of hardcoding `TCP_RKN_list.txt`/`TCP_Custom.txt` — necessary
  since different profiles use different hostlist files (and RKN_TLS's
  own block turned out to have TWO separate `--hostlist=` lines, not one
  comma-joined value as first assumed). Refuses if the donor block has no
  `--hostlist=` line at all (e.g. `key=2`/GV_TLS matches via
  `--hostlist-domains=googlevideo.com` instead — an inline value, not a
  file — cloning that wouldn't give the new domain its own file to
  register into).
- **Open/unverified risk, flagged for whoever picks this up next**: the
  real YT_TLS donor block starts with `--qnum 300 --filter-tcp=443
  --filter-l7=tls` — cloning it verbatim carries `--qnum 300` into the
  new block too. Nothing in this repo knows whether nfqws2 tolerates two
  blocks declaring the same `--qnum`, or whether it needs to be unique/
  omitted on the clone. The preview step will show this plainly (it's
  right there in the printed block) — a human needs to actually look at
  it and decide before running `--yes`, not just skim for the
  hostlist/key substitution and assume the rest is fine.
- **If the domain is already governed by an existing profile — refuse
  with a warning, don't create a second conflicting one.** Checked
  against `TCP_YT_list.txt`/`TCP_Discord.txt`/`TCP_RKN_list.txt`/
  `TCP_Custom.txt` directly (not `z2r_detect_governing_profile()`'s
  fallback-catching version, which would call an unmatched domain
  "Fallback_TLS" — that's exactly the shared-strategy problem this tool
  exists to solve, so "not explicitly matched anywhere" is precisely the
  eligible case, not a rejection).
- `z2r_detect_governing_profile()` now ALSO checks this tool's own
  registry (`$ORCH_DIR/custom_domains.tsv`) before falling through to the
  Fallback_TLS default — so `rank_strategies.sh --domain`/
  `test_custom_domain.sh` correctly route an already-registered exotic
  domain to its own profile instead of re-detecting it as unmanaged.
- `remove` deliberately does NOT delete the block from the live config —
  same risk class as creating one, except worse (editing `--new`
  boundaries in a file a running `nfqws2` process may be reading at that
  exact moment). It only empties the domain's one-line hostlist file —
  the block stops matching anything and goes inert, harmlessly, without
  ever touching config structure again.

## domain_list_sync.sh — read-only bridge to official curated domain lists (since 2026-08-31)

- Live finding while closing the `auto_promoter.py` youtubei.googleapis.com
  gap: `domain_pool` for YT_TLS only ever had one row (`www.youtube.com`)
  — testing/promotion coverage was thin not because of a code limit but
  because nobody had added more domains. Turned out the server already
  has real, curated, per-profile domain lists on disk under
  `$Z2R_BASE/lists/` (`russia-youtube.txt`, `russia-discord.txt` —
  confirmed live, 19 and N domains respectively; `russia-youtubeQ.txt`
  exists too but is for the UDP/QUIC YouTube variant, not wired into
  anything domain_pool-related since that profile isn't curl-testable
  the same way; `russia-youtube-rtmps.txt` is raw IPs, not domains, not
  applicable here at all).
- `domain_list_sync.sh <profile>` just cats the matching file (comments/
  blanks stripped) to stdout — **read-only, no state, no mutation**. The
  profile→filename mapping is a hardcoded dict inside the script itself,
  deliberately NOT inferred from a naming pattern (`russia-<profile>`
  doesn't generalize — no such file exists for RKN_TLS/GV_TLS/Fallback
  profiles on the server this was verified against) — add new profiles
  to the dict only after confirming the actual filename on a real
  server, same "don't guess, verify" principle as everything else in
  this file. `--list-profiles` lets a caller (the panel) discover which
  profiles currently have a mapping without hardcoding that list a
  second time somewhere else.
- The panel's `/domains` page calls this to offer a one-click
  "Синхронизировать" button that's only shown for profiles the script
  actually knows about — feeds the resulting domains through the exact
  same `get_or_create_domain()` path as manual/bulk add, so there's no
  separate "synced from file" state to track or drift from what a human
  could've typed by hand.
- `YT_QUIC_UDP` -> `russia-youtubeQ.txt` added to the dict later the same
  day (see z0r-panel's CLAUDE.md "Live bug hit right after this shipped"
  — someone tried pasting that file's path straight into the manual
  add-domain field and got a confusing "Пустой домен").
- **`--path <файл-или-путь>` added same day, on request** ("не до конца
  понял как добавлять путь до списка") — an escape hatch for a profile
  with no entry in `PROFILE_LIST_FILES` (or just a different file), taken
  from the panel as a free-text field instead of the fixed
  "Синхронизировать" button. Still can't read anything outside
  `$Z2R_BASE/lists/`: the argument is either a bare filename (resolved
  against that directory) or a full path, but the script always
  `realpath`-resolves it first (collapsing `..` and symlinks) and refuses
  anything whose resolved path isn't a `$Z2R_BASE/lists/*` prefix, before
  ever touching file contents. The sudoers grant for this script has
  always been a single greedy `domain_list_sync.sh *` (see
  `ensure_panel_runtime_grants`) — this mode doesn't widen that surface,
  the script's own realpath check is the actual boundary, same as it
  already was for the `<profile>` lookup (a bad profile name just fails
  the dict lookup, no filesystem access happens either way). Verified
  with a synthetic `$Z2R_BASE` sandbox before shipping: bare filename,
  full in-directory path, `../../etc/...` traversal (refused), an
  absolute path outside `lists/` (refused), and a missing file (refused,
  distinct message) — all behaved as intended.

## Uniform restart/stop for every managed module (since 2026-08-31)

- Live gap: every `manage_X()` in `z0r` had grown its own one-off ON-state
  prompt, and none of them had BOTH restart and stop — `manage_zapret`
  only ever offered restart, while `manage_daemon`/`manage_voice_bot`/
  `manage_tg_relay`/`manage_panel`/`manage_dnscrypt` only ever offered
  stop. Direct request, using `web_panel` as the concrete example: "заходим
  в неё [пункт 24] — 2 пункта: рестарт и остановить".
- Added a shared `_service_on_menu(label, restart_fn, stop_fn)` — prints
  `1) Рестарт / 2) Остановить / 0) Назад` and dispatches to whichever
  `_X_do_restart`/`_X_do_stop` function the caller passes by name (bash
  resolves the function name at call time, so definition order relative
  to `manage_X()` doesn't matter). Wired into all six: `manage_zapret`,
  `manage_daemon` (autotune-daemon), `manage_voice_bot` (Discord_bot),
  `manage_panel` (web_panel), `manage_tg_relay` (Zenith-TG),
  `manage_dnscrypt`.
- **`_tgrelay_do_restart` deliberately does NOT touch the iptables
  REDIRECT rule** — that's an already-applied network change independent
  of the process, only `_tgrelay_do_stop` removes it (same as before).
  Restarting the relay process shouldn't silently undo working traffic
  redirection.
- **Not yet covered: `zenith_toggle()`** (Zenith's own `1) Запуск/Стоп`
  inside its nested submenu) — three different backends (api/native
  mariadb/docker compose), a genuinely different shape from the other
  six's simple systemd on/off, and no restart concept wired in yet
  (`docker compose restart` for the docker case would be the natural
  fit). Left as a known follow-up rather than forced into today's pattern.
- Panel side: added `.restart()` to `daemon_ctl.SystemdServiceCtl` (used
  by all three panel-managed units: `autotune_daemon`/`zenith_autorun`/
  `zenith_promoter`) and a matching `systemctl restart <unit>` sudoers
  grant alongside each unit's existing start/stop/is-active/journalctl
  set in `z0r::ensure_panel_runtime_grants`. `/controls/automation` now
  shows a "рестарт" button next to start/stop for all three. Discord_bot/
  DNSCrypt-proxy/Zenith-TG/web_panel have NO panel presence at all today
  (CLI-only) — giving them one is a materially bigger scope (new pages,
  new sudoers, new routes each) than "add restart where start/stop
  already exist," deliberately not done in this same pass.
- **Same-day follow-up: "проверить обновления" added to the same
  submenu.** `_service_on_menu()` gained an optional 4th arg (`check_fn`)
  — item `3) Проверить обновления` only appears when the caller passes
  one, so modules with no git-based update path (`zapret2` — third-party
  installer, not this repo's git; `DNSCrypt-proxy` — system package) just
  don't get the option instead of showing something that can't work.
  Wired into the four that DO live in a git checkout: `autotune-daemon`
  (→ `$INSTALL_DIR`, this repo itself), `Discord_bot` (→
  `$VOICE_BOT_DIR`), `web_panel` (→ `$PANEL_DIR`), `Zenith-TG` (→
  `$TGRELAY_DIR`). `_check_git_updates(dir, label)` is read-only —
  `git fetch origin main` + `rev-list --count HEAD..origin/main`,
  reports "actual" or "N commits behind" (with a short log) — it never
  runs the actual `pull`, that stays item 25's (Автообновление) job
  specifically so this check can't be confused with an update mechanism
  of its own.

- The panel has its own equivalent of this check (`daemon_ctl.
  check_git_updates()`, see z0r-panel's own CLAUDE.md) — this repo's
  `ensure_panel_runtime_grants` grants it three literal
  `git -C <dir> <verb> ...` sudoers lines per repo (six total, across
  `$INSTALL_DIR` and `$ZENITH_DIR`) — no `*` wildcards anywhere,
  matching exactly what that Python function invokes. `git_bin` resolved
  the same way as `systemctl_bin`/`journalctl_bin`/`flock_bin` already
  were (`command -v` with a hardcoded fallback path).

## Publishing hygiene

- This repo (and Zenith) are public. Do not commit the production
  server's hostname, ISP/provider names, individual people's names, or
  names of unpublished/draft projects discussed in chat — keep those in
  conversation only. Scrub before any commit touching README/comments if
  such details crept in from chat context.
- Servers/providers mentioned across incident notes below are
  anonymized as `Server A`/`Server B`/etc. and `Provider A`/`Provider
  B`/etc. — a consistent codename per real server/ISP, not per incident,
  so cross-references between sections still resolve to the same
  physical box. 2026-08-26: retroactively scrubbed real hostnames/ISP
  names (that had crept in from chat context over several prior
  sessions) throughout this file to these codenames — if you're adding a
  new incident note, use the existing codename for a server/provider
  already in this document, or the next free letter for a new one.
