import { NextResponse } from "next/server";
import { parentOtpV3PreparationSchema } from "@/lib/mail-v2-contract";
import {
  parentOtpSupportActionResponseSchema,
  parentOtpSupportActionSchema,
} from "@/lib/parent-otp-support-contract";
import { getServerEnv } from "@/lib/env";
import {
  deriveParentCode,
  generateParentChallengeId,
  hashParentSecret,
} from "@/server/auth/parent";
import { requireStaffRole } from "@/server/auth/staff";
import { deliverPreparedParentOtpV3 } from "@/server/email/otp-delivery";
import {
  BODY_POLICIES,
  guardBrowserMutation,
  readJsonRequest,
} from "@/server/security/route-guard";
import { getSupabaseAdminClient } from "@/server/supabase/admin";
import { getSupabaseServerClient } from "@/server/supabase/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const privateHeaders = { "Cache-Control": "private, no-store, max-age=0" };

function fail(message: string, status: number) {
  return NextResponse.json(
    { error: message },
    { status, headers: privateHeaders },
  );
}

export async function POST(request: Request) {
  const guarded = guardBrowserMutation(request, {
    body: BODY_POLICIES.jsonTiny,
  });
  if (guarded) return guarded;
  try {
    await requireStaffRole(["beheerder"]);
    const body = await readJsonRequest(request, BODY_POLICIES.jsonTiny);
    if (!body.ok) return body.response;
    const parsed = parentOtpSupportActionSchema.safeParse(body.data);
    if (!parsed.success) {
      return fail("Controleer het ouderaccount en de gekozen actie.", 400);
    }
    const [supabase, admin] = await Promise.all([
      getSupabaseServerClient(),
      Promise.resolve(getSupabaseAdminClient()),
    ]);
    if (!supabase || !admin) {
      return fail("De verificatiemail is tijdelijk niet beschikbaar.", 503);
    }

    const proposedChallengeId = generateParentChallengeId();
    const codeHash = hashParentSecret(
      deriveParentCode(proposedChallengeId),
    );
    const { data, error } = await supabase.schema("app").rpc(
      "prepare_parent_otp_support_delivery_v1",
      {
        p_parent_account_id: parsed.data.parentAccountId,
        p_mode: parsed.data.mode,
        p_challenge_id: proposedChallengeId,
        p_code_hash: codeHash,
      },
    );
    if (error) {
      if (error.code === "42501") {
        return fail("Alleen een beheerder met MFA kan dit uitvoeren.", 403);
      }
      if (error.code === "P0001") {
        return fail("Te veel supportverzoeken. Probeer het later opnieuw.", 429);
      }
      if (error.code === "P0002") {
        return fail("Dit ouderaccount heeft geen actieve portaltoegang.", 404);
      }
      if (error.code === "22023") {
        return fail("Het supportverzoek is niet geldig.", 400);
      }
      return fail("De verificatiemail kon niet veilig worden voorbereid.", 502);
    }
    const preparation = parentOtpV3PreparationSchema.safeParse(data);
    if (!preparation.success || preparation.data.status !== "prepared") {
      return fail("De verificatiemail kan momenteel niet worden verstuurd.", 409);
    }

    const { data: recipient, error: recipientError } = await admin
      .schema("app")
      .rpc("resolve_parent_otp_delivery_recipient_v1", {
        p_delivery_attempt_id: preparation.data.deliveryAttemptId,
      });
    if (
      recipientError
      || typeof recipient !== "string"
      || recipient.trim().length < 3
    ) {
      return fail("Het geregistreerde loginadres kon niet veilig worden bepaald.", 502);
    }

    const delivery = await deliverPreparedParentOtpV3(
      admin,
      preparation.data,
      recipient,
      getServerEnv().APP_BASE_URL,
    );
    const response = parentOtpSupportActionResponseSchema.parse({
      outcome: delivery.outcome,
      reused: preparation.data.reused,
      expiresAt: preparation.data.expiresAt,
    });
    return NextResponse.json(response, {
      status: 200,
      headers: privateHeaders,
    });
  } catch (error) {
    if (
      error instanceof Error
      && error.message === "STAFF_AUTHORIZATION_REQUIRED"
    ) {
      return fail("Alleen een beheerder kan ouderlogin ondersteunen.", 403);
    }
    return fail("De verificatiemail kon niet worden verwerkt.", 500);
  }
}
