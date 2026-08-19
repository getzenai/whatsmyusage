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
| The feed itself | `site/appcast.xml`, deployed with the rest of the site |
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
4. Sign that zip with the EdDSA key (`sign_update`, key on stdin) and write the
   `<item>` into `site/appcast.xml` with `Scripts/appcast.py`.
5. Commit the feed to `main` and start the site deploy **by name**: a push made
   with `GITHUB_TOKEN` does not trigger another workflow, so `on: push` would
   never fire and the feed would sit in the repo, unpublished.

The order matters at step 3/4: the feed goes in after the asset is downloadable.
A feed that points at nothing turns every user's check into an error.

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
