# 22nd X AI brand assets

Source: https://axi-solutions.vercel.app/, retrieved 3 October 2026.
The site calls the brand "22nd X AI" (page title, `og:site_name`, header and footer).

| File | Source | Use |
| --- | --- | --- |
| `logo.webp` | `assets/logo.webp` on the site, 192 x 192 | Original |
| `logo.png` | Lossless conversion of `logo.webp` | Onyx logo upload (accepts PNG or JPEG only) |
| `favicon.svg` | Inline favicon of the site | Reference for a future favicon |
| `enterprise-settings.json` | Our text | Payload for `PUT /api/admin/enterprise-settings` |
| `apply-branding.sh` | Our script | Uploads the logo, then applies the payload |

Brand values from the site's CSS: background `#000000`, text `#ffffff`, accent `#3656e8`,
ink `#171a23`, muted `#8e8e8e`. Fonts: Inter, Manrope. Tagline: "More growth. Less busywork."

## What the supported settings change

With a Business license, `apply-branding.sh` sets the app name, the logo (sidebar, login page,
favicon, default agent avatar), the login subtitle, the new-chat greeting and the footer text.

## Gaps that settings cannot close (Onyx v4.8.4)

| Gap | Where | Option |
| --- | --- | --- |
| Brand colours and fonts | No setting. Tokens in `web/lib/shared/tokens/semantic-*.json` (`theme-primary-*`) | Patch tokens and build our own web image, or keep the neutral Onyx theme. The brand is mostly black and white, so the neutral theme is close. |
| "Powered by Onyx" | `hide_onyx_branding` | Enterprise plan |
| Help link | `custom_help_link_*` | Enterprise plan |
| Onyx name in the account menu version row and "Help & FAQ" link | `web/src/sections/sidebar/AccountPopover.tsx` | No setting |
| Onyx wordmark, Discord link and support address on error and license pages | `web/src/components/errorPages/` | No setting |
| "Onyx" as owner of built-in agents | `web/src/sections/agents/AgentCard.tsx` | No setting |
| App domain | Not supplied | Owner input. Set `WEB_DOMAIN` and TLS on the VM. |

We made no source patches. A colour patch needs our own web image build and pipeline.
Decide on it after the licensed settings are in place.
