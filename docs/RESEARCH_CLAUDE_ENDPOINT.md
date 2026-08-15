# Claude-Endpunkte für die Usage Bar — live gemessen 2026-08-15

Gemessen gegen ein echtes Konto mit gültigem `sessionKey`. Nur lesende GETs.
Alle kontobezogenen Werte (Org-UUIDs, Org-Namen, E-Mail, konkrete Prozentzahlen) sind hier
durch Platzhalter ersetzt — dokumentiert ist die **Form** der Antwort, nicht ein Konto.

## 1. Cloudflare blockt Nicht-Browser-Clients — aber nicht URLSession

| Client | `/api/bootstrap` |
|---|---|
| python `urllib` (mit und ohne `cf_clearance`, Safari-UA) | **403** |
| `curl` (mit `cf_clearance`, Safari-UA) | **403**, Body = Cloudflare Managed Challenge (`__cf_chl_rt_tk`) |
| Swift `URLSession`, nur `Cookie: sessionKey=…`, kein UA gesetzt | **200** |

Zwei Konsequenzen:

- **Die App braucht nur `sessionKey`.** Kein `cf_clearance`, kein `lastActiveOrg`, kein UA-Spoofing.
- **Endpunkte nie mit curl/python testen.** Ein 403 dort ist ein Fingerprint-Block, keine
  Auth-Aussage. Jeder Spike gegen claude.ai läuft über URLSession.

## 2. `/api/bootstrap` → `account.memberships[]`

Ein Login kann mehrere Organisationen tragen, und **nicht jede ist ein Abo**. Beobachtete Formen:

| `rate_limit_tier` | `capabilities` | `/usage` |
|---|---|---|
| `default_raven` | `chat`, `raven` | 200 |
| `default_claude_max_20x` | `chat`, `claude_max` | 200 |
| `auto_trust_tier_c` | `api` | **403** |

Die dritte ist die API-Konsole, kein Abo. `/usage` antwortet dort

```json
{"type":"error","error":{"type":"permission_error","message":"Invalid authorization for organization"}}
```

Das ist ein **403 mit gültigem Cookie**. „401/403 → Tracking abgelaufen" wäre hier falsch und
würde ein Tracking grau schalten, dessen Cookie einwandfrei ist. Notwendige Unterscheidung:

- 401 überall, oder 403 auf `/api/bootstrap` → **Cookie abgelaufen**
- 403 nur auf `/organizations/{id}/usage`, `type: permission_error` → **Org nicht trackbar**

Im Org-Picker deshalb nur Orgs anbieten, deren `capabilities` `chat` enthält, und die 403-Antwort
trotzdem sauber behandeln (Capabilities können sich ändern).

## 3. Der Fall, für den es die App gibt — reproduziert

Ein Max-Konto zum Messzeitpunkt:

```
five_hour.utilization   =   0     resets_at = null
seven_day.utilization   = 100     resets_at = <ts>
limits[weekly_all]      = 100     severity = "critical", is_active = true
limits[weekly_scoped/<Modell>] = 100  severity = "critical"
```

Die verbreitete Leiste zeigt ausschließlich `five_hour` — also **0 %**, während das Wochenlimit
voll und das Konto gesperrt ist. Kein Hörensagen, sondern ein Messwert.

## 4. Antwortstruktur `/organizations/{id}/usage`

`limits[]` ist die reichere Quelle:

```json
{"group":"weekly","kind":"weekly_scoped","percent":100,"is_active":false,
 "resets_at":"…","severity":"critical",
 "scope":{"model":{"display_name":"<Modell>","id":null},"surface":null}}
```

- `kind` ∈ `session` | `weekly_all` | `weekly_scoped` (bisher beobachtet)
- `group` ∈ `session` | `weekly`
- `scope == null` → **blocking**; `scope.model != null` → **model**
- `severity` ∈ `normal` | `critical` — vom Anbieter, brauchbar als Kreuzprobe zur eigenen Schwelle
- `is_active` markiert das *bindende* Limit, ist aber **nicht** dasselbe wie „voll":
  beobachtet wurde ein Modell-Limit bei 24 % mit `is_active: true`, während `weekly_all` bei 14 %
  auf `false` stand. **Nicht als Filter benutzen.**
- `percent` kommt als **Int** (`1`, `14`, `24`, `100`) — Decoder muss Int **und** Double nehmen.

Top-Level-Schlüssel duplizieren `limits[]`: `five_hour` == `limits[kind=session]`,
`seven_day` == `limits[kind=weekly_all]`. Beide tragen zusätzlich
`limit_dollars`/`used_dollars`/`remaining_dollars` (hier durchgehend `null`).

`seven_day_sonnet`, `seven_day_opus` sind **null** — Modelllimits stehen nur noch in `limits[]`.
`limits[]` ist also nicht Zukunftsvorsorge, sondern heute schon die einzige Quelle dafür.

Weitere Top-Level-Schlüssel, alle `null`, offenbar unveröffentlichte Buckets:
`amber_ladder`, `cinder_cove`, `iguana_necktie`, `nimbus_quill`, `omelette_promotional`,
`tangelo`, `seven_day_cowork`, `seven_day_oauth_apps`, `seven_day_omelette`.
**Bestätigt die generische Verarbeitung** — wer diese Namen hardcodet, schreibt Code für Buckets,
die es morgen anders gibt.

`extra_usage` und `spend` beschreiben Guthaben/Overage. `spend.percent` und
`extra_usage.utilization` wären eigene Buckets; für v1 nicht nötig, aber vorhanden — ein
separater `/prepaid/credits`-Aufruf ist damit womöglich überflüssig.

## Was daraus folgt

1. Cookie-Eingabe braucht **nur** `sessionKey`; `lastActiveOrg` ist bequem, nicht nötig.
2. Fehlerbehandlung: 403 auf `/usage` ≠ abgelaufen. Eigener Zustand „Org nicht trackbar".
3. `parseUsage` liest `limits[]` als Primärquelle, `scope` entscheidet blocking vs. model,
   `percent` als Int **oder** Double, unbekannte `kind`-Werte werden durchgereicht statt verworfen.
4. `severity` mitnehmen — kostenlos, und der Anbieter weiß selbst am besten, was kritisch ist.
