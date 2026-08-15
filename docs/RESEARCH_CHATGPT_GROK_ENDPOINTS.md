# ChatGPT- und Grok-Endpunkte — live gemessen 2026-08-15

Gemessen durch Mitschnitt des echten Browserverkehrs (Chrome DevTools Protocol, siehe
„Methode" unten). Alle kontobezogenen Werte sind durch Platzhalter ersetzt.

## ChatGPT

**Der Endpunkt ist `GET https://chatgpt.com/backend-api/wham/usage` — aber Cookies allein
reichen nicht.** Es sind zwei Schritte:

1. `GET https://chatgpt.com/api/auth/session` mit den `session-token`-Cookies → Feld `accessToken`
2. `GET /backend-api/wham/usage` mit **`Authorization: Bearer <accessToken>`** (die Cookies dürfen
   mitgehen, tragen aber nicht)

**Ohne den Bearer antwortet `/backend-api/` mit 401 — auch mit dem vollständigen Cookie-Satz.**
Live gemessen: Token allein 401, Token + `__Secure-oai-is` 401, Token + `cf_clearance` 401,
**alle 22 Cookies der Domain** 401; mit Bearer 200. Für Schritt 1 genügen die beiden
`__Secure-next-auth.session-token.N`.

Das ist die Falle dieser Messmethode: der Browser hängt den `Authorization`-Header selbst an, und
ein Mitschnitt, der bewusst keine Header aufzeichnet, sieht davon nichts. **Ein aufgezeichneter
Aufruf beweist die Adresse, nicht die Berechtigung.** Wer hier nur die URL übernimmt, baut ein
Tracking, das dauerhaft „abgelaufen" anzeigt, obwohl die Anmeldung einwandfrei ist.

Die Usage-Ansicht selbst ist eine reine Client-Route (`chatgpt.com/#settings/Usage`) — der Server
sieht sie nie. Beim Aufbau der Seite laufen ~50 Aufrufe unter `/backend-api/`; nur einer trägt die
Zahlen.

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

Bemerkenswert:

- **`used_percent` kommt fertig** — anders als bei Grok muss nichts gerechnet werden.
- **`primary_window` / `secondary_window`** sind das Gegenstück zu Claudes `five_hour` /
  `seven_day`. `limit_window_seconds: 604800` = eine Woche. `secondary_window` war hier `null`;
  die App darf sich also nicht darauf verlassen, dass beide existieren.
- **`reset_at` ist ein Unix-Zeitstempel**, `reset_after_seconds` dieselbe Information relativ.
- **`allowed: false` ist das ehrlichste Feld der ganzen API** — der Anbieter sagt selbst, ob
  gerade noch etwas geht. Genau das gehört in die Leiste, nicht nur eine Prozentzahl.
- `plan_type` unterscheidet `team`/`plus`/`pro`; die Ansicht ist kontobezogen, nicht nutzerbezogen.

Ergänzende Endpunkte, für v1 nicht nötig:

| Endpunkt | Inhalt |
|---|---|
| `GET /backend-api/wham/rate-limit-reset-credits` | „Reset available"-Guthaben: `available_count`, `immediate_reset_purchase_eligible` |
| `GET /backend-api/accounts/{accountId}/remaining_balance` | Guthaben als String (`"0"`) |
| `GET /backend-api/pageConfigs/usage_limits` | steuert nur, was die Web-UI anzeigt |

## Grok

**Der Endpunkt ist `POST https://grok.com/rest/rate-limits` mit `{"modelName":"<modell>"}`.**

```json
{"windowSizeSeconds": 7200, "remainingQueries": 270, "totalQueries": 270,
 "lowEffortRateLimits": null, "highEffortRateLimits": null}
```

Drei Unterschiede, die für die App zählen:

1. **Grok zählt Anfragen, keine Prozente.** Auslastung = `1 - remainingQueries / totalQueries`.
   Der Anbieter sagt nicht, ob man gesperrt ist — das muss die App aus `remainingQueries == 0`
   selbst schließen.
2. **Ein Aufruf pro Modell.** `modelName` ist Pflicht (beobachtet: `fast`). Für mehrere Modelle
   braucht die App mehrere Aufrufe, nicht einen.
3. **`windowSizeSeconds` statt `reset_at`** — es gibt keinen Zeitpunkt, nur eine Fensterlänge
   (hier 2 h). Ein „setzt zurück um …" lässt sich daraus **nicht** ableiten.

**Die „Reset available"-Anzeige ist teuer.** Sie kommt aus
`POST /prod_mc_billing.ConsumerUiSvc/GetRemainingResets`, und das ist **gRPC-Web mit
Protobuf-Kodierung** (`application/grpc-web+proto`), nicht JSON. Ohne die `.proto`-Definitionen
ist das in Swift erheblicher Aufwand. **Für v1 draußen lassen** — dieselbe Kodierung gilt für
alle `ConsumerUiSvc`- und `GrokBuildBilling`-Aufrufe (Zahlungsmittel, Guthaben, Auto-Top-up).

## Was die drei Anbieter gemeinsam haben — und was nicht

| | Claude | ChatGPT | Grok |
|---|---|---|---|
| Auslastung | `percent` (Int) | `used_percent` | selbst rechnen aus `remaining/total` |
| gesperrt? | aus `percent == 100` schließen | **`allowed`** direkt | aus `remainingQueries == 0` schließen |
| Zurücksetzung | `resets_at` (ISO) | `reset_at` (Unix) | nur Fensterlänge |
| mehrere Limits | `limits[]` in einer Antwort | `primary`/`secondary_window` | ein Aufruf **pro Modell** |
| Kontoauswahl | Organisation | Account | — |

Folge für den Kern der App: ein gemeinsames Modell aus (Bezeichnung, Auslastung 0…1,
Zurücksetzung optional, gesperrt ja/nein/unbekannt) und **pro Anbieter ein Übersetzer**. Der
kleinste gemeinsame Nenner ist die Auslastung; alles andere fehlt bei mindestens einem Anbieter.

## Methode — Verkehr mitschneiden, ohne Cookies weiterzureichen

1. Chrome mit **eigenem Profil** starten: `--remote-debugging-port=9222
   --user-data-dir=/tmp/chrome-cdp`. **Ab Chrome 136 ignoriert Chrome die Fernsteuerung auf dem
   Standardprofil** — bewusste Härtung, kein Fehler. In diesem Profil einmal anmelden.
2. Über das DevTools-Protokoll an **alle** Ziele hängen, nicht nur an die Seite: Settings-Ansichten
   laufen in eigenen Kontexten (iframe/Worker). Wer nur am Hauptdokument lauscht, sieht ~50 von
   ~80 Aufrufen — und der gesuchte ist im fehlenden Drittel.
3. `Debugger.setSkipAllPauses` setzen: claude.ai enthält eine Anti-Debugger-Falle (`debugger;`),
   die die Seite einfriert, sobald ein Debugger hängt.
4. Hash-Routen laden bei `Page.navigate` auf dieselbe Adresse **nicht** neu — Reload erzwingen.

Der Mitschnitt hält Adressen, Anfragekörper und Antwortkörper fest, **keine Header und keine
Cookies**. Für die App wird die Form der Antwort gebraucht, nie der Schlüssel.
