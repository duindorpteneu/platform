// @vitest-environment jsdom

import { readFileSync } from "node:fs";
import path from "node:path";
import { Editor } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import React, { act } from "react";
import { createRoot } from "react-dom/client";
import {
  afterAll,
  afterEach,
  beforeAll,
  describe,
  expect,
  it,
  vi,
} from "vitest";
import type { MailTipTapDocument } from "@/lib/mail-v2-contract";
import { MailV2Editor } from "./mail-v2-editor";

const source = readFileSync(
  path.join(import.meta.dirname, "mail-v2-editor.tsx"),
  "utf8",
);

describe("MailV2Editor editable-sync", () => {
  const editors: Editor[] = [];
  const roots: Array<ReturnType<typeof createRoot>> = [];

  beforeAll(() => {
    vi.stubGlobal("React", React);
    (globalThis as typeof globalThis & {
      IS_REACT_ACT_ENVIRONMENT: boolean;
    }).IS_REACT_ACT_ENVIRONMENT = true;
  });

  afterAll(() => {
    vi.unstubAllGlobals();
    (globalThis as typeof globalThis & {
      IS_REACT_ACT_ENVIRONMENT: boolean;
    }).IS_REACT_ACT_ENVIRONMENT = false;
  });

  afterEach(() => {
    for (const editor of editors.splice(0)) editor.destroy();
    for (const root of roots.splice(0)) act(() => root.unmount());
  });

  it("behandelt een busy-wissel niet als inhoudswijziging", () => {
    expect(source).toContain("editor?.setEditable(!disabled, false);");
    expect(source).not.toContain("editor?.setEditable(!disabled);");
  });

  it("bewijst waarom de expliciete emitUpdate=false nodig is", () => {
    const onUpdate = vi.fn();
    const editor = new Editor({
      element: document.createElement("div"),
      extensions: [StarterKit],
      content: "<p>Canonieke inhoud</p>",
      onUpdate,
    });
    editors.push(editor);

    editor.setEditable(false);
    expect(onUpdate).toHaveBeenCalledTimes(1);

    onUpdate.mockClear();
    editor.setEditable(true, false);
    expect(onUpdate).not.toHaveBeenCalled();
    expect(editor.getText()).toBe("Canonieke inhoud");
  });

  it("synchroniseert de later gecommitte inhoud van een nieuwe template", async () => {
    const first: MailTipTapDocument = {
      type: "doc",
      content: [{
        type: "paragraph",
        content: [{ type: "text", text: "Eerste template" }],
      }],
    };
    const second: MailTipTapDocument = {
      type: "doc",
      content: [{
        type: "paragraph",
        content: [{ type: "text", text: "Tweede template" }],
      }],
    };
    const onChange = vi.fn();
    const element = document.createElement("div");
    const root = createRoot(element);
    roots.push(root);

    await act(async () => {
      root.render(
        <MailV2Editor
          revisionKey="eerste:hash"
          content={first}
          allowedShortcodes={[]}
          protectedNodes={[]}
          onChange={onChange}
        />,
      );
    });
    expect(element.textContent).toContain("Eerste template");

    await act(async () => {
      root.render(
        <MailV2Editor
          revisionKey="tweede:hash"
          content={first}
          allowedShortcodes={[]}
          protectedNodes={[]}
          onChange={onChange}
        />,
      );
    });
    await act(async () => {
      root.render(
        <MailV2Editor
          revisionKey="tweede:hash"
          content={second}
          allowedShortcodes={[]}
          protectedNodes={[]}
          onChange={onChange}
        />,
      );
    });

    expect(element.textContent).toContain("Tweede template");
    expect(element.textContent).not.toContain("Eerste template");
    expect(onChange).not.toHaveBeenCalled();
  });
});
