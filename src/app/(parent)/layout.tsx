import { ParentLiveChat } from "@/components/member/parent-live-chat";

export default function ParentLayout({ children }: { children: React.ReactNode }) {
  return (
    <>
      {children}
      <ParentLiveChat />
    </>
  );
}
