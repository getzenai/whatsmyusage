# AGENTS.md

Read `README.md` and `docs/` before changing parsers or cookie handling.

## Hard rules

- Session cookies never go in chat, commit, log, or test fixtures. Fixtures use real
  *structure* and placeholder *values*.
- This repo is meant to be public. No org UUIDs, emails, account names, or live
  usage numbers from a real account. Document the shape of a response, never an account.
- Never probe the live APIs with `curl` or Python. Cloudflare challenges both.
  A 403 from those clients is a fingerprint block, not an auth result. Spikes go
  through Swift `URLSession`.
- 403 is not "expired". 401 everywhere (or 403 on Claude `/api/bootstrap`) means
  the cookie is dead. 403 on a single Claude org's `/usage` with `permission_error`
  means that org is not trackable. Greying the whole Claude tracking on that 403
  hides a healthy session.
- ChatGPT `/backend-api/` rejects cookies. Mint a Bearer from `GET /api/auth/session`
  (`accessToken`). A 200 session body without `accessToken` is expired — not a later
  401 on `wham/usage`.
- Do not invent a lock state the provider does not send. ChatGPT has `allowed`.
  Grok's 2-hour window locks at remaining zero; the weekly credits call locks
  only at 100 %. Claude has percentages only — lock stays `unknown`.
- Grok's weekly limit is `application/grpc-web+proto`, not JSON. JSON encodings
  return an empty body and `grpc-status: 13`. Status is in the trailer frame
  (flag `0x80`), never in the HTTP header. Only take the limit when field
  `1.8.1 == 2` (weekly); any other period type is dropped, not remapped.
- Reset vouchers are display-only. Never call `redeemReset` or any purchase
  path. A missing field is a miss, not 0 — do not `?? 0`. Show the line only
  when the provider sent a count ≥ 1. Claude has no such endpoint. The extra
  call must not delay the limit refresh.
- The usage log stores every reading, never a state change it decided at write time,
  and never `accountLabel` (org name, plan). The series key is `trackingID + limit.id`,
  which survives a rename. Anything derived — resets, waits, burn rate, achievements —
  is a query in `UsageHistory` / `Achievements`, so a wrong rule stays fixable instead
  of destroying data. No badge is ever stored.
- Achievements read the change points, not every row. A rule must therefore measure a
  full stretch to the reading that saw it *end*, never to the last stored full reading:
  the identical readings in between are not kept, so that one collapses to zero.
- The `whatsmyusage` CLI reads `usage-log.sqlite` and the app UserDefaults suite
  `com.whatsmyusage.app` (`accountDisplayNames`, `accountDefaultNames`). No
  network, no Keychain, no cookies. Do not write `accountLabel` into the log.
  A number older than one refresh (5 min) plus 90 s is `null` / "unknown",
  never a current value — same rule as the pill (spec 18, 20, 25). `pick` treats a
  full model-scoped limit as blocking; the number it reports is still the
  account-scoped worst. Claude `locked` stays `unknown` — do not invent it.
- Do not hardcode limit names the provider invents. Claude's `limits[]` grows
  new `kind` values; unknown ones pass through.
- Status pages: the badge is not the answer. Claude reported "All Systems
  Operational" with an incident open. Read `components[]` and the incident
  list; a component can be degraded with nothing declared. A page that timed
  out, changed shape, or answered 503 is `unchecked`, never "no incidents" —
  silence must not render as health. Unknown component words count as trouble,
  and an incident that names no component counts for the whole source — so the
  per-service ticks narrow degradations, never incidents. OpenAI's components
  come from `components.json`: its `summary.json` truncates at 25 of 34 and
  cuts off exactly the Codex services. See `docs/RESEARCH_STATUS_PAGES.md`.

## Layout

| Path | What |
|---|---|
| `Sources/UsageBarCore` | Common model, `parseUsage`, `extractSessionKey`, translators, log, CLI queries |
| `Sources/UsageBarApp` | Menu bar, Keychain, `URLSession`. Thin. |
| `Sources/WhatsMyUsageCLI` | `whatsmyusage` argv + print. No Keychain, no network. |
| `Tests/UsageBarCoreTests` | Fixtures with placeholders. No network. |

## Versioning

Every PR is squashed, so **the PR title becomes the commit subject and the
release job reads it**. Title it as a Conventional Commit:

```
type(scope): subject          feat(cli): show the reset voucher
type(scope)!: subject         feat(log)!: rekey the series   (breaking)
```

| Type | Release |
|---|---|
| `feat` | minor |
| `fix`, `perf`, `revert` | patch |
| `refactor`, `docs`, `test`, `build`, `ci`, `chore`, `style` | none |
| any type with `!`, or a `BREAKING CHANGE:` footer | major |

- **Git tags are the version.** No VERSION file, nothing to keep in sync.
  `Scripts/make-app-bundle.sh` and the release job both read the latest tag.
- **Below 1.0.0 a breaking change bumps the minor**, not the major — a first
  `feat!:` should not declare the product finished. The strict rule takes over
  by itself once a tag reads 1.x.
- **A batch of only `docs` / `chore` / `ci` / `test` / `build` / `refactor`
  releases nothing.** A version bump is a promise about behaviour.
- One parser does all of it: `Scripts/semver.py`. Check a title before you open
  the PR with `Scripts/semver.py check-title "feat: …"`, and see what main would
  release with `Scripts/semver.py next`. Change the rules there and both CI jobs
  follow; `Scripts/semver.py selftest` guards it and runs first in both.

## Verify

`swift test` must pass on the commit you claim it passes on. Run the full
package suite, not a scoped test filter.

CI (`.github/workflows/ci.yml`, Blacksmith macOS runners) repeats that and adds
what a green suite does not cover: `swift build -c release -Xswiftc
-warnings-as-errors` over every source target, and `Scripts/make-app-bundle.sh`.
`swift test` never compiles `Sources/UsageBarApp`, so the app can be broken with
285 tests passing. **A new compiler warning fails the build** — both parser bugs
fixed in `fix(parsers)` were standing warnings. Tests are exempt: the
swift-testing dependency is deprecated on Swift 6.3 and still required without
Xcode.
