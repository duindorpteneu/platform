import { PaymentWorkspace } from "@/components/payments/payment-workspace";
import { getPaymentWorkspace } from "@/server/payments/workspace";

export const dynamic = "force-dynamic";

export default async function PaymentsPage() {
  return <PaymentWorkspace workspace={await getPaymentWorkspace()} />;
}
