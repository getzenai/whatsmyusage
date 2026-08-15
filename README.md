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
| ChatGPT | `GET /backend-api/wham/usage` | live gemessen, siehe [docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md](docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md) |
| Grok | `POST /rest/rate-limits` (pro Modell) | live gemessen, siehe [docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md](docs/RESEARCH_CHATGPT_GROK_ENDPOINTS.md) |

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
