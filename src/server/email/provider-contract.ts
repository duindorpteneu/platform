export type EmailDeliveryResult =
  | { delivered: true; providerMessageId: string }
  | {
      delivered: false;
      reason: "disabled" | "configuration_error" | "provider_rejected" | "delivery_uncertain";
      outcome: "retry" | "failed" | "delivery_uncertain";
      providerCode?: string;
    };

export type EmailMessage = {
  recipientEmail: string;
  subject: string;
  text: string;
  html: string;
  fromName: string;
  fromEmail: string;
  replyToEmail: string;
  headers?: Record<string, string>;
};
