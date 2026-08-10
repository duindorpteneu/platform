import { CircleDot, Package, Shirt } from "lucide-react";
import type { CatalogIconType } from "@/lib/catalog-order-contract";

export function ArticleIcon({
  type,
  className = "size-5",
}: {
  type: CatalogIconType;
  className?: string;
}) {
  const Icon = type === "shirt"
    ? Shirt
    : type === "circle-dot"
    ? CircleDot
    : Package;
  return <Icon className={className} strokeWidth={1.7} aria-hidden="true" />;
}
