import React from "react";
import BrandMark from "@/components/branding/BrandMark";
import { BRANDING } from "@/lib/branding";

interface ErrorPageLayoutProps {
  children: React.ReactNode;
}

export default function ErrorPageLayout({ children }: ErrorPageLayoutProps) {
  return (
    <div className="flex flex-col items-center justify-center w-full h-screen gap-4">
      <div className="flex items-center gap-3 text-text-05">
        <BrandMark size={48} />
        <span className="font-heading-h2">{BRANDING.NAME}</span>
      </div>
      <div className="max-w-160 w-full border bg-background-neutral-00 shadow-box-02 rounded-16 p-6 flex flex-col gap-4">
        {children}
      </div>
    </div>
  );
}
