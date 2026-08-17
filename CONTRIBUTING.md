# Contributing

## Open an issue before you write code

An unannounced pull request is very likely to be closed, however good the code is.
The expensive part of a change here is not writing it — it is deciding whether the
app should do the thing at all, and whether a number can be trusted. That decision
does not fit in a diff. So: issue first, agreement, then code.

Forks are disabled, so a pull request needs push access. Ask in an issue.

## What a change has to survive

There is no test CI for a fork to lean on, so run it yourself on the exact commit
you submit:

```sh
swift test                                    # the whole suite, never a filter
swift build -c release -Xswiftc -warnings-as-errors
Scripts/make-app-bundle.sh release
```

Read `AGENTS.md` before touching parsers, cookie handling or the usage log. It is
short, and every rule in it is there because the opposite shipped once.

## The pull request title is the release

Every pull request is squashed, so its title becomes the commit subject and the
release job reads that subject to decide the next version. Write it as a
Conventional Commit:

```
feat(cli): show the reset voucher
fix(parsers): read a missing count as a miss
feat(log)!: rekey the series          # breaking
```

`docs`, `chore`, `ci`, `test`, `build` and `refactor` release nothing. That is on
purpose: a version bump is a promise about behaviour.

## Never in a commit, an issue or a fixture

Session cookies, org UUIDs, e-mail addresses, account names, real usage numbers.
Fixtures use real *structure* and placeholder *values*. See `SECURITY.md`.
