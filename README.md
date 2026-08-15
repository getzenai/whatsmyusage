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

Without `USAGE_BAR_SIGN_IDENTITY` the bundle is ad-hoc signed. That identity
is the binary hash, so Keychain treats every rebuild as a new app and prompts
again. A named certificate stays put:

```
USAGE_BAR_SIGN_IDENTITY="AI Usage Bar Local" Scripts/make-app-bundle.sh
```

Make one in two minutes: Keychain Access → Certificate Assistant → Create a
Certificate… → name it (this is the identity string), Identity Type **Self
Signed Root**, Certificate Type **Code Signing**. The first open still needs
right-click → Open (self-signed, Gatekeeper). After that the Keychain asks
once, then stays quiet across rebuilds.

The app is a menu bar accessory (no Dock icon). UI is English. First launch is a
short wizard: welcome (Keychain warning + preview of the macOS prompt) → paste
cookies (Continue stores them) → here’s what we found → close and use the bar.
The bundle version is the git short hash, shown in Settings and the popover. Chrome: log in → right-click Inspect / ⌥⌘I → Application
→ Storage → Cookies → the site (claude.ai and a.claude.ai are separate) → ⌘A ⌘C.
Paste in the window. Only the session keys go into the Keychain; the rest of the
paste is discarded. Two logins of the same provider (two Claude Max emails) are
two rows. Pasting a refreshed cookie for the same login updates that row.

Settings (the old Cookies window) can hide individual limits, hide an account,
and reorder cards. That order is the popover and the pill.

The menu bar shows a **pill with one coloured slot per account**. Colour is the
worst *account-wide* limit of that subscription (green < 70 %, orange < 90 %,
red otherwise). A full model limit (for example one Claude model) does not paint
the slot — it stays in the popover. Click the pill for progress bars, remaining
time until reset, and rename.

| Key | Action |
|---|---|
| ⌘R | Refresh |
| ⌘, | Settings |
| ⌘Q | Quit |

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
