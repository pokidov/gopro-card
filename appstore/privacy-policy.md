# Privacy Policy — CamCard

_Last updated: 5 November 2026_

CamCard is a macOS app that makes an action camera appear as a drive in Finder.

## What the app collects

**Nothing.** CamCard has no analytics, no crash reporting, no advertising SDKs, no accounts,
and no servers of its own. It does not transmit any data off your Mac.

## What the app accesses

| Access | Why | Where it goes |
|---|---|---|
| The camera on your USB connection | Read the media list and file contents | Nowhere — processed locally |
| A loopback HTTP server on `127.0.0.1` | Lets macOS mount the camera as a volume | Bound to loopback only; not reachable from the network |
| `~/Library/Logs/GoProCard.log` | Diagnostics you can open from the menu | Stays on your Mac |

Camera files are read only when you open or copy them. The mounted volume is read-only; the
app never writes to the camera.

## Purchases

If you buy CamCard through the Mac App Store, Apple processes the transaction and CamCard
receives only a confirmation that the purchase exists. Apple's privacy policy covers that
transaction. CamCard does not receive your name, email, or payment details.

## Children

CamCard is not directed at children and collects no personal information from anyone.

## Changes

Any change to this policy will be published at this URL with a new date.

## Contact

privacy@example.com
