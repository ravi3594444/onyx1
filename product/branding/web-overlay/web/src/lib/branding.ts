// 22nd X AI defaults for the MIT-covered frontend. They replace only the
// upstream fallbacks ("Onyx", the Onyx mark, the login subtitle). The
// licensed enterprise settings (application_name, custom logo, greeting,
// login subtitle) still win when an admin sets them.
export const BRANDING = {
  NAME: "22nd X AI",
  TAGLINE: "More growth. Less busywork.",
  HERO_SUBLINE: "AI automation agency. Websites. Growth.",
  LOGIN_SUBTITLE: "Sign in to continue.",
  // Also set as theme-primary-* and action-text-link-05 in
  // lib/shared/tokens/semantic-{light,dark}.json.
  ACCENT: "#3656e8",
  // Served from web/public (see the overlay README).
  LOGO_SRC: "/axi-logo.png",
} as const;

// Pre-login screens (login, signup, join). Values come from the agency site:
// black page, white text, muted grey, ink for borders, accent for links.
export const AUTH_THEME = {
  pageBackground: "#000000",
  heroText: "#ffffff",
  heroMuted: "#8e8e8e",
  cardBorder: "#171a23",
  linkColor: BRANDING.ACCENT,
} as const;

// English catalog entries that replace the upstream text. Merged over
// src/i18n/messages/en.json in src/i18n/request.ts.
export const BRANDING_MESSAGES = {
  auth: { login: { welcomeSubtitle: { text: BRANDING.LOGIN_SUBTITLE } } },
  chat: { welcome: { greeting: { startText: BRANDING.TAGLINE } } },
};
