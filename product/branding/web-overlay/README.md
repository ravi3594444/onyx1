# 22nd X AI web overlay for Onyx v4.8.4

`build-web-image.sh` exports `web/` from the upstream tag, copies every file under
`web/` here over the same path, then runs `docker build -f web/Dockerfile`. Nothing
outside `web/` changes. `backend/`, `backend/ee`, `web/src/ee` and `web/src/app/ee`
stay as upstream ships them, so license enforcement is intact.

Branding values live in one file, `web/src/lib/branding.ts`. The replaced files
import from it. The licensed enterprise settings (application name, custom logo,
greeting, login subtitle) still win when an admin sets them; the overlay changes
only the fallbacks that upstream hard-codes as "Onyx".

## New files

| Path | Why |
| --- | --- |
| `web/src/lib/branding.ts` | Name, tagline, hero text, accent, logo path, pre-login colours, English text overrides |
| `web/src/components/branding/BrandMark.tsx` | The 22nd X AI mark, rendered like an uploaded enterprise logo |
| `web/public/axi-logo.png` | Copy of `product/branding/logo.png`, served at `/axi-logo.png` |

## Replaced upstream files

| Path | Why |
| --- | --- |
| `web/public/onyx.ico` | Favicon: ICO (48/32/16) made from `logo.png`; the file name upstream code expects |
| `web/src/app/layout.tsx` | Browser title from `fetchAppName()` (enterprise name, else the brand name) |
| `web/src/lib/settings/hooks.ts` | `appName` fallback for client components |
| `web/src/lib/settings/svcSS.ts` | `appName` fallback for server-side settings |
| `web/src/lib/app/svcSS.ts` | `fetchAppName()` fallback (admin title, signup text) |
| `web/src/lib/app/components.tsx` | Sidebar `Logo`: brand mark and name instead of the Onyx mark and wordmark |
| `web/src/components/auth/AuthFlowContainer.tsx` | Login, signup and join shell: black page, hero with mark, name and tagline, accent links |
| `web/src/refresh-components/avatars/AgentAvatar.tsx` | Default agent avatar (chat greeting) shows the brand mark |
| `web/src/components/errorPages/ErrorPageLayout.tsx` | Error and license pages show the brand mark and name |
| `web/src/i18n/request.ts` | Merges `BRANDING_MESSAGES` over the English catalog (login subtitle, one greeting) |
| `web/lib/shared/tokens/semantic-light.json` | `theme-primary-04/05/06` and `action-text-link-05` set to the accent (`#3656e8`, hover `#4f6cee`, active `#2a46c4`) |
| `web/lib/shared/tokens/semantic-dark.json` | Same tokens as light tints (`#8ea0f2`, `#a9b7f5`, `#7085ee`) so dark text stays readable on them |

Contrast: white text on `#3656e8` is 5.7:1, on `#4f6cee` 4.5:1; near-black text on
`#8ea0f2` is about 8:1. All meet WCAG AA for normal text.

## Left as upstream

- "Powered by Onyx" under the sidebar name. The code and the `hide_onyx_branding`
  setting are unchanged.
- The "Onyx <version>" row in the account menu, "Help & FAQ" to docs.onyx.app, the
  Onyx owner label on built-in agents, support addresses on license pages.
- Translated catalogs (`de`, `es`, ...). The English overrides are the fallback
  base for them, but a translated entry still wins.
- Fonts. The site uses Inter and Manrope; the app keeps Hanken Grotesk.
- `web/public/logo*.png`, `logo.svg`, `logotype*.png`: no code reads them.

## Licence notes

- Onyx is MIT licensed outside the `ee` directories (`LICENSE` at the repo root).
  The MIT notice stays in the image: `LICENSE` is not under `web/` and is not
  copied, so keep a copy of the upstream `LICENSE` with any redistribution of the
  image. The replaced files keep their upstream content except the listed edits.
- `web/src/ee` and `web/src/app/ee` carry the Onyx Enterprise License. The overlay
  does not touch them. The image still contains them, as the upstream image does;
  the features stay gated by the backend license check.
- `web/lib/opal` and `web/lib/shared` are MIT (`web/lib/shared/package.json`).
