export type WaitlistLine = {
  orderLineId: string;
  orderId: string;
  memberName: string;
  relationNumber: string | null;
  team: string | null;
  variantId: string;
  article: string;
  size: string;
  sku: string | null;
  quantity: number;
  paid: boolean;
  sizeValid: boolean;
  fifoAt: string | null;
  eligible: boolean;
  createdAt: string;
};

export type WaitlistGroup = {
  orderId: string;
  memberName: string;
  relationNumber: string | null;
  team: string | null;
  lines: WaitlistLine[];
};

export function groupWaitlistByOrder(lines: WaitlistLine[]): WaitlistGroup[] {
  const groups = new Map<string, WaitlistGroup>();

  for (const line of lines) {
    const existing = groups.get(line.orderId);
    if (existing) {
      existing.lines.push(line);
      continue;
    }

    groups.set(line.orderId, {
      orderId: line.orderId,
      memberName: line.memberName,
      relationNumber: line.relationNumber,
      team: line.team,
      lines: [line],
    });
  }

  return [...groups.values()];
}
