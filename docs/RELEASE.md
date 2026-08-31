# Getting DriveLayer onto your phone

The `TestFlight` workflow archives, signs and uploads the app. Everything it
needs about your Apple account comes from repository secrets — nothing about the
developer account is committed.

This is the one part of DriveLayer that cannot be automated from a Linux
container: signing requires your certificate and your account. Below is
everything you have to do once, and then the button you press.

---

## 1. Apple Developer Program — required

TestFlight needs a paid membership (currently $99/year) at
<https://developer.apple.com/programs/>. A free account can install to your own
phone from Xcode, but it cannot upload to TestFlight and its builds expire after
seven days.

The membership also unlocks **WeatherKit**, which DriveLayer needs before route
weather returns anything. That is worth knowing before you decide it is
expensive: it is one purchase for both.

## 2. Register the identifiers

At <https://developer.apple.com/account/resources/identifiers/list>:

| What | Identifier |
|---|---|
| App ID | `com.drivelayer.app` |
| App ID (widget extension) | `com.drivelayer.app.widgets` |
| App Group | `group.com.drivelayer.app` |

The App Group is not optional. It is how the widgets read the snapshot the app
publishes; without it the widgets show placeholder data forever.

On `com.drivelayer.app`, enable these capabilities:

- **App Groups** — select `group.com.drivelayer.app`
- **WeatherKit** — needed for current and route weather
- **Background Modes** — location and Bluetooth are declared in `Info.plist`

On `com.drivelayer.app.widgets`, enable **App Groups** and select the same group.

Do **not** enable CarPlay yet. See §6.

## 3. Create the app record

At <https://appstoreconnect.apple.com/apps>, create a new iOS app using bundle ID
`com.drivelayer.app`. The name has to be unique across the App Store; if
"DriveLayer" is taken, anything works — it is only the listing name, and TestFlight
shows it to you alone.

## 4. Create the six secrets

In the repository: **Settings → Secrets and variables → Actions → New repository
secret**.

| Secret | Where it comes from |
|---|---|
| `APPLE_TEAM_ID` | <https://developer.apple.com/account> → Membership. Ten characters, e.g. `A1B2C3D4E5`. |
| `BUILD_CERTIFICATE_BASE64` | An **Apple Distribution** certificate exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy`. |
| `P12_PASSWORD` | The password you set when exporting that `.p12`. |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key with **App Manager** access. The Key ID is shown in the list. |
| `APP_STORE_CONNECT_ISSUER_ID` | On the same page, above the key list. A UUID. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The `.p8` file that key downloads — **once only**. Paste its whole contents, `-----BEGIN PRIVATE KEY-----` line included. |

Creating the distribution certificate is the only step that wants a Mac (Keychain
Access → Certificate Assistant → Request a Certificate from a Certificate
Authority, then upload the request at
<https://developer.apple.com/account/resources/certificates/add>).

**No Mac? Use the appendix.** Everything above can be done from a browser, and
the certificate can be made with OpenSSL on Linux or Windows — see
[Appendix A](#appendix-a-making-the-certificate-without-a-mac). Nothing else in
this document changes.

## 5. Press the button

**Actions → TestFlight → Run workflow.**

Leave both inputs alone the first time. The build number defaults to the workflow
run number, which always increases — App Store Connect rejects a build number it
has seen before, and that is the most common way a first upload fails.

It takes about fifteen minutes. Apple then processes the build for another five
to fifteen. When it appears in TestFlight, install it from the TestFlight app on
your phone.

**Internal testers need no review.** Add yourself as an internal tester and the
build is installable as soon as processing finishes. External testers need a
review pass, which is where background location will draw questions — you do not
need external testers to test your own car.

## 6. CarPlay, honestly

**CarPlay will not work in this build**, and adding the entitlement to the
repository would make signing fail rather than make CarPlay appear.

Apple grants the driving-task entitlement by application, at
<https://developer.apple.com/carplay/>. Once granted, `docs/CARPLAY.md` has the
two edits — an entitlement key and a scene declaration — and the code behind them
already compiles.

Until then: the phone app is fully usable in the car. Mount the phone, connect the
adapter, and Drive Mode does what CarPlay would, on the screen you have.

## 7. What to expect on the first real drive

This is the first time any of this meets hardware, so treat it as a shakedown
rather than a demo.

**Set up before you drive:**

- Pair the OBD-II adapter in **Settings → Adapter**, with the ignition on.
- Grant location **Always** if you want drives to record without opening the app.
  While Using is enough for a drive you start by hand.
- No adapter yet? **Settings → Adapter → Use the simulator** exercises the whole
  app — trips, insights, widgets — against a simulated car.

**What is most likely to go wrong**, since nothing here has met a real adapter:

- Cheap ELM327 clones lie about what they support, respond slowly, or drop the
  connection under load. The parser is tested hard against malformed responses,
  but no test replaces a real one.
- The Harrier's OBD support is unverified. **Settings → Capability levels** shows
  what your car actually reports versus what DriveLayer can interpret — that
  screen is the single most useful thing to send me after the first drive.
- Weather stays "not configured" until WeatherKit is enabled on the App ID and a
  build carrying that capability is installed.
- Baselines need several drives before insights say anything specific. A first
  drive reporting little is the design working, not a fault.

**Worth capturing:** the Capability levels screen, anything in the Debug Center
that looks wrong, and any number that seems implausible. A wrong number that
looks confident is the most important bug class in this app.

---

## Appendix A. Making the certificate without a Mac

Keychain Access is the usual way to produce an Apple Distribution certificate, but
nothing about the format requires it. A certificate is a signed public key, and
OpenSSL can make the request and assemble the result just as well. This route
works on Linux, on Windows via WSL, and on a Mac if you would rather not use
Keychain Access.

You need OpenSSL 3.x (`openssl version`) and about ten minutes.

### A1. Make a private key and a signing request

```sh
openssl genrsa -out private.key 2048

