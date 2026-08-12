"use client";

import Link from "@tiptap/extension-link";
import { Node, mergeAttributes } from "@tiptap/core";
import { EditorContent, useEditor } from "@tiptap/react";
import StarterKit from "@tiptap/starter-kit";
import {
  Bold,
  Braces,
  Heading2,
  Heading3,
  Italic,
  Link2,
  List,
  ListOrdered,
  Rows3,
} from "lucide-react";
import { useEffect } from "react";
import type {
  MailProtectedNodeKey,
  MailShortcodeKey,
  MailTipTapDocument,
} from "@/lib/mail-v2-contract";

const protectedNodeLabels: Record<MailProtectedNodeKey, string> = {
  portal_route: "Portaalroute",
  otp_code: "OTP-code",
  otp_validity: "OTP-geldigheid",
  otp_warning: "OTP-waarschuwing",
  size_table: "Maattabel",
  size_action: "Maatbevestiging",
  payment_summary: "Betaalsamenvatting",
  payment_action: "Betaalknop",
  ready_items: "Afhaalklaar",
  stock_items: "Voorraadstatus",
  picked_up_items: "Nu afgehaald",
  remaining_items: "Nog te leveren",
  full_package: "Volledig pakket",
  pickup_location: "Afhaallocatie",
  pickup_qr: "Afhaal-QR",
  failure_reference: "Foutreferentie",
};

const ShortcodeNode = Node.create({
  name: "shortcode",
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,
  addAttributes() {
    return {
      key: {
        default: null,
        parseHTML: (element) => element.getAttribute("data-mail-shortcode"),
      },
    };
  },
  parseHTML() {
    return [{ tag: "span[data-mail-shortcode]" }];
  },
  renderHTML({ HTMLAttributes }) {
    const key = String(HTMLAttributes.key ?? "");
    return [
      "span",
      mergeAttributes({
        "data-mail-shortcode": key,
        class: "rounded bg-brand-50 px-1.5 py-0.5 font-mono text-[11px] font-semibold text-brand-700",
        contenteditable: "false",
      }),
      `{{${key}}}`,
    ];
  },
  renderText({ node }) {
    return `{{${String(node.attrs.key ?? "")}}}`;
  },
});

const ProtectedBlockNode = Node.create({
  name: "protectedBlock",
  group: "block",
  atom: true,
  isolating: true,
  selectable: true,
  addAttributes() {
    return {
      kind: {
        default: null,
        parseHTML: (element) => element.getAttribute("data-mail-protected"),
      },
    };
  },
  parseHTML() {
    return [{ tag: "div[data-mail-protected]" }];
  },
  renderHTML({ HTMLAttributes }) {
    const kind = String(HTMLAttributes.kind ?? "") as MailProtectedNodeKey;
    return [
      "div",
      mergeAttributes({
        "data-mail-protected": kind,
        class: "my-3 rounded-lg border border-brand-100 bg-brand-50 px-3 py-3 text-xs font-semibold text-brand-900",
        contenteditable: "false",
      }),
      `Beschermd blok · ${protectedNodeLabels[kind] ?? kind}`,
    ];
  },
});

function ToolbarButton({
  active = false,
  disabled = false,
  label,
  onClick,
  children,
}: {
  active?: boolean;
  disabled?: boolean;
  label: string;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      aria-pressed={active}
      disabled={disabled}
      onClick={onClick}
      className={`flex size-9 items-center justify-center rounded-md border text-slate-600 transition disabled:cursor-not-allowed disabled:opacity-40 ${
        active
          ? "border-brand-200 bg-brand-50 text-brand-700"
          : "border-transparent hover:border-line hover:bg-slate-50"
      }`}
    >
      {children}
    </button>
  );
}

