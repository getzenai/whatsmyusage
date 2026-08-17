# Contributing

## Issues, not pull requests

Bug reports and ideas are welcome, and an issue is the way to send them.

Code is not. A pull request that arrives without being asked for will be closed
unread, however good it is. The hard part of a change here is deciding whether
the app should do the thing at all and whether a number can be trusted, and that
decision does not fit in a diff.

If you want to work on something, say so in an issue and wait for an answer.

## For people with push access

Every pull request is squashed, so its title becomes the commit subject, and the
release job reads that subject to decide the next version. Write it as a
Conventional Commit:

```
feat(cli): show the reset voucher
fix(parsers): read a missing count as a miss
feat(log)!: rekey the series          # breaking
```

`docs`, `chore`, `ci`, `test`, `build` and `refactor` release nothing. A version
bump is a promise about behaviour.

There is no test CI, so run the checks yourself on the exact commit you submit:

```sh
swift test                                    # the whole suite, never a filter
swift build -c release -Xswiftc -warnings-as-errors
Scripts/make-app-bundle.sh release
```

Read `AGENTS.md` before touching parsers, cookie handling or the usage log. It
is short, and every rule in it is there because the opposite shipped once.

Never in a commit or a fixture: session cookies, org UUIDs, e-mail addresses,
real usage numbers. Fixtures use real structure and placeholder values.
