# Claude endpoints for the usage bar — measured live 2026-08-15

Measured against a real account with a valid `sessionKey`. Read-only GETs.
Every account-related value (org UUIDs, org names, email, concrete percentages) has been
replaced by a placeholder here — what is documented is the **shape** of the response, not an
account.

## 1. Cloudflare blocks non-browser clients — but not URLSession

| Client | `/api/bootstrap` |
|---|---|
| python `urllib` (with and without `cf_clearance`, Safari UA) | **403** |
| `curl` (with `cf_clearance`, Safari UA) | **403**, body = Cloudflare Managed Challenge (`__cf_chl_rt_tk`) |
| Swift `URLSession`, only `Cookie: sessionKey=…`, no UA set | **200** |

Two consequences:

- **The app only needs `sessionKey`.** No `cf_clearance`, no `lastActiveOrg`, no UA spoofing.
- **Never test endpoints with curl/python.** A 403 there is a fingerprint block, not a
  statement about auth. Every spike against claude.ai goes through URLSession.

## 2. `/api/bootstrap` → `account.memberships[]`

One login can carry several organizations, and **not every one is a subscription**. Observed
shapes:

| `rate_limit_tier` | `capabilities` | `/usage` |
|---|---|---|
| `default_raven` | `chat`, `raven` | 200 |
| `default_claude_max_20x` | `chat`, `claude_max` | 200 |
| `auto_trust_tier_c` | `api` | **403** |

The third one is the API console, not a subscription. `/usage` answers there with

```json
{"type":"error","error":{"type":"permission_error","message":"Invalid authorization for organization"}}
```

That is a **403 with a valid cookie**. "401/403 → tracking expired" would be wrong here and
would grey out a tracking whose cookie is perfectly fine. The distinction that matters:

- 401 everywhere, or 403 on `/api/bootstrap` → **cookie expired**
- 403 only on `/organizations/{id}/usage`, `type: permission_error` → **org not trackable**

So the org picker only offers orgs whose `capabilities` contain `chat`, and still handles the
403 response cleanly (capabilities can change).

## 3. The case the app exists for — reproduced

A Max account at the time of measurement:

```
five_hour.utilization   =   0     resets_at = null
seven_day.utilization   = 100     resets_at = <ts>
limits[weekly_all]      = 100     severity = "critical", is_active = true
limits[weekly_scoped/<model>] = 100  severity = "critical"
```

The widespread bar shows `five_hour` only — so **0 %**, while the weekly limit is full and the
account is locked. Not hearsay, a measurement.

## 4. Response structure of `/organizations/{id}/usage`

`limits[]` is the richer source:

```json
{"group":"weekly","kind":"weekly_scoped","percent":100,"is_active":false,
 "resets_at":"…","severity":"critical",
 "scope":{"model":{"display_name":"<model>","id":null},"surface":null}}
```

- `kind` ∈ `session` | `weekly_all` | `weekly_scoped` (observed so far)
- `group` ∈ `session` | `weekly`
- `scope == null` → **blocking**; `scope.model != null` → **model**
- `severity` ∈ `normal` | `critical` — from the provider, useful as a cross-check against our
  own threshold
- `is_active` marks the *binding* limit, but is **not** the same as "full":
  observed was a model limit at 24 % with `is_active: true`, while `weekly_all` sat at 14 %
  with `false`. **Do not use it as a filter.**
- `percent` arrives as an **Int** (`1`, `14`, `24`, `100`) — the decoder has to accept Int
  **and** Double.

Top-level keys duplicate `limits[]`: `five_hour` == `limits[kind=session]`,
`seven_day` == `limits[kind=weekly_all]`. Both additionally carry
`limit_dollars`/`used_dollars`/`remaining_dollars` (all `null` here).

`seven_day_sonnet`, `seven_day_opus` are **null** — model limits now live in `limits[]` only.
So `limits[]` is not future-proofing, it is already today the single source for them.

Further top-level keys, all `null`, apparently unreleased buckets:
`amber_ladder`, `cinder_cove`, `iguana_necktie`, `nimbus_quill`, `omelette_promotional`,
`tangelo`, `seven_day_cowork`, `seven_day_oauth_apps`, `seven_day_omelette`.
**This confirms generic handling** — hardcoding those names means writing code for buckets that
will look different tomorrow.

`extra_usage` and `spend` describe credit/overage. `spend.percent` and
`extra_usage.utilization` would be buckets of their own; not needed for v1, but present — which
may well make a separate `/prepaid/credits` call unnecessary.

## What follows from this

1. Cookie entry needs **only** `sessionKey`; `lastActiveOrg` is convenient, not required.
2. Error handling: 403 on `/usage` ≠ expired. It gets its own state, "org not trackable".
3. `parseUsage` reads `limits[]` as the primary source, `scope` decides blocking vs. model,
   `percent` as Int **or** Double, unknown `kind` values pass through instead of being dropped.
4. Take `severity` along — it is free, and the provider knows best what counts as critical.
