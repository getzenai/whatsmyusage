# WhatsMyUsage

macOS menu bar app at [whatsmyusage.com](https://whatsmyusage.com): the usage that
**actually binds you** across every AI subscription, at a glance — Claude, ChatGPT, Grok.

## Why

Existing bars only show Claude's 5-hour window. Measured 2026-08-15:
5h window **0 %**, weekly limit **100 %** — the bar would have read "0 %" while the
account was locked out. The app has to look at every limit and show the **worst** one.

## Status

| Provider | Endpoint | Status |
|---|---|---|
| Claude | `/api/bootstrap`, `/api/organizations/{id}/usage` | measured live, see [docs/RESEARCH_CLAUDE_ENDPOINT.md](docs/RESEARCH_CLAUDE_ENDPOINT.md) |
| ChatGPT | `/api/auth/session` → Bearer → `GET /backend-api/wham/usage` + `rate-limit-reset-credits` (display only) | measured live, see [docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md](docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md) |
| Grok | `POST /rest/rate-limits` (2 h, per model) + `GetGrokCreditsConfig` (weekly, grpc-web) + `GetRemainingResets` (vouchers, display only) | measured live, see [docs/RESEARCH_GROK_WEEKLY_LIMIT.md](docs/RESEARCH_GROK_WEEKLY_LIMIT.md) |

## Handling cookies — binding

Session cookies (`sessionKey`, `__Secure-next-auth.session-token.*`, `sso`) are full
logins. They **never** belong in a chat, issue, commit, log, or test fixture.

- Entry happens locally in the app, straight from the browser into the paste field.
- Storage in the macOS Keychain, never in a file in the repo.
- Test fixtures: real response structure, values replaced by placeholders.

**This repo is meant to become public.** The same rule therefore covers everything
account-related: no org UUIDs, email addresses, org names, or real usage numbers — what gets
documented is the *shape* of a response, never an account.

On ChatGPT the session token is split across several numbered cookies
(`…session-token.0`, `…session-token.1`) — extraction has to reassemble the parts sorted by
index, otherwise the token is silently invalid.

## Building

```
swift test
Scripts/make-app-bundle.sh        # → .build/WhatsMyUsage.app
open ".build/WhatsMyUsage.app"
```

`Scripts/make-app-bundle.sh` also builds the `whatsmyusage` CLI and copies
it to `~/.local/bin/whatsmyusage`, so agents can run `whatsmyusage status --json`
without a path. The CLI does not go into the `.app` — the app never launches
it, and on a case-insensitive volume `Contents/MacOS/whatsmyusage` is the
same path as `WhatsMyUsage`. The script refuses to overwrite a destination
that already exists under a different name.

Without `USAGE_BAR_SIGN_IDENTITY` the bundle is ad-hoc signed. That identity
is the binary hash, so Keychain treats every rebuild as a new app and prompts
again. A named certificate stays put:

```
USAGE_BAR_SIGN_IDENTITY="WhatsMyUsage Local" Scripts/make-app-bundle.sh
```

Make one in two minutes: Keychain Access → Certificate Assistant → Create a
Certificate… → name it (this is the identity string), Identity Type **Self
Signed Root**, Certificate Type **Code Signing**. The first open still needs
right-click → Open (self-signed, Gatekeeper). After that the Keychain asks
once, then stays quiet across rebuilds.

The bundle id is `com.whatsmyusage.app`. The Keychain item — the name macOS
shows in the access prompt — is `whatsmyusage.com`. A rebuild after a rename
asks once more, then copies cookies from the previous names
(`com.whatsmyusage.app`, `de.getzenai.ai-usage-bar`).

## Using it

The app is a menu bar accessory (no Dock icon). UI is English. First launch is a
short wizard: welcome (Keychain warning + preview of the macOS prompt) → paste
cookies (Continue stores them) → here's what we found → close and use the bar.
The bundle version is the git short hash, shown in Settings and the popover. Chrome: log in → right-click Inspect / ⌥⌘I → Application
→ Storage → Cookies → the site (claude.ai and a.claude.ai are separate) → ⌘A ⌘C.
Paste in the window. Only the session keys go into the Keychain; the rest of the
paste is discarded. Two logins of the same provider (two Claude Max emails) are
two rows. Pasting a refreshed cookie for the same login updates that row.

Settings (the old Cookies window) can hide individual limits, hide an account,
and reorder cards. That order is the popover and the pill.

The menu bar shows a **pill with one coloured slot per account**. Colour is the
worst *account-wide* limit of that subscription:

| Colour | Meaning |
|---|---|
| green | under 70 % |
| yellow | 70 – 89 % |
| orange | 90 – 99 % — nearly out, but still usable |
| red | locked, or the meter reads 100 % — nothing left to spend |

Red is reserved for the wall. At 95 % you can keep working and at 100 % you
cannot, and that is the one difference the bar exists to show. Claude never
sends a lock state, so a full meter counts as blocked on its own.

A full model limit (for example one Claude model) does not paint
the slot — it stays in the popover. Click the pill for progress bars, remaining
time until reset, and rename.

Settings can shrink the pill to a **single slot for all accounts**. Its colour
comes from the mean utilisation of each account's shortest window, on the same
scale — nothing else. A lock on one account does not paint it red: ChatGPT and
Grok send `locked` for a meter that reached 100 % and nothing more, so obeying
any lock made the one slot red almost always. The 100 % is already in the mean.
Everything shut therefore still reads red, and one open account among four full
ones lands in the warning band.

| Key | Action |
|---|---|
| ⌘R | Refresh |
| ⌘, | Settings |
| ⌘Q | Quit |

It also refreshes every five minutes on its own.

## CLI

`whatsmyusage` with no arguments prints the usage block, then which account
to use, then one line per account. `--json` is the data structure. Names and
hidden limits come from the app; hiding is display only. A reading older than
five minutes plus 90 seconds is unknown — never an old number presented as
current.

```
whatsmyusage
whatsmyusage status [--json] [--limits]
whatsmyusage pick [--provider claude]
whatsmyusage achievements --json
```

`pick` exits 0 when an account still has room and 1 when every account is
blocked or stale (stdout then carries the earliest `resetsAt`). A full
model-scoped limit (Fable, Opus, …) blocks the account even when `weekly_all`
has room; the reported `utilization` is still the worst *account* limit.
JSON keys are the model names: `trackingID`, `limitID`, `utilization`, `resetsAt`.

`locked` is what the provider sent. Claude never sends one — every Claude
limit is `unknown`, including a 100 % week. `is_active` on the Claude
response is not a lock (a model limit at 24 % has been seen `is_active:
true` while `weekly_all` sat at 14 %). Read `utilization` (and `pick`'s
exit code) to decide whether the account is usable. ChatGPT sends
`allowed`. Grok's 2-hour window locks at remaining zero; the weekly
credits call locks only at 100 %.

## Core

`UsageBarCore` is testable without a network:

- `SessionCookies.extractSessionKey` — cookie text → Claude `sessionKey`, ChatGPT parts
  (sorted by index, sent back as numbered cookies), Grok `sso`
- `UsageParser.parseUsage` — HTTP status + body → common model
  (label, utilization 0…1, optional reset, locked yes/no/**unknown**)
- `UsageParser.chatGPTAccessToken` — `/api/auth/session` → Bearer; if `accessToken`
  is missing, the session has expired
- `UsageParser.parseGrokWeekly` — grpc-web body → weekly limit, only if the
  period is `weekly`; every error is `nil`, not "!"
- 401 = expired; 403 on a Claude org = that org is not trackable;
  403 on ChatGPT/Grok is **not** a logout (Cloudflare)

One translator per provider. Claude never invents a lock state. ChatGPT takes `allowed`.
Grok infers locked from `remainingQueries == 0`.

## Website

Static landing page in [`site/`](site/). Push to `main` deploys it to
[whatsmyusage.com](https://whatsmyusage.com) via GitHub Actions → Cloudflare Pages.

## License

MIT — see [LICENSE](LICENSE).
