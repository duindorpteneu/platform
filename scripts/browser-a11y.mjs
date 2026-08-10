import AxeBuilder from "@axe-core/playwright";

const wcagTags = [
  "wcag2a",
  "wcag2aa",
  "wcag21a",
  "wcag21aa",
  "wcag22aa",
];

export async function assertNoAutomatedA11yViolations(page, label) {
  const result = await new AxeBuilder({ page })
    .withTags(wcagTags)
    .analyze();
  if (result.violations.length === 0) return;
  const safeParts = [];
  for (const violation of result.violations) {
    const firstTarget = violation.nodes[0]?.target[0];
    const elementShape = typeof firstTarget === "string"
      ? await page.locator(firstTarget).first().evaluate((element) => ({
        aria: Array.from(element.attributes)
          .map((attribute) => attribute.name)
          .filter((name) => name.startsWith("aria-"))
          .sort(),
        classes: element instanceof HTMLElement
          ? [...element.classList].sort()
          : [],
        color: getComputedStyle(element).color,
        backgroundColor: getComputedStyle(element).backgroundColor,
        role: element.getAttribute("role"),
        tag: element.tagName.toLowerCase(),
      })).catch(() => null)
      : null;
    const shape = elementShape
      ? [
          elementShape.tag,
          elementShape.role ?? "implicit",
          elementShape.aria.join("+") || "no-aria",
          elementShape.classes.join(".") || "no-class",
          elementShape.color,
          elementShape.backgroundColor,
        ].join(":")
      : "unknown-element";
    safeParts.push(
      `${violation.id}:${violation.impact ?? "unknown"}:${violation.nodes.length}:${shape}`,
    );
  }
  const safeSummary = safeParts.join(",");
  throw new Error(`A11Y_${label.toUpperCase()}_${safeSummary}`);
}

export async function assertKeyboardFocusVisible(page, label) {
  await page.locator("body").click({ position: { x: 1, y: 1 } });
  for (let attempt = 0; attempt < 12; attempt += 1) {
    await page.keyboard.press("Tab");
    const focus = await page.evaluate(() => {
      const element = document.activeElement;
      if (!(element instanceof HTMLElement) || element === document.body) {
        return null;
      }
      const bounds = element.getBoundingClientRect();
      return {
        focusVisible: element.matches(":focus-visible"),
        visible:
          bounds.width > 0
          && bounds.height > 0
          && bounds.bottom >= 0
          && bounds.right >= 0
          && bounds.top <= window.innerHeight
          && bounds.left <= window.innerWidth,
      };
    });
    if (focus?.focusVisible && focus.visible) return;
  }
  throw new Error(`A11Y_${label.toUpperCase()}_FOCUS_NOT_VISIBLE`);
}

export async function assertReducedMotionHonored(page, label) {
  await page.emulateMedia({ reducedMotion: "reduce" });
  try {
    const durations = await page.evaluate(() => {
      const probe = document.createElement("div");
      probe.className = "animate-spin transition-all duration-1000";
      probe.setAttribute("aria-hidden", "true");
      document.body.append(probe);
      const style = getComputedStyle(probe);
      const result = {
        animation: style.animationDuration,
        iterations: style.animationIterationCount,
        transition: style.transitionDuration,
      };
      probe.remove();
      return result;
    });
    const milliseconds = (value) => value.endsWith("ms")
      ? Number.parseFloat(value)
      : Number.parseFloat(value) * 1_000;
    if (
      milliseconds(durations.animation) > 0.01
      || milliseconds(durations.transition) > 0.01
      || durations.iterations !== "1"
    ) {
      throw new Error(`A11Y_${label.toUpperCase()}_REDUCED_MOTION_IGNORED`);
    }
  } finally {
    await page.emulateMedia({ reducedMotion: "no-preference" });
  }
}
