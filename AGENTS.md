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
  Grok has a remaining count of zero. Claude has percentages only — lock stays
  `unknown`.
- Do not hardcode limit names the provider invents. Claude's `limits[]` grows
  new `kind` values; unknown ones pass through.

## Layout

| Path | What |
|---|---|
| `Sources/UsageBarCore` | Common model, `parseUsage`, `extractSessionKey`, translators |
| `Sources/UsageBarApp` | Menu bar, Keychain, `URLSession`. Thin. |
| `Tests/UsageBarCoreTests` | Fixtures with placeholders. No network. |

## Verify

`swift test` must pass on the commit you claim it passes on. Run the full
package suite, not a scoped test filter.
