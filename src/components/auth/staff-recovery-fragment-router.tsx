"use client";

import { useEffect } from "react";
import { resolveStaffRecoveryRedirect } from "@/lib/staff-invitation";

export function StaffRecoveryFragmentRouter() {
  useEffect(() => {
    const target = resolveStaffRecoveryRedirect(window.location.pathname, window.location.hash);
    if (target) window.location.replace(target);
  }, []);
  return null;
}
