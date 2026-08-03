"use client";

import { useLayoutEffect } from "react";

export function QrFragmentScrubber() {
  useLayoutEffect(() => {
    if (window.location.hash || window.location.search) {
      window.history.replaceState(window.history.state, "", "/qr");
    }
  }, []);
  return null;
}
