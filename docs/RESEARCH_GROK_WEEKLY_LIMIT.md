# Grok's weekly limit — measured live 2026-08-15

`POST /rest/rate-limits` is **not** the limit a Grok subscriber runs into. It only reports a
**2-hour window per model**. The limit that Grok's own UI shows under *Settings → Usage* —
"Weekly SuperGrok … Limit, N % used, Resets <date>" — comes from a different source and can sit
high while every 2 h window reads 0 %. A bar that only reads `rest/rate-limits` will show
"all clear" for Grok forever.

## Where the weekly number comes from

```
POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
Cookie: sso=<…>
Content-Type: application/grpc-web+proto
X-Grpc-Web: 1
Body: 00 00 00 00 00      (empty request message, just the 5-byte frame)
```

Measured with **Swift `URLSession` and the `sso` cookie alone**: HTTP 200,
`content-type: application/grpc-web+proto`. No bearer, no `cf_clearance`, no UA spoof.

**There is no JSON.** `application/json`, `application/connect+json` and
`application/grpc-web+json` all answer with length 0 and
`grpc-status: 13 · Unexpected EOF decoding stream`. The service speaks protobuf only.

**The status lives in the body, not the header.** The response is a pair of grpc-web frames: a
data frame (flag `0x00`, 4-byte length, message) followed by a trailer frame (flag `0x80`)
carrying the text `grpc-status:0`. An `HTTPURLResponse.value(forHTTPHeaderField:)` on
`grpc-status` returns `nil` — check that and you will consider every response broken.

## The response, by field number

Without a `.proto` definition a wire-format reader is enough; the fields we need are fixed:

| Path | Type | Meaning |
|---|---|---|
| `1` | message | `config` |
| `1.1` | fixed32 (float) | **utilization in percent, 0…100** |
| `1.4` / `1.5` | Timestamp | billing period (`seconds`, `nanos`) |
| `1.7` | message, repeated | `productUsage`: `.1` product enum, `.2` percent of that product |
| `1.8.1` | varint | period type: **2 = weekly**, 1 = monthly |
| `1.8.2` / `1.8.3` | Timestamp | **start and end of the current period** |

`1.8.3` is therefore what Grok had been missing: a real **reset timestamp**.
`rest/rate-limits` only has a window length.

The percentage arrives ready-made, as with ChatGPT — nothing to compute. The service still does
not send a lock state; `locked` stays `unknown` unless the number reads 100.

Cross-checked against the UI: the value in `1.1` is exactly the number the usage view shows as
"N % used", and `1.8.3` is exactly its "Resets …" date.

## What this means for the app

Grok needs **two** calls: `rest/rate-limits` per model for the 2 h window (short term) and this
one for the week (long term) — the same relationship as Claude's `five_hour`/`seven_day`. The
weekly limit is the account-wide one; the 2 h windows are per model.

Not needed, same encoding, deliberately left out: `ConsumerUiSvc/GetRemainingResets`
("Reset available"), `GetPrepaidBenefits`, `GrokBuildBilling/ListInvoices`.

## Method

Measured in remote-controlled Chrome (see `RESEARCH_CHATGPT_GROK_ENDPOINTS.md`, section
"Method"). Mapping number → endpoint did not come from the network capture but from the
**React props of the element** that draws the number: the fiber tree above the percentage
carries the delivered object (`usagePercent`, `currentPeriod`, `productUsage`, `tierName`), and
the matching conversion sat in the chunk next to it. For a number that arrives as binary gRPC,
searching the bodies for that number finds nothing — the client knows what it drew.

**Only then the evidence that counts:** the same call from Swift `URLSession` with the cookie
alone. A call that succeeded in the browser proves the address, not the authorization.
