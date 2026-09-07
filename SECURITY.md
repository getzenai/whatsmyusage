# Security

## Reporting a vulnerability

Use **Report a vulnerability** on the [Security tab](../../security/advisories/new).
That opens a private advisory only the maintainers can read. Do not use a public
issue for anything that would let someone else reach an account.

Expect a first reply within a week. There is no bounty; this is a small app
maintained in spare time.

Redact before you paste. Session cookies, org UUIDs, e-mail addresses and real
usage numbers all identify your account, and a report needs the shape of a
response, not your account. If a cookie has already gone somewhere public, log
out of that provider in the browser you took it from. That invalidates the
session.

## What this app can reach

The app reads three provider APIs with a cookie you pasted yourself, keeps that
cookie in the macOS Keychain, and writes readings to a local SQLite file. Each
cookie only ever goes to the provider it came from, and no reading leaves your
machine.

Besides those three it fetches two kinds of public page, both without a cookie:
the status pages of Anthropic, OpenAI, xAI and GitHub, and the update feed at
whatsmyusage.com. It calls no purchase or redemption path anywhere. The
`whatsmyusage` CLI reads the local log and nothing else: no network, no
Keychain.
