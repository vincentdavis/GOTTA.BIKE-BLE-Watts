# Website: ble.gotta.bike

The product site for GOTTA.BIKE: BLE Watts: home page (features,
screenshots, downloads), Support, Privacy Policy and Terms of Use. Plain
HTML and one stylesheet, no build step, no JavaScript, no cookies, no
external fonts or trackers. It is hosted on **Cloudflare Pages** at
**https://ble.gotta.bike**.

| Page | Source | URL | Used for |
|---|---|---|---|
| Home | `index.html` | `/` | App Store Marketing URL, Play "Website" |
| Support | `support.html` | `/support` | App Store **Support URL** (required) |
| Privacy Policy | `privacy.html` | `/privacy` | App Store **Privacy Policy URL**, Play App content › Privacy policy, the in-app link |
| Terms of Use | `terms.html` | `/terms` | Linked from the site; optional custom EULA reference |

Cloudflare Pages serves `privacy.html` at `/privacy` (it strips `.html`),
so give the stores the extensionless URLs above. `_redirects` adds
`/privacy-policy`, `/tos`, `/mac` (latest Mac DMG) and `/releases`.

## Before the first deploy: fill in the placeholders

Placeholders are in square brackets and highlighted yellow on the page.
`tool/check_website.sh` lists them and fails while any remain (it is the
Cloudflare build command, so a deploy can't go out with them).

| Placeholder | Where | Notes |
|---|---|---|
| `[CONTACT EMAIL]` | privacy, terms, support | Shown publicly; Apple's Support URL must lead to real contact info. A role address such as `support@gotta.bike` works well. |
| `[DEVELOPER LEGAL NAME]` | every footer, privacy, terms | Must match the seller / developer name on App Store Connect and Play Console. |
| `[POSTAL ADDRESS]` | privacy | Optional for a personal developer account; delete the line if you don't want it. |
| `[EFFECTIVE DATE]` | privacy, terms | The date you publish. |
| `[GOVERNING LAW JURISDICTION]` | terms | For example "the State of Colorado, USA". |
| `[RESPONSE TIME, e.g. 3 business days]` | support | Or delete that sentence. |
| `[APP STORE URL]` | index | `https://apps.apple.com/app/id<APPLE ID>` once App Store Connect assigns the Apple ID. |

Also, when each store build goes live, delete its "Coming soon" line in the
Download section of `index.html`. The Google Play link
(`ble.make.bike.gotta`) and the Mac link
(`releases/latest/download/gotta-bike-ble-watts-macos.dmg`) are already
the final URLs, but they only work once the app is published there. The
Windows button points at the latest GitHub release until the Windows build
has a stable asset name.

## Preview locally

Open `website/index.html` in a browser, or serve the folder:

```bash
python3 -m http.server -d website 8000   # http://localhost:8000
```

## Deploy on Cloudflare Pages (one-time setup)

1. Cloudflare dashboard › **Workers & Pages** › Create › **Pages** ›
   Connect to Git › pick `vincentdavis/GOTTA.BIKE-BLE-Watts`.
2. Settings:
   - Production branch: `main`
   - Framework preset: **None**
   - Build command: `bash tool/check_website.sh`
   - Build output directory: `website`
   - Root directory: leave empty (repo root)
3. Build watch paths (Settings › Builds): include `website/*` and
   `tool/check_website.sh`, so app-only commits don't redeploy the site.
4. **Custom domains** › Set up a domain › `ble.gotta.bike`. If `gotta.bike`
   is on Cloudflare DNS, it adds the CNAME for you; otherwise add a CNAME
   `ble` → `<project>.pages.dev` at your DNS host.
5. Pull requests get preview deployments automatically, but the build
   check also runs there, so previews fail until the placeholders are
   filled in.

`_headers` sets a strict Content-Security-Policy (no scripts, no inline
styles, same-origin images and CSS only) plus HSTS. If you add analytics or
an embed later, update the CSP, and the privacy policy's "This website"
paragraph.

## Screenshots

`assets/screenshots/*.png` (1080×2340) are rendered from the app's real
widgets with fake Bluetooth, so they always match the current UI:

```bash
flutter test tool/screenshots/capture_test.dart --update-goldens
```

They avoid third-party names and logos, so they can also be used for the
store listings. iPad, Mac and Windows store screenshots need their own
sizes; take those on the device or simulator.

## Keeping it accurate

- The privacy policy is the single copy for every platform
  (`store/privacy-policy.md` just points here). Update it, and its
  effective date, whenever permissions, dependencies or features change:
  re-check the Android permission table against the merged release
  manifest and the Apple section against `ios/Runner/PrivacyInfo.xcprivacy`.
- Feature text on the home page mirrors `README.md` and
  `store/listing.md`. Don't add claims the app can't back up (see the
  "Where each claim comes from" table in `store/listing.md`).
- Requirements: iOS / iPadOS 27+, macOS 27+ (Apple silicon) and Android
  7.0+ (`minSdk 24`) as of this writing. Update them if the platform
  threads change the minimums.
