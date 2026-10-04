import { BRANDING } from "@/lib/branding";
import { cn } from "@opal/utils";

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
