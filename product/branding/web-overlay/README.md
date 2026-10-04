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
| `web/src/lib/branding.ts` | Name, tagline, hero text, accent, logo path, chat footer, pre-login colours, English text overrides |
| `web/src/components/branding/BrandMark.tsx` | The 22nd X AI mark, rendered like an uploaded enterprise logo; `BrandIcon` for icon slots |
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
| `web/src/i18n/request.ts` | Merges `BRANDING_MESSAGES` over the English catalog (see "English text overrides") |
| `web/src/lib/app/hooks.ts` | Chat footer fallback: `BRANDING.FOOTER` instead of "[Onyx <version>](onyx.app) - Open Source AI Platform" |
| `web/src/sections/sidebar/AccountPopover.tsx` | Account menu version row: brand mark and "22nd X AI <version>" (the link to the changelog stays) |
| `web/src/sections/agents/AgentCard.tsx` | Owner of an agent without an owner (built-in agents): brand name instead of "Onyx" |
| `web/src/lib/agents/components/AgentViewerModal.tsx` | Same owner fallback in the agent details modal |
| `web/lib/shared/tokens/semantic-light.json` | `theme-primary-04/05/06` and `action-text-link-05` set to the accent (`#3656e8`, hover `#4f6cee`, active `#2a46c4`) |
| `web/lib/shared/tokens/semantic-dark.json` | Same tokens as light tints (`#8ea0f2`, `#a9b7f5`, `#7085ee`) so dark text stays readable on them |

Contrast: white text on `#3656e8` is 5.7:1, on `#4f6cee` 4.5:1; near-black text on
`#8ea0f2` is about 8:1. All meet WCAG AA for normal text.

## English text overrides

`BRANDING_MESSAGES` in `branding.ts` replaces these `en.json` entries. The ICU
placeholders stay the same.

| Keys | New text |
| --- | --- |
| `auth.login.welcomeSubtitle.text` | Login subtitle |
| `chat.welcome.greeting.startText` | Tagline as a greeting |
| `auth.createAccount.{createTeamOption,inviteOption,notFound}` | "Onyx team" and "access Onyx" use the brand name (cloud sign-up) |
| `admin.indexSettings.cloudDisabled.tooltip`, `admin.indexSettings.embeddingModel.cloudManaged.title` | "managed by Onyx Cloud" becomes "managed by 22nd X AI" (cloud mode) |
| `admin.modals.newTeam.tryOnyxButton.label` | "Try 22nd X AI while waiting" (cloud mode) |
| `admin.exportLogs.header.description` | "an Onyx support thread" becomes "a support thread" |
| `admin.security...allowedEmailDomains.placeholder`, `admin.ssoProviders...emailDomainsField.placeholder` | Example domain `example.com` instead of `onyx.app` |
| `admin.theme.appName.description` | 'replace "22nd X AI" in the UI' |
| `admin.analytics.slackChannelChart.*`, `admin.slackBots.*` (19 keys) | "OnyxBot" becomes "the Slack bot" (the bot name comes from the Slack app) |

## Left as upstream

- "Powered by Onyx" under the sidebar name (`common.logo.poweredBy.label`). It is
  the attribution: "Powered by 22nd X AI" under the name "22nd X AI" would claim
  authorship of the platform. The code, `hide_onyx_branding` and
  `NEXT_PUBLIC_DO_NOT_USE_TOGGLE_OFF_DANSWER_POWERED` are unchanged. The Theme
  page texts that describe this setting (`admin.theme.branding.*`) stay too.
- Docs and support: "Help & FAQ" to docs.onyx.app, the changelog link on the
  version row, `admin.slackBots.intro.docsPrompt`, `admin.theme.helpLink`,
  `admin.shared.liteModeNotice` (deployment guide), `support@onyx.app` in
  `auth.error.cloudSupportPrompt` and `common.errorPages.accessRestricted.billingAdminHint`.
- Licence and plan facts: `admin.billing.license.keyField`, `admin.groups.tokenLimits.disabledTooltip`,
  `sidebar.adminSidebar.{enterpriseOnly,businessOrEnterpriseOnly}`,
  `auth.impersonate.adminNote` (`@onyx.app` admins), `admin.externalApps.facts.providedByOnyx`.
- Craft ("Onyx Craft", `admin.craft*`, `craft.*`, the `onyxBranded` logo): Onyx
  enables it per deployment.
- "Created by Onyx" on built-in skills (`SkillPreviewModal`): Onyx wrote them.
- Admin-only names of upstream components: "Onyx Web Crawler" and the Onyx mark
  for built-in providers (web search, voice, tracing, index settings, LLM
  providers), the "Onyx" default tracing project, the "allow Onyx to index" texts
  in `lib/connectors/connectors.tsx`, the Onyx mark for `onyx.app` web results.
- `SvgOnyxOctagon`, the generic agent icon.
- The first-visit popup (`AppPopup`) shows the Onyx mark only when no licensed
  name or logo is set; it needs licensed popup content to show at all.
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
