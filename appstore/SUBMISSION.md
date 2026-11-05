# Mac App Store submission package

## Read this first: this build cannot ship on the Mac App Store

Mac App Store apps must run inside **App Sandbox** (App Review Guideline 2.4.5). This app's
core action is mounting a filesystem, and the sandbox forbids it. That is not a theory — it
was measured on this machine with the shipping binary:

| Build | Result |
|---|---|
| Normal (as shipped) | mounts `/Volumes/HERO13 Black` |
| Same binary, `com.apple.security.app-sandbox` + network client/server entitlements | camera found, WebDAV bridge started, `mount_webdav` → **exit 22 (EINVAL)**, nothing mounted |

The sandboxed process is also containerised (`~/Library/Containers/com.gopromount.goprocard/`)
and cannot create mount points in `/Volumes`.

Two further review blockers, independent of the sandbox:

1. **Trademark (Guideline 5.2.1).** “GoPro” is a registered trademark. An app name, subtitle,
   icon or keyword set that uses it is routinely rejected without written permission from
   GoPro. The metadata below therefore uses the neutral name **CamCard**; “works with GoPro”
   belongs in the description only, and even that is safer as “works with popular action cams”.
2. **Hardware dependency (Guideline 2.1).** Reviewers do not own a GoPro. An app whose entire
   function requires a specific camera is hard to approve; you would need to supply
   reproduction steps, a demo mode, and likely a video.

**In-app purchase** also needs something this environment cannot create: an App Store Connect
record, a real Apple Developer account, and a product ID that StoreKit can fetch. The code is
in `Sources/Store.swift`; the product itself must be created by you.

---

## Option A — Direct distribution (recommended, works today)

No sandbox, the app behaves exactly as it does now.

* Sign with a **Developer ID Application** certificate.
* **Notarize** with `notarytool` and staple the ticket.
* Ship a signed **DMG**.
* Charge $10 with a licence key from a merchant of record (Lemon Squeezy, Paddle, Gumroad —
  they handle VAT and are the seller of record). The app checks the key once and stores it.

This is the only route where the product you already have can be sold as-is. Roughly a day of
work plus a $99/year Apple Developer membership and a merchant account.

## Option B — App Store version (possible, but a different product)

Apple's supported way to show remote files in Finder without mounting is a
**File Provider extension** (`NSFileProviderReplicatedExtension`) — the mechanism Dropbox,
Google Drive and OneDrive use. It is sandbox-friendly and App Store-legal.

What changes:

| | Today (mount) | File Provider |
|---|---|---|
| Where it appears | `/Volumes/HERO13 Black`, Desktop icon | Finder sidebar location, no disk |
| Copy behaviour | kernel-level reads, any app | materialised per file on open |
| Sandbox | impossible | required |
| Entitlement | none | `com.apple.developer.fileprovider.*`, granted by Apple on request |

That is a substantial rewrite (enumeration, item fetching, change tracking) plus an entitlement
request to Apple. Worth doing only if App Store distribution is the goal in itself.

---

## Assets in this package

| Path | Use |
|---|---|
| `icon/icon_1024.png` | App Store icon (1024×1024, no alpha, no rounding) |
| `../Resources/AppIcon.icns` | icon inside the `.app` |
| `screenshots/01-finder-drive.png` | 1280×800 screenshot |
| `screenshots/02-copy.png` | 1280×800 screenshot |
| `screenshots/03-menu-bar.png` | 1280×800 screenshot |
| `privacy-policy.md` | ready to host |
| `SUBMISSION.md` | this file |

Regenerate everything with `python3 Tools/make_assets.py`.

## App Store Connect metadata (ready to paste)

**Name** (≤30)
```
CamCard
```

**Subtitle** (≤30)
```
Your action cam, as a drive
```

**Category** Utilities · **Age rating** 4+ · **Price** $9.99 (or free + IAP, see below)

**Promotional text** (≤170)
```
Plug in your action camera and it appears in Finder like an SD card. No reader, no import queue, no cloud.
```

**Description**
```
CamCard turns your action camera into an ordinary macOS volume.

Plug in the camera with its USB cable and a drive appears in Finder — open it, drag footage
out, and get on with your edit. No card reader, no import queue, no uploading your footage to
someone else's servers.

WHY IT EXISTS
Action cameras do not behave like USB flash drives. They speak MTP/PTP, which macOS cannot
mount, so the usual answer is a card reader or a third-party file manager. CamCard bridges the
camera's own USB interface to a filesystem macOS already understands.

FEATURES
• Appears as a normal drive in Finder and on the Desktop
• Mounts automatically when the camera is plugged in
• Byte-identical copies, verified against the camera
• Seek inside clips without downloading them first
• Read-only by design — recordings cannot be changed or deleted by accident
• Lives in the menu bar, starts at login, no Dock icon

REQUIREMENTS
• A recent action camera with USB “GoPro Connect”-style networking
• macOS 13 or newer
• Any USB data cable
```

**Keywords** (≤100)
```
action cam,mount,sd card,finder,usb,footage,dcim,media,import,gopro,drive,reader
```

**Support URL** `https://example.com/camcard/support` (you must host)
**Privacy Policy URL** `https://example.com/camcard/privacy` (host `privacy-policy.md`)

**Review notes**
```
CamCard mounts an action camera as a drive; it needs a supported camera attached by USB.
Our test camera is a GoPro HERO13 Black in USB “GoPro Connect” mode, which exposes a network
interface and an HTTP media API at 172.20.x.x:8080; CamCard bridges that to WebDAV and mounts
it with the system mount_webdav tool.

The app contacts no external services. It only talks to the camera on the local USB link and
to a loopback WebDAV server it hosts itself (127.0.0.1). A screen recording showing plug-in,
mount and copy is attached to this submission.
```

## In-app purchase configuration

| Field | Value |
|---|---|
| Reference name | GoPro Card Pro |
| Product ID | `com.gopromount.goprocard.pro` |
| Type | Non-consumable |
| Price | $9.99 (price point 11 / “Tier 10”) |
| Localisations | English (U.S.) |
| Review screenshot | `screenshots/01-finder-drive.png` |

The base app is free; the mount is unlocked by the purchase. That model needs the free tier to
be genuinely useful to pass review — otherwise ship it as a **paid app at $9.99** and skip the
IAP entirely (simpler, no StoreKit, no restore button).

To enable the paywall in code, build with `-DSTORE_ENFORCEMENT` (see `Store.enforcementEnabled`).

## What you must provide

- [ ] Apple Developer Program membership ($99/year)
- [ ] App Store Connect app record + the product ID above
- [ ] Signing: “Apple Distribution” certificate + provisioning profile (App Store),
      or “Developer ID Application” (direct distribution)
- [ ] Hosted support and privacy URLs
- [ ] Decision: paid $9.99 upfront, or free with a $9.99 IAP
- [ ] For Option B only: File Provider entitlement request to Apple

## Signing and notarisation (direct distribution)

```bash
codesign --force --deep --options runtime --timestamp \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" "GoPro Card.app"

ditto -c -k --keepParent "GoPro Card.app" GoProCard.zip
xcrun notarytool submit GoProCard.zip --keychain-profile AC_PASSWORD --wait
xcrun stapler staple "GoPro Card.app"
```
