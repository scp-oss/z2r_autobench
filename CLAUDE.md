# CLAUDE.md

Operational notes for Claude sessions working on this repo — dense, for an
agent, not prose for an external reader (that's what README.md is for).
Do not put server names, individual people's names, or unpublished/draft
project names here — same public-repo constraint as README.md.

## Workflow constraints

- Designated branch: `claude/z2r-autobench-open-issues-hq8gjy`. Never push
  elsewhere without explicit permission.
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

## `/opt/zapret2` vs `/opt/zator` — two real directories, not a symlink pair (since 2026-08-23)

- Live incident on NETH-4: after a core-file recovery, `/opt/zapret2` and
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

## Zenith-TG (scp-oss/Zenith-TG)

- Separate repo: transparent Telegram access, not a zapret2 desync
  profile — tried that first (`zapret2/TG_MTPROTO.block.conf` still in
  that repo for reference), confirmed live on NETH-4 that it does
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
  Confirmed working end-to-end on NETH-4 with an unmodified Telegram
  client over the existing VLESS tunnel.
- Installed via z0r menu item 24 (manage)/25 (uninstall), same
  on-demand-clone pattern as Zenith's 22/23 — but note its shipped
  `relay/tg-transparent-relay.service` hardcodes `/opt/Zenith-TG`
  (how it was first deployed by hand); `manage_tg_relay()` in `z0r`
  `sed`-rewrites that path to the real `$TGRELAY_DIR` before installing
  the unit, don't `cp` it as-is like `manage_panel` does.

## Zenith (scp-oss/zenith)

- Separate repo/service: strategy *generator* (mutation/crossover/UCB over
  `--lua-desync=` parameters), not part of this repo. Talks to production
  only via `set_strategy_cli.sh set/get/max` — never touches
  `/opt/zapret2` directly. MySQL-backed (`db/schema.sql`), docker-compose
  based, no systemd. Installed via z0r menu item 22 (manage)/23
  (uninstall), same on-demand-clone pattern as item 14's Discord bot.
- Scaffold-only as of this writing — mutation/UCB/crossover logic not yet
  ported into it.
- Production panel host (NETH-4) has its own `Zenith/` checkout on `main`,
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

## z2r core install — GitHub is not reliable from every provider

- Live case (Rostelecom, 2026-08-13): `raw.githubusercontent.com`/
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

## Publishing hygiene

- This repo (and Zenith) are public. Do not commit the production
  server's hostname, individual people's names, or names of
  unpublished/draft projects discussed in chat — keep those in
  conversation only. Scrub before any commit touching README/comments if
  such details crept in from chat context.
