# Does a module click feel instant? — the measurement, and what it found

Owner complaint, 2026-09-15: *"why it feels like a website? because when click different
modules, it will refresh? whereas other apps i used before feels there no loading at all."*

This file records how that was measured, what the numbers were, and the one conclusion worth
keeping. The tool is `tests/browser/measure-navigation-feel.mjs`. It is **not a test and not a
CI gate** — it reports, it does not pass or fail. Pinning a machine's timing to a threshold is
how a suite learns to be ignored.

## Running it

```
PLAYWRIGHT_MODULE="<...>/playwright-core/index.js" \
PLAYWRIGHT_EXECUTABLE_PATH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
MEASURE_RPC_MS=150 node tests/browser/measure-navigation-feel.mjs
```

| env | default | what it is for |
|---|---|---|
| `MEASURE_RPC_MS` | `0` | delay injected into the stub's thenable. **0 is the client-side floor** — at 0ms the loading state cannot even be observed, because it is replaced inside the same task. 150 approximates a Singapore → Supabase round trip. |
| `MEASURE_APP_DIR` | this repo's `app/` | point at another worktree's `app/` to compare against a baseline. The owner stub is loaded from **that build's own** `tests/browser/fixtures/`, so a build is never measured against a stub it never shipped with. |
| `MEASURE_PORT` | `4990` | give each concurrent run its own. |
| `MEASURE_NAV` | `click` | `hash` navigates by `location.hash` instead of clicking the rail — the rail is `display:none` at mobile widths, so it is the only way to measure 390px on equal terms. |
| `MEASURE_WIDTH` / `HEIGHT` | `1280x900` | |
| `MEASURE_ROUNDS` | `6` | |

## The conclusion worth keeping: count waves, not nodes

**DOM churn was never the bottleneck.** v912's shell reuse took chrome churn from 494 to 437
element nodes per navigation and left commit time *identical* — 125ms both. What costs is
**serial read waves**: round trips stacked end to end, where a read begins only after every
earlier one has finished. Latency multiplies waves.

Measured at 150ms per read, before v948:

| page | commit | waves | loading state seen |
|---|---|---|---|
| one-wave pages (Customers, Bookings) | ~125ms | 1 | **never** |
| Record sale | 412ms | 2 | **8/8** |
| Appointments | 409ms | 3 | **8/8** |
| both, after v948 | ~245ms | 1 | **0/8** |

So: if a page ever "feels like a website" again, **count its waves before touching its
rendering.**

## Baseline on `main` @ `284f5ce3` (v974), 1280x900, 150ms injected

Splash never visible — `splash_seen_pct: 0`, peak opacity 0 — across every run. That is the
260ms `animation-delay` (v958) doing its job: the loading state exists, and no navigation now
lasts long enough to reach it.

| page | commit (first visit) | waves |
|---|---|---|
| `#/custpackages` | 59ms | 1 |
| `#/bookings` | 54ms | 1 |
| `#/clients` | 127ms | 1 |
| `#/till` (Record sale) | 208ms | 1 |
| `#/appointments` | 232ms | 1 |

At 0ms latency the same navigations commit in 60–76ms, which is the app's own rendering cost.

## One honest caveat found while validating the committed copy

On **repeat** visits within a long run, `#/till` measures **2 waves** (237ms), not 1. That is
not a regression — it is v948's documented fallback showing up in the numbers. v948 seeds the
per-branch projections at T=0 from `branchScopeCacheV370`, which has a **120s TTL**; once that
lapses, the seed is empty and the projections are fetched at `settle()` after the branch list
is known, which is the old two-wave shape. `loadBranchModuleProjection` is deliberately
uncached (v370 — it carries permission state another session can revoke), so the fix could
only ever be "start it earlier", never "remember it".

The practical reading: the first navigation into Record sale — the one a merchant actually
experiences — is one wave. A tab left open past two minutes pays the second wave again. Worth
revisiting only if the owner reports slowness on returning to the page, not before.

## Two probe bugs that produced confident nonsense

Both are commented in the harness at the lines that fix them, because both produced *impossible*
values (a rebuilt-every-time shell "surviving" 100%) rather than merely wrong ones.

1. **Arming after the event.** `page.evaluate(probe)` issued without `await` before `page.click`
   often ran *after* the navigation had finished, "measuring" a settled page: 0 mutations, ~0ms.
   Arm, **await the arming**, then click.
2. **Committing on the old page.** Clicking `<a href="#/x">` changes `location.hash`
   **synchronously**, long before `route()` renders. A commit condition of "hash matches and some
   `h1` exists" fires while the old DOM is still on screen. Require the **new `<main>` node**.

When a number is impossible, the instrument is wrong. See
`docs/engineering/BUG_CLOSURE_PROTOCOL.md` and the standing note on verifying the measuring tool
before its verdict.

## Gotchas

- Leftover `python3 -m http.server` processes from an aborted run cause confusing "not serving a
  build" failures in *later* runs and in `run-browser-checks.mjs`. The harness kills its server in
  a `finally`, but `pkill -f 'http.server 49'` first if a run was interrupted.
- The harness clicks `#navwrap`, which is `display:none` at 390px — use `MEASURE_NAV=hash` there.
- `playwright-core` ships no browser, so `PLAYWRIGHT_EXECUTABLE_PATH` is required with it.

## The gates that *do* assert

- `tests/browser/verify-v912-shell-reuse.mjs` — the shell is reused across navigations.
- `tests/browser/verify-v972-idle-dock.mjs` — the hidden mobile dock is not rebuilt, and is
  correct the moment a resize reveals it.
- `tests/business-ui/v948-branch-projection-overlap.test.mjs` — the projections still settle for
  every assigned branch, and failure still blocks the write controls.

**Known pre-existing:** `verify-reward-overview-owner.mjs` fails identically on untouched `main`.