openssl req -new -key private.key \
  -out CertificateSigningRequest.certSigningRequest \
  -subj "/emailAddress=you@example.com/CN=Your Name/C=IN"
```

Use your own email and name. Apple reads the public key out of the request and
largely ignores the rest, so these fields are for your own recognition later.

**`private.key` is the secret.** Apple never sees it and cannot reissue it. Lose
it and the certificate Apple gives you back is inert — you would have to revoke
and start again. Keep it somewhere you will still have next year, and do not
commit it.

### A2. Have Apple sign it

At <https://developer.apple.com/account/resources/certificates/add>:

1. Choose **Apple Distribution**. Not "Apple Development" — a development
   certificate cannot sign a TestFlight upload, and the failure appears late, at
   the export step.
2. Upload `CertificateSigningRequest.certSigningRequest`.
3. Download the certificate Apple generates. It arrives as `distribution.cer`,
   in DER encoding.

### A3. Combine the certificate with your key

Apple returns only the certificate. The `.p12` the workflow wants is the
certificate *and* the private key in one encrypted file, which is why this step
happens on your machine rather than theirs.

```sh
openssl x509 -inform DER -in distribution.cer -outform PEM -out distribution.pem

openssl pkcs12 -export \
  -inkey private.key \
  -in distribution.pem \
  -out certificate.p12 \
  -passout pass:CHOOSE_A_PASSWORD
```

That password is what goes into the `P12_PASSWORD` secret. Choose a real one —
it is the only thing protecting your signing key inside the repository secret.

Check the result carries both halves before going further:

```sh
openssl pkcs12 -in certificate.p12 -passin pass:CHOOSE_A_PASSWORD -nodes -noout -info
```

It should print a `PKCS7 Encrypted data:` line and no error. To confirm both the
key and the certificate are inside, this must print `2`:

```sh
openssl pkcs12 -in certificate.p12 -passin pass:CHOOSE_A_PASSWORD -nodes 2>/dev/null \
  | grep -cE 'BEGIN (PRIVATE KEY|CERTIFICATE)'
```

A `1` means the export picked up the certificate but not the key, and signing
will fail on the runner with a message about no identity being found.

### A4. Base64 it for the secret

GitHub secrets hold text, so the binary `.p12` is base64-encoded:

```sh
base64 -w 0 certificate.p12 > certificate.p12.base64   # Linux
base64 -i certificate.p12 -o certificate.p12.base64    # macOS
```

Paste the whole contents of `certificate.p12.base64` into
`BUILD_CERTIFICATE_BASE64`. The workflow decodes it with `base64 --decode`, which
recovers the file byte for byte; wrapped or unwrapped lines both decode, so do
not worry about the line breaks.

### If the runner rejects the `.p12`

OpenSSL 3 encrypts a `.p12` with AES-256-CBC and a SHA-256 MAC by default.
Older Apple tooling only understands the original, much weaker RC2 encryption.
If the **Import the signing certificate** step fails with a MAC or decryption
error rather than a password error, rebuild the file with `-legacy`:

```sh
openssl pkcs12 -export -legacy \
  -inkey private.key -in distribution.pem \
  -out certificate.p12 -passout pass:CHOOSE_A_PASSWORD
```

then base64 it again and replace the secret. Try the default first — `-legacy`
downgrades the encryption protecting your key, so it is worth using only if the
modern format is actually refused.

### What I could and could not verify

I ran every command in A1–A4 on OpenSSL 3.0.13 and confirmed the chain end to
end: the request is well formed, the DER-to-PEM conversion and the `.p12`
assembly succeed, and the base64 round trip through the workflow's own
`base64 --decode` returns a byte-identical file that still opens with its
password and still contains both the key and the certificate.

What I could not test is the half that needs Apple: signing with a real
distribution certificate, on a real macOS runner. Two things are therefore worth
knowing as likely first-run failures:

- **A development certificate instead of a distribution one.** It imports
  cleanly and fails later, during export, which makes it look like an export
  problem. Re-read A2 step 1 before debugging anything else.
- **A missing intermediate certificate.** `codesign` builds a chain from your
  certificate up through Apple's Worldwide Developer Relations intermediate.
  GitHub's macOS runners ship with it installed, so this normally resolves
  itself; if signing fails complaining the certificate is untrusted or has no
  valid chain, that is the cause rather than anything in your `.p12`.
