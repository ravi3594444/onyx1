import { BRANDING } from "@/lib/branding";
import { cn } from "@opal/utils";
import type { IconProps } from "@opal/types";

interface BrandMarkProps {
  size: number;
  className?: string;
  alt?: string;
}

// The 22nd X AI mark, rendered the same way as an uploaded enterprise logo.
export default function BrandMark({
  size,
  className,
  alt = "",
}: BrandMarkProps) {
  return (
    <div
      className={cn(
        "aspect-square rounded-full overflow-hidden relative shrink-0",
        className
      )}
      style={{ height: size, width: size }}
    >
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        alt={alt}
        src={BRANDING.LOGO_SRC}
        className="object-cover object-center w-full h-full"
      />
    </div>
  );
}

// The mark as an icon component, for slots that take an IconFunctionComponent.
// Those slots size the icon through `style` (width/height) or `size`.
export function BrandIcon({ size, className, style }: IconProps) {
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      alt=""
      src={BRANDING.LOGO_SRC}
      className={cn("shrink-0 rounded-full object-cover", className)}
      style={{ width: size, height: size, ...style }}
    />
  );
}
