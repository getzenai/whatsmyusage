# Updates

The app updates itself with [Sparkle 2](https://sparkle-project.org). This is
what is wired up, what is deliberately not, and how a release ends up in the
feed the app polls.

## What the user sees

- Settings has a checkbox, **Check for updates automatically**, and a **Check
  now** button.
- The app menu (visible while a window of ours is in front) has **Check for
  Updates…**.
- The automatic check starts **off** (`SUEnableAutomaticChecks` is `false` in
  the bundle). Sparkle would otherwise ask on the first launch with a modal,
  and the first thing a new app says should not be about itself.

## Why Sparkle and not a hand-rolled check

Reading the GitHub releases API and comparing a version number is easy. The
three things around it are not:

- **Replacing a running app.** A process cannot overwrite its own bundle and
  live. Sparkle ships a helper (`Autoupdate`, plus two XPC services) that does
  the swap and relaunches, and that cleans up if it is killed mid-way.
- **Proving the update is ours.** Gatekeeper checks that a download is signed
  by *a* valid Developer ID, not by *ours*. Sparkle additionally checks that
  the new bundle's team identifier matches the running app's, and that the
  archive carries an EdDSA signature made with our private key. A hijacked feed
  or a hijacked release asset still installs nothing.
- The rest: quarantine flag, downgrade protection, "remind me later", progress.

## Keys and where they live

| Thing | Where |
|---|---|
| EdDSA public key (`SUPublicEDKey`) | `Scripts/make-app-bundle.sh`, written into the bundle |
| EdDSA private key | The maintainer's login Keychain, item *Private key for signing Sparkle updates* |
| Feed URL (`SUFeedURL`) | `Scripts/make-app-bundle.sh` → `https://whatsmyusage.com/appcast.xml` |
| The feed itself | `appcast.xml`, attached to the newest GitHub release; `site/_redirects` points the feed URL at it |
| The empty skeleton | `Scripts/appcast-template.xml` |
| EdDSA private key, for the release job | repo secret `SPARKLE_PRIVATE_KEY` |

The private key was generated with Sparkle's `generate_keys` and lives in the
Keychain. The repo secret is a copy of it, made once:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x private-key.txt   # may ask for Keychain access
gh secret set SPARKLE_PRIVATE_KEY < private-key.txt
rm private-key.txt
```

Losing the private key means no existing installation can ever be updated
again: the public half is baked into every shipped bundle. Back it up with the
Developer ID certificate, not separately.

## How a release reaches the feed

`.github/workflows/release.yml` does all of it, in this order, and each step
exists because the one before it is not enough:

1. Build on a macOS runner and sign with the Developer ID, hardened runtime and
   a real timestamp — Sparkle's helpers (`Autoupdate`, `Updater.app`, the two
   XPC services) get the same treatment, because notarisation looks at every
   executable in the bundle and not only the outermost one.
2. Notarise, staple the ticket, ask `spctl` what Gatekeeper will say.
3. Publish the release with the stapled zip attached.
4. Sign that zip with the EdDSA key (`sign_update`, key on stdin), build the
   feed from `Scripts/appcast-template.xml` with `Scripts/appcast.py`, and
   attach it to the same release as `appcast.xml`.

The order matters at step 3/4: the feed goes in after the asset is downloadable.
A feed that points at nothing turns every user's check into an error.

### Why the feed is a release asset and not a file in the repo

It was a file in `site/`, and the first release showed why that cannot work:
the entry can only be written after Apple has notarised the build, and by then
the job has to push it to `main` — which branch protection refuses, correctly.
Weakening the protection to let a job past it is a worse trade than moving the
file.

So the release carries its own feed, and `site/_redirects` sends
`https://whatsmyusage.com/appcast.xml` — the URL baked into every bundle we
have ever shipped — to
`https://github.com/getzenai/whatsmyusage/releases/latest/download/appcast.xml`.
`latest` follows the newest published release on its own, so nothing has to be
updated when we ship.

Each feed holds one item, the release it is attached to. Sparkle offers the
highest version it finds, so older items would be history and nothing else.

### Why CFBundleVersion is the tag and not the commit

Sparkle compares `CFBundleVersion` between the running app and the feed's
`sparkle:version`. A git short hash is not larger or smaller than another git
short hash, so the comparison would be a coin toss. The bundle therefore carries
the tag in `CFBundleVersion` and the commit in `WMUBuildCommit`, which nothing
does arithmetic on. `AppVersion.label` still shows both.

## Testing it without a certificate

`Scripts/make-app-bundle.sh` produces a bundle with the feed URL and the public
key in it, ad-hoc signed. Launching it and pressing **Check now** exercises the
whole path except the install: the feed is fetched and parsed, and an empty
channel reports that the app is up to date. It cannot install anything, because
an ad-hoc signature has no team identifier to match.
