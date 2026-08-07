const fallback = {
  primaryColor: "#17418B",
  secondaryColor: "#0B2E63",
  accentColor: "#2E69CC",
} as const;

type PublicBrandTokens = {
  primaryColor: string;
  secondaryColor: string;
  accentColor: string;
};

const colorPattern = /^#[0-9A-F]{6}$/;

function validTokens(value: unknown): value is PublicBrandTokens {
  if (!value || typeof value !== "object") return false;
  const candidate = value as Record<string, unknown>;
  return colorPattern.test(String(candidate.primaryColor ?? ""))
    && colorPattern.test(String(candidate.secondaryColor ?? ""))
    && colorPattern.test(String(candidate.accentColor ?? ""));
}

function rgb(hex: string) {
  return [
    Number.parseInt(hex.slice(1, 3), 16),
    Number.parseInt(hex.slice(3, 5), 16),
    Number.parseInt(hex.slice(5, 7), 16),
  ].join(" ");
}

export function brandCssVariables(tokens: PublicBrandTokens) {
  return {
    "--brand-500-rgb": rgb(tokens.accentColor),
    "--brand-700-rgb": rgb(tokens.primaryColor),
    "--brand-900-rgb": rgb(tokens.secondaryColor),
  };
}

export async function getPublishedBrandCssVariables() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim();
  if (!url || !key) return brandCssVariables(fallback);
  try {
    const response = await fetch(
      `${url}/rest/v1/rpc/get_public_brand_tokens_v1`,
      {
        method: "POST",
        cache: "no-store",
        signal: AbortSignal.timeout(1_500),
        headers: {
          apikey: key,
          Authorization: `Bearer ${key}`,
          "Content-Type": "application/json",
        },
        body: "{}",
      },
    );
    if (!response.ok) return brandCssVariables(fallback);
    const payload: unknown = await response.json();
    return brandCssVariables(validTokens(payload) ? payload : fallback);
  } catch {
    return brandCssVariables(fallback);
  }
}
