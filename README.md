# ai_usage_bar

macOS-Menüleisten-App: der **wirklich bindende** Verbrauch aller AI-Abos auf einen Blick —
Claude, ChatGPT, Grok.

## Warum

Bestehende Leisten zeigen bei Claude nur das 5-Stunden-Fenster. Gemessen am 15.08.2026:
5h-Fenster **0 %**, Wochenlimit **100 %** — die Leiste hätte „0 %" angezeigt, während das
Konto gesperrt war. Die App muss über alle Limits gehen und das **schlimmste** anzeigen.

## Stand

| Anbieter | Endpunkt | Stand |
|---|---|---|
| Claude | `/api/bootstrap`, `/api/organizations/{id}/usage` | live gemessen, siehe [docs/RESEARCH_CLAUDE_ENDPOINT.md](docs/RESEARCH_CLAUDE_ENDPOINT.md) |
| ChatGPT | `/api/auth/session` → Bearer → `GET /backend-api/wham/usage` | live gemessen, siehe [docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md](docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md) |
| Grok | `POST /rest/rate-limits` (2 h, pro Modell) + `GetGrokCreditsConfig` (Woche, grpc-web) | live gemessen, siehe [docs/RESEARCH_GROK_WEEKLY_LIMIT.md](docs/RESEARCH_GROK_WEEKLY_LIMIT.md) |

## Umgang mit Cookies — verbindlich

Session-Cookies (`sessionKey`, `__Secure-next-auth.session-token.*`, `sso`) sind vollwertige
Anmeldungen. Sie gehören **niemals** in Chat, Issue, Commit, Log oder Testfixture.

- Eingabe passiert lokal in der App, direkt aus dem Browser in die Paste-Eingabe.
- Ablage in der macOS-Keychain, nie in einer Datei im Repo.
- Fixtures für Tests: echte Antwortstruktur, Werte durch Platzhalter ersetzt.

**Dieses Repo soll öffentlich werden.** Deshalb gilt dieselbe Regel für alles Kontobezogene:
keine Org-UUIDs, E-Mail-Adressen, Org-Namen oder realen Verbrauchszahlen — dokumentiert wird
die *Form* einer Antwort, nie ein Konto.

Bei ChatGPT ist das Sitzungstoken auf mehrere nummerierte Cookies aufgeteilt
(`…session-token.0`, `…session-token.1`) — die Extraktion muss die Teile nach Index sortiert
wieder zusammensetzen, sonst ist das Token still ungültig.

## Bauen

```
swift test
Scripts/make-app-bundle.sh        # → .build/AI Usage Bar.app
open ".build/AI Usage Bar.app"
```

Die App ist ein Menüleisten-Accessory (kein Dock-Icon). Beim ersten Start öffnet sich
das Cookie-Fenster. Ein Paste aus dem Safari-Cookie-Reiter reicht; erkannte Schlüssel
wandern in die Keychain, der Rohtext nicht.

Die Leiste zeigt das **schlimmste account-weite Limit** über alle Anbieter. Ein volles
Modell-Limit (z. B. nur ein Claude-Modell) färbt die Leiste nicht — das steht im Menü.

| Tastatur | Aktion |
|---|---|
| ⌘R | aktualisieren |
| ⌘, | Cookies |
| ⌘Q | beenden |

Auffrischung zusätzlich alle fünf Minuten.

## Kern

`UsageBarCore` ist ohne Netz testbar:

- `SessionCookies.extractSessionKey` — Cookie-Text → Claude `sessionKey`, ChatGPT-Teile
  (nach Index sortiert, als nummerierte Cookies gesendet), Grok `sso`
- `UsageParser.parseUsage` — HTTP-Status + Body → gemeinsames Modell
  (Bezeichnung, Auslastung 0…1, optionale Zurücksetzung, gesperrt ja/nein/**unbekannt**)
- `UsageParser.chatGPTAccessToken` — `/api/auth/session` → Bearer; fehlt
  `accessToken`, ist die Sitzung abgelaufen
- `UsageParser.parseGrokWeekly` — grpc-web-Körper → Wochenlimit, nur wenn
  die Periode `weekly` ist; jeder Fehler ist `nil`, nicht „!"
- 401 = abgelaufen; 403 auf einer Claude-Org = diese Org ist nicht trackbar;
  403 auf ChatGPT/Grok ist **kein** Logout (Cloudflare)

Pro Anbieter ein Übersetzer. Claude erfindet keinen Sperrzustand. ChatGPT nimmt `allowed`.
Grok schließt gesperrt aus `remainingQueries == 0`.
