import { useEffect, useState } from "react";
import { useI18n } from "../../i18n";
import { modMonogram } from "../../lib/format";

interface ModCoverProps {
  name: string;
  src?: string | null;
  className?: string;
  imageClassName?: string;
  decorative?: boolean;
}

export function ModCover({
  name,
  src,
  className = "",
  imageClassName = "",
  decorative = false,
}: ModCoverProps) {
  const { t } = useI18n();
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    setFailed(false);
  }, [src]);

  const showImage = Boolean(src) && !failed;
  return (
    <span className={`mod-cover ${className}`.trim()} aria-hidden={decorative || undefined}>
      {showImage ? (
        <img
          className={`mod-cover-image ${imageClassName}`.trim()}
          src={src ?? undefined}
          alt={decorative ? "" : t("common.modCover", { name })}
          loading="lazy"
          decoding="async"
          referrerPolicy="no-referrer"
          onError={() => setFailed(true)}
        />
      ) : (
        <span className="mod-cover-fallback" aria-hidden="true">
          {modMonogram(name)}
        </span>
      )}
    </span>
  );
}