export function MailV2Editor({
  revisionKey,
  content,
  allowedShortcodes,
  protectedNodes,
  disabled,
  onChange,
}: {
  revisionKey: string;
  content: MailTipTapDocument;
  allowedShortcodes: readonly MailShortcodeKey[];
  protectedNodes: readonly MailProtectedNodeKey[];
  disabled?: boolean;
  onChange: (document: MailTipTapDocument) => void;
}) {
  const editor = useEditor({
    immediatelyRender: false,
    editable: !disabled,
    extensions: [
      StarterKit.configure({
        link: false,
        heading: { levels: [2, 3] },
        code: false,
        codeBlock: false,
        blockquote: false,
        horizontalRule: false,
      }),
      Link.configure({
        openOnClick: false,
        autolink: false,
        protocols: ["https"],
        defaultProtocol: "https",
      }),
      ShortcodeNode,
      ProtectedBlockNode,
    ],
    content,
    editorProps: {
      attributes: {
        class: "min-h-64 px-4 py-4 text-sm leading-6 text-ink outline-none [&_h2]:mb-2 [&_h2]:mt-5 [&_h2]:text-xl [&_h2]:font-bold [&_h2]:text-brand-900 [&_h3]:mb-2 [&_h3]:mt-4 [&_h3]:text-base [&_h3]:font-bold [&_h3]:text-brand-900 [&_ol]:my-3 [&_ol]:list-decimal [&_ol]:pl-6 [&_p]:my-2 [&_ul]:my-3 [&_ul]:list-disc [&_ul]:pl-6",
      },
    },
    onUpdate: ({ editor: currentEditor }) => {
      onChange(currentEditor.getJSON() as MailTipTapDocument);
    },
  });

  useEffect(() => {
    if (!editor) return;
    if (JSON.stringify(editor.getJSON()) === JSON.stringify(content)) return;
    editor.commands.setContent(content, { emitUpdate: false });
  }, [content, editor, revisionKey]);

  useEffect(() => {
    editor?.setEditable(!disabled, false);
  }, [disabled, editor]);

  function setLink() {
    if (!editor) return;
    const current = editor.getAttributes("link").href as string | undefined;
    const value = window.prompt("HTTPS-link", current ?? "https://");
    if (value === null) return;
    if (!value.trim()) {
      editor.chain().focus().unsetLink().run();
      return;
    }
    try {
      const url = new URL(value);
      if (url.protocol !== "https:" || url.username || url.password) throw new Error();
      editor.chain().focus().extendMarkRange("link").setLink({ href: url.toString() }).run();
    } catch {
      window.alert("Gebruik een volledige HTTPS-link zonder gebruikersnaam of wachtwoord.");
    }
  }

  if (!editor) {
    return <div className="min-h-72 animate-pulse rounded-lg border border-line bg-slate-50" />;
  }

  return (
    <div className="overflow-hidden rounded-lg border border-line bg-white focus-within:border-brand-500 focus-within:ring-2 focus-within:ring-brand-100">
      <div className="flex flex-wrap items-center gap-1 border-b border-line bg-slate-50 px-2 py-2">
        <ToolbarButton label="Vet" active={editor.isActive("bold")} disabled={disabled} onClick={() => editor.chain().focus().toggleBold().run()}>
          <Bold className="size-4" />
        </ToolbarButton>
        <ToolbarButton label="Cursief" active={editor.isActive("italic")} disabled={disabled} onClick={() => editor.chain().focus().toggleItalic().run()}>
          <Italic className="size-4" />
        </ToolbarButton>
        <ToolbarButton label="Kop niveau 2" active={editor.isActive("heading", { level: 2 })} disabled={disabled} onClick={() => editor.chain().focus().toggleHeading({ level: 2 }).run()}>
          <Heading2 className="size-4" />
        </ToolbarButton>
        <ToolbarButton label="Kop niveau 3" active={editor.isActive("heading", { level: 3 })} disabled={disabled} onClick={() => editor.chain().focus().toggleHeading({ level: 3 }).run()}>
          <Heading3 className="size-4" />
        </ToolbarButton>
        <ToolbarButton label="Opsomming" active={editor.isActive("bulletList")} disabled={disabled} onClick={() => editor.chain().focus().toggleBulletList().run()}>
          <List className="size-4" />
        </ToolbarButton>
        <ToolbarButton label="Genummerde lijst" active={editor.isActive("orderedList")} disabled={disabled} onClick={() => editor.chain().focus().toggleOrderedList().run()}>
          <ListOrdered className="size-4" />
        </ToolbarButton>
        <ToolbarButton label="Link instellen" active={editor.isActive("link")} disabled={disabled} onClick={setLink}>
          <Link2 className="size-4" />
        </ToolbarButton>
        <span className="mx-1 h-6 w-px bg-line" />
        <label className="relative inline-flex h-9 items-center gap-2 rounded-md border border-line bg-white px-2 text-[11px] font-semibold text-brand-700">
          <Braces className="size-3.5" />
          Shortcode
          <select
            aria-label="Shortcode invoegen"
            disabled={disabled}
            value=""
            onChange={(event) => {
              const key = event.target.value as MailShortcodeKey;
              if (key) editor.chain().focus().insertContent({ type: "shortcode", attrs: { key } }).run();
            }}
            className="absolute inset-0 cursor-pointer opacity-0"
          >
            <option value="">Kies shortcode</option>
            {allowedShortcodes.map((key) => <option key={key} value={key}>{key}</option>)}
          </select>
        </label>
        <label className="relative inline-flex h-9 items-center gap-2 rounded-md border border-line bg-white px-2 text-[11px] font-semibold text-brand-700">
          <Rows3 className="size-3.5" />
          Beschermd blok
          <select
            aria-label="Beschermd blok invoegen"
            disabled={disabled}
            value=""
            onChange={(event) => {
              const kind = event.target.value as MailProtectedNodeKey;
              if (kind) editor.chain().focus().insertContent({ type: "protectedBlock", attrs: { kind } }).run();
            }}
            className="absolute inset-0 cursor-pointer opacity-0"
          >
            <option value="">Kies beschermd blok</option>
            {protectedNodes.map((kind) => <option key={kind} value={kind}>{protectedNodeLabels[kind]}</option>)}
          </select>
        </label>
      </div>
      <EditorContent editor={editor} />
    </div>
  );
}
