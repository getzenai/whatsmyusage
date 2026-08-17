# Security

## Never put a session cookie in an issue

`sessionKey`, `__Secure-next-auth.session-token.*` and `sso` are full logins to your
Claude, ChatGPT or Grok account. Anyone reading the issue can use them. If you have
already pasted one anywhere public, log out of that provider in the browser you took
it from — that invalidates the session — and only then open the report.

The same goes for anything that identifies your account: org UUIDs, e-mail addresses,
account names, real usage numbers. A bug report needs the *shape* of a response, never
your account. Replace values with placeholders before you paste.

## Reporting a vulnerability

Use **Report a vulnerability** on the [Security tab](../../security/advisories/new).
That opens a private advisory that only the maintainers can read. Do not open a public
issue for anything that would let someone else reach an account.

Expect a first reply within a week. There is no bounty; this is a small app maintained
in spare time.

## What this app can and cannot reach

The app talks to three provider APIs with a cookie you pasted yourself, keeps that
cookie in the macOS Keychain, and writes readings to a local SQLite file. It never
sends anything anywhere else, and it never calls a purchase or redemption path.
The `whatsmyusage` CLI has no network access and no Keychain access at all.
