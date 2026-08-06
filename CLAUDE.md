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

## Test domains

- `MIN_BYTES_THRESHOLD=65536` (`probe_url`/`probe_http_url` in
  `z2r_autobench_lib.sh`) — a candidate test URL/path must actually serve
  ≥64KB or every probe reports false failure regardless of real DPI
  bypass. Check actual response size before adopting a new test domain.
- Domains rot over time and dense probing risks the *site's own* WAF, not
  just DPI/ISP blocking. Prefer CDN/static-asset endpoints over ordinary
  human-facing sites when picking new test targets.

## Zenith (scp-oss/zenith)

- Separate repo/service: strategy *generator* (mutation/crossover/UCB over
  `--lua-desync=` parameters), not part of this repo. Talks to production
  only via `set_strategy_cli.sh set/get/max` — never touches
  `/opt/zapret2` directly. MySQL-backed (`db/schema.sql`), docker-compose
  based, no systemd. Installed via z0r menu item 22 (manage)/23
  (uninstall), same on-demand-clone pattern as item 14's Discord bot.
- Scaffold-only as of this writing — mutation/UCB/crossover logic not yet
  ported into it.

## Publishing hygiene

- This repo (and Zenith) are public. Do not commit the production
  server's hostname, individual people's names, or names of
  unpublished/draft projects discussed in chat — keep those in
  conversation only. Scrub before any commit touching README/comments if
  such details crept in from chat context.
