export type EmailDeliveryResult =
  | {
      /**
       * Backwards-compatible transport flag. This means that the selected
       * provider accepted the message, not that the receiving mailbox
       * delivered it.
       */
      delivered: true;
      deliveryState?: "provider_accepted";
      providerMessageId: string;
      providerCode?: string;
      enhancedStatusCode?: string;
    }
  | {
      delivered: false;
      reason: "disabled" | "configuration_error" | "provider_rejected" | "delivery_uncertain";
      outcome: "retry" | "failed" | "delivery_uncertain";
      deliveryState?:
        | "temporary_failure"
        | "permanent_rejection"
        | "delivery_uncertain"
        | "configuration_error"
        | "disabled";
      providerCode?: string;
      enhancedStatusCode?: string;
      recipientFailure?: boolean;
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
