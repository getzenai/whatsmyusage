# ChatGPT and Grok endpoints — measured live 2026-08-15

Measured by capturing real browser traffic (Chrome DevTools Protocol, see "Method" below).
Every account-related value has been replaced by a placeholder.

## ChatGPT

**The endpoint is `GET https://chatgpt.com/backend-api/wham/usage` — but cookies alone are not
enough.** It takes two steps:

1. `GET https://chatgpt.com/api/auth/session` with the `session-token` cookies → field `accessToken`
2. `GET /backend-api/wham/usage` with **`Authorization: Bearer <accessToken>`** (the cookies may
   ride along, but they carry nothing)

**Without the bearer, `/backend-api/` answers 401 — even with the complete cookie set.**
Measured live: token alone 401, token + `__Secure-oai-is` 401, token + `cf_clearance` 401,
**all 22 cookies of the domain** 401; with bearer 200. For step 1 the two
`__Secure-next-auth.session-token.N` are enough.

That is the trap of this measurement method: the browser attaches the `Authorization` header
itself, and a capture that deliberately records no headers sees nothing of it. **A recorded call
proves the address, not the authorization.** Copy just the URL here and you build a tracking that
permanently reads "expired" while the login is perfectly fine.

The usage view itself is a pure client route (`chatgpt.com/#settings/Usage`) — the server never
sees it. Building the page fires ~50 calls under `/backend-api/`; only one carries the numbers.

```json
{
  "user_id": "user-…", "account_id": "…", "email": "…",
  "plan_type": "team",
  "rate_limit": {
    "allowed": false,
    "limit_reached": true,
    "primary_window": {
      "used_percent": 100,
      "limit_window_seconds": 604800,
      "reset_after_seconds": 248662,
      "reset_at": 1787043909
    },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": null,
  "credits": { "has_credits": false, "unlimited": false, "overage_limit_reached": false,
               "balance": null, "approx_local_messages": null, "approx_cloud_messages": null },
  "spend_control": { "reached": false, "individual_limit": null },
  "rate_limit_reached_type": { "type": "workspace_owner_credits_depleted", "details": null },
  "rate_limit_upsell": { … }
}
```

Worth noting:

- **`used_percent` arrives ready-made** — unlike Grok, nothing has to be computed.
- **`primary_window` / `secondary_window`** are the counterpart to Claude's `five_hour` /
  `seven_day`. `limit_window_seconds: 604800` = one week. `secondary_window` was `null` here, so
  the app must not rely on both existing.
- **`reset_at` is a Unix timestamp**, `reset_after_seconds` the same information relative.
- **`allowed: false` is the most honest field in the whole API** — the provider itself says
  whether anything still works right now. That is what belongs in the bar, not a percentage alone.
- `plan_type` distinguishes `team`/`plus`/`pro`; the view is account-scoped, not user-scoped.

Supplementary endpoints, not needed for v1:

| Endpoint | Content |
|---|---|
| `GET /backend-api/wham/rate-limit-reset-credits` | Reset vouchers. Measured 2026-08-16: `{ "available_count": 0, "credits": [], "immediate_reset_purchase_eligible": false, "total_earned_count": 0 }`. Same Bearer as `/wham/usage`. Missing `available_count` is a miss, not 0. `immediate_reset_purchase_eligible` is a store flag — do not redeem, do not offer to buy. |
| `GET /backend-api/accounts/{accountId}/remaining_balance` | balance as a string (`"0"`) |
| `GET /backend-api/pageConfigs/usage_limits` | only controls what the web UI displays |

## Grok

**The endpoint is `POST https://grok.com/rest/rate-limits` with `{"modelName":"<model>"}`.**

> **Addendum 2026-08-15: this is the short-term window only.** The weekly limit that Grok's UI
> shows is not in here and can sit high while every 2 h window reads 0 %.
> Source and encoding: `RESEARCH_GROK_WEEKLY_LIMIT.md`.

```json
{"windowSizeSeconds": 7200, "remainingQueries": 270, "totalQueries": 270,
 "lowEffortRateLimits": null, "highEffortRateLimits": null}
```

Three differences that matter for the app:

1. **Grok counts requests, not percentages.** Utilization = `1 - remainingQueries / totalQueries`.
   The provider does not say whether you are locked out — the app has to infer that from
   `remainingQueries == 0` itself.
2. **One call per model.** `modelName` is required (observed: `fast`). Several models mean
   several calls, not one.
3. **`windowSizeSeconds` instead of `reset_at`** — there is no point in time, only a window
   length (2 h here). A "resets at …" **cannot** be derived from it.

**"Reset available" is now readable.** `POST /prod_mc_billing.ConsumerUiSvc/GetRemainingResets`
uses the same grpc-web encoding as `GetGrokCreditsConfig`. Field numbers and the empty-list
rule: `RESEARCH_GROK_WEEKLY_LIMIT.md`. Do not call `redeemReset`.

## What the three providers have in common — and what they don't

| | Claude | ChatGPT | Grok |
|---|---|---|---|
| utilization | `percent` (Int) | `used_percent` | compute from `remaining/total` |
| locked? | infer from `percent == 100` | **`allowed`** directly | infer from `remainingQueries == 0` |
| reset | `resets_at` (ISO) | `reset_at` (Unix) | window length only |
| several limits | `limits[]` in one response | `primary`/`secondary_window` | one call **per model** |
| account selection | organization | account | — |

Consequence for the core of the app: one common model of (label, utilization 0…1, optional
reset, locked yes/no/unknown) and **one translator per provider**. The smallest common
denominator is utilization; everything else is missing at at least one provider.

## Method — capture traffic without passing cookies on

1. Start Chrome with its **own profile**: `--remote-debugging-port=9222
   --user-data-dir=/tmp/chrome-cdp`. **From Chrome 136 on, Chrome ignores remote control on the
   default profile** — deliberate hardening, not a bug. Log in once inside that profile.
2. Attach to **all** targets over the DevTools protocol, not just the page: settings views run in
   their own contexts (iframe/worker). Listen to the main document only and you see ~50 of ~80
   calls — and the one you want is in the missing third.
3. Set `Debugger.setSkipAllPauses`: claude.ai contains an anti-debugger trap (`debugger;`) that
   freezes the page as soon as a debugger attaches.
4. Hash routes do **not** reload on `Page.navigate` to the same address — force a reload.

The capture records addresses, request bodies and response bodies, **no headers and no cookies**.
What the app needs is the shape of the response, never the key.
