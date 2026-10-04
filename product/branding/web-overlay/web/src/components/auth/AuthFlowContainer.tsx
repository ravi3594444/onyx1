"use client";

import Link from "next/link";
import { useTranslations } from "next-intl";
import { useSettings } from "@/lib/settings/hooks";
import BrandMark from "@/components/branding/BrandMark";
import { AUTH_THEME, BRANDING } from "@/lib/branding";

// Upstream layout and flow, styled after the agency site: black page, a hero
// with the mark, the name and the tagline, then the upstream card.
export default function AuthFlowContainer({
  children,
  authState,
  footerContent,
}: {
  children: React.ReactNode;
  authState?: "signup" | "login" | "join";
  footerContent?: React.ReactNode;
}) {
  const t = useTranslations("auth.flowContainer");
  const { appName, logoUrl } = useSettings();
  const linkClassName =
    "underline underline-offset-4 transition-colors duration-200";
  return (
    <div
      className="p-4 flex flex-col items-center justify-center min-h-screen"
      style={{ backgroundColor: AUTH_THEME.pageBackground }}
    >
      <div className="w-full max-w-md flex flex-col gap-6">
        <div
          className="flex flex-col items-start gap-4"
          style={{ color: AUTH_THEME.heroText }}
        >
          <div className="flex items-center gap-3">
            {/* logo_display_style only governs the sidebar; auth pages always show
                the logo mark (custom when uploaded, 22nd X AI otherwise) */}
            {logoUrl ? (
              <div
                className="aspect-square rounded-full overflow-hidden relative"
                style={{ height: 44 }}
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  alt={t("logo.alt")}
                  src={logoUrl}
                  className="object-cover object-center w-full h-full"
                />
              </div>
            ) : (
              <BrandMark size={44} alt={t("logo.alt")} />
            )}
            <span className="font-heading-h3">{appName}</span>
          </div>
          <h1 className="text-3xl md:text-4xl font-semibold tracking-tight leading-tight">
            {BRANDING.TAGLINE}
          </h1>
          <p
            className="font-main-ui-body"
            style={{ color: AUTH_THEME.heroMuted }}
          >
            {BRANDING.HERO_SUBLINE}
          </p>
        </div>
        <div
          className="w-full flex items-start flex-col bg-background-tint-00 rounded-16 shadow-lg shadow-box-02 p-6"
          style={{ border: `1px solid ${AUTH_THEME.cardBorder}` }}
        >
          <div className="w-full">{children}</div>
        </div>
      </div>
      {authState === "login" && (
        <div
          className="text-sm mt-6 text-center w-full mainUiBody mx-auto"
          style={{ color: AUTH_THEME.heroMuted }}
        >
          {footerContent ?? (
            <>
              <span>{t("signupPrompt.text", { appName })}</span>{" "}
              <Link
                href="/auth/signup"
                className={linkClassName}
                style={{ color: AUTH_THEME.linkColor }}
              >
                {t("createAccountLink.label")}
              </Link>
            </>
          )}
        </div>
      )}
      {authState === "signup" && (
        <div
          className="text-sm mt-6 text-center w-full mainUiBody mx-auto"
          style={{ color: AUTH_THEME.heroMuted }}
        >
          {t("signinPrompt.text")}{" "}
          <Link
            href="/auth/login?autoRedirectToSignup=false"
            className={linkClassName}
            style={{ color: AUTH_THEME.linkColor }}
          >
            {t("signInLink.label")}
          </Link>
        </div>
      )}
    </div>
  );
}
