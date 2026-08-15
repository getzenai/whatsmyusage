# Groks Wochenlimit — live gemessen 2026-08-15

`POST /rest/rate-limits` ist **nicht** das Limit, an das ein Grok-Abonnent stößt. Es liefert
nur ein **2-Stunden-Fenster pro Modell**. Das Limit, das die Grok-Oberfläche unter
*Settings → Usage* anzeigt — „Weekly SuperGrok … Limit, N % used, Resets <Datum>" — kommt aus
einer anderen Quelle und kann hoch stehen, während alle 2-h-Fenster auf 0 % sind. Eine Leiste,
die nur `rest/rate-limits` liest, zeigt für Grok dauerhaft „alles frei".

## Woher die Wochenzahl kommt

```
POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
Cookie: sso=<…>
Content-Type: application/grpc-web+proto
X-Grpc-Web: 1
Body: 00 00 00 00 00      (leeres Request-Message, nur der 5-Byte-Rahmen)
```

Gemessen mit **Swift `URLSession` und nur dem `sso`-Cookie**: HTTP 200,
`content-type: application/grpc-web+proto`. Kein Bearer, kein `cf_clearance`, kein UA-Spoof.

**JSON gibt es nicht.** `application/json`, `application/connect+json` und
`application/grpc-web+json` antworten alle mit Länge 0 und
`grpc-status: 13 · Unexpected EOF decoding stream`. Der Dienst spricht ausschließlich Protobuf.

**Der Status steht im Körper, nicht im Header.** Die Antwort ist ein grpc-web-Rahmenpaar:
Datenrahmen (Flag `0x00`, 4 Byte Länge, Message) gefolgt von einem Trailer-Rahmen
(Flag `0x80`) mit dem Text `grpc-status:0`. Ein `HTTPURLResponse.value(forHTTPHeaderField:)`
auf `grpc-status` liefert `nil` — wer darauf prüft, hält jede Antwort für kaputt.

## Die Antwort, nach Feldnummern

Ohne `.proto`-Definition reicht ein Wire-Format-Leser; die gebrauchten Felder liegen fest:

| Pfad | Typ | Bedeutung |
|---|---|---|
| `1` | message | `config` |
| `1.1` | fixed32 (float) | **Auslastung in Prozent, 0…100** |
| `1.4` / `1.5` | Timestamp | Abrechnungszeitraum (`seconds`, `nanos`) |
| `1.7` | message, wiederholt | `productUsage`: `.1` Produkt-Enum, `.2` Prozent dieses Produkts |
| `1.8.1` | varint | Periodentyp: **2 = weekly**, 1 = monthly |
| `1.8.2` / `1.8.3` | Timestamp | **Beginn und Ende der laufenden Periode** |

`1.8.3` ist damit das, was Grok bisher fehlte: ein echter **Zurücksetzungs-Zeitpunkt**.
`rest/rate-limits` hat nur eine Fensterlänge.

Die Prozentzahl kommt fertig, wie bei ChatGPT — nichts zu rechnen. Einen Sperrzustand sendet
der Dienst weiterhin nicht; `locked` bleibt `unknown`, außer die Zahl steht auf 100.

Gegenprobe an der Oberfläche: der Wert in `1.1` ist genau die Zahl, die die Usage-Ansicht als
„N % used" zeigt, und `1.8.3` genau ihr „Resets …"-Datum.

## Was das für die App heißt

Grok braucht **zwei** Aufrufe: `rest/rate-limits` je Modell für das 2-h-Fenster (Kurzfrist) und
diesen einen für die Woche (Langfrist) — dieselbe Beziehung wie Claudes `five_hour`/`seven_day`.
Das Wochenlimit ist das kontobezogene; die 2-h-Fenster sind pro Modell.

Nicht gebraucht, gleiche Kodierung, bewusst draußen: `ConsumerUiSvc/GetRemainingResets`
(„Reset available"), `GetPrepaidBenefits`, `GrokBuildBilling/ListInvoices`.

## Methode

Gemessen im ferngesteuerten Chrome (siehe `RESEARCH_CHATGPT_GROK_ENDPOINTS.md`, Abschnitt
„Methode"). Die Zuordnung Zahl → Endpunkt kam nicht aus dem Netzwerkmitschnitt, sondern aus den
**React-Props des Elements**, das die Zahl zeichnet: der Fiber-Baum über der Prozentanzeige
trägt das gelieferte Objekt (`usagePercent`, `currentPeriod`, `productUsage`, `tierName`), und
die passende Umwandlung stand im Chunk daneben. Bei einer Zahl, die aus binärem gRPC kommt,
findet ein Body-Suchlauf nach der Zahl nichts — der Client weiß, was er gezeichnet hat.

**Danach erst der Beleg, der zählt:** derselbe Aufruf aus Swift `URLSession` mit nur dem
Cookie. Ein im Browser gelungener Aufruf beweist die Adresse, nicht die Berechtigung.
