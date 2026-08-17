# Status pages: what the four of them actually answer

Measured 2026-08-17 from macOS, `URLSession`. Values below are shapes, not an
account: status pages are public and carry no personal data.

The feature they feed answers one question the usage numbers cannot: **is it me
or them?** A meter at 12 % and nothing working is an outage, not a limit.

## The badge lies

`status.claude.com/api/v2/status.json` returned

```json
{"indicator": "none", "description": "All Systems Operational"}
```

while the incident *Degraded performance for Claude Opus 5, Claude Sonnet 5*
was open (`status: monitoring`, `impact: minor`). Same day, GitHub's badge
(`major`, "Partial System Outage") did agree with its incident list.

So the badge is never read. The component list and the incident list decide,
and they are read independently: a component can be `degraded_performance` with
no incident declared at all.

## Claude and GitHub — Statuspage v2

`GET /api/v2/summary.json` on `status.claude.com` and `www.githubstatus.com`.

| Key | What |
|---|---|
| `components[]` | `id`, `name`, `status`, `group` |
| `incidents[]` | the **unresolved** ones, with `components[]`, `started_at`, `shortlink` |
| `status` | the badge. Not read. |

- Component vocabulary seen: `operational`, `degraded_performance`,
  `partial_outage`, `major_outage`, `under_maintenance`.
- Incident vocabulary seen: `investigating`, `identified`, `monitoring`,
  `resolved`, `postmortem`. Only the last two mean the user is fine again.
- `group: true` entries are containers whose children are listed separately.
  Counting both reports one outage twice.
- Claude listed 6 components, GitHub 12.

## OpenAI — same URL shape, different backend

`status.openai.com` answers `/api/v2/summary.json` and `/api/v2/components.json`,
but:

- **`summary.json` has no `incidents` key at all.** Not empty — absent.
- `/api/v2/incidents/unresolved.json` and
  `/api/v2/scheduled-maintenances/active.json` are **404**.
- So open incidents come from `/api/v2/incidents.json` (the full history,
  25 records) filtered on `status`.
- Those records carry **no `components[]` and no `started_at`** — only
  `created_at`. An OpenAI incident cannot be attributed to a service.
- The page lists 25 components in `summary.json`, 34 in `components.json`, and
  **two of them are both named "Login"**. There is nothing to narrow by name,
  which is why OpenAI ships without a default component filter.

## xAI — no API, but a real feed

`status.x.ai` is a server-rendered Next.js page. No `/api/v2/*`, no embedded
JSON payload (`"status"`, `"slug"`, `"severity"` appear zero times in the HTML).
The services and their state are in Tailwind markup:

```html
<a … href="/grok-com"><div class="heading-2">Grok (Web)</div>… >available</div></a>
```

`https://status.x.ai/feed.xml` is the better source and is what the app reads:

```xml
<item>
  <title>[API (us-west-2.api.x.ai)] Imagine Video 1.5 …</title>
  <link>https://status.x.ai/api-us-west-2/INC548339c6</link>
  <guid isPermaLink="false">INC548339c6</guid>
  <description><![CDATA[ <h3>Status: RESOLVED</h3> <p>Severity: available</p> … ]]></description>
  <pubDate>Tue, 07 Jul 2026 15:40:26 GMT</pubDate>
  <category>available</category>
  <category>resolved</category>
</item>
```

- **The service is in the link path**, which is what makes a per-service filter
  possible at all. Slugs seen: `grok-com`, `ios-app`, `android-app`,
  `grok-in-x`, `single-sign-on`, `api-us-east-1`, `api-us-west-2`,
  `api-eu-west-1`, `api-console`, `docs`, `xai-website`.
- **The feed publishes no service list**, so the slug → name table is in
  `XAIServices`, hardcoded from the page.
- **All 105 items were `resolved` with severity `available`.** The severity
  category is the state *after* the incident, not its peak, so it says nothing
  and is not read. What an open item looks like is therefore **not measured** —
  hence: closed only on positive evidence (`resolved` category or
  `Status: RESOLVED`), everything else open.
- That rule is bounded by `openWindow` (7 days). If the markers ever change
  shape, the whole archive would otherwise read as open at once.
- `<guid>` carries an attribute; matching a bare `<guid>` finds nothing.

## Which service belongs to our Grok

**Grok (Web), not the API.** All three of our Grok calls go to `grok.com`
(`UsageClient.swift`), and the cookie comes from that domain — we measure a
consumer subscription, not API credit. The Grok CLI (`grok 1.0.4`) talks to
`cli-chat-proxy.grok.com` with an `auth.x.ai` session, so it is on the same
side of the fence; the status page has no component for that proxy, so
"CLI ⊂ Grok (Web)" is an assumption from the shared domain, not a measurement.
Defaults: **Grok (Web)** and **Single Sign-On** — an SSO outage looks exactly
like being logged out, which is the confusion this feature exists to end.

## Cloudflare

`curl` and Python get a challenge from `status.x.ai`; `URLSession` gets through.
Same story as the usage endpoints. Do not "verify" a status endpoint with curl:
a 403 there is a client fingerprint, not an answer.
