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

The app talks to three provider APIs with a cookie you pasted yourself, keeps
that cookie in the macOS Keychain, and writes readings to a local SQLite file.
It sends nothing anywhere else, and it never calls a purchase or redemption
path. The `whatsmyusage` CLI has no network and no Keychain access at all.
