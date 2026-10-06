import test from "node:test";
import assert from "node:assert/strict";
import { confirmGoogleAccountChange } from "../src/account-confirmation.ts";

// Minimal DOM fixture. The real native WebView dialog is also checked in the release app.
class Element extends EventTarget {
  isConnected = true;
  focused = false;
  focus() { this.focused = true; }
}
globalThis.HTMLElement = Element;
class Dialog extends Element {
  returnValue = "";
  cancel = new Element();
  confirm = new Element();
  opened = false;
  setAttribute() {}
  querySelector(selector) { return selector === "[data-cancel]" ? this.cancel : this.confirm; }
  showModal() { this.opened = true; }
  close(value = this.returnValue) { this.returnValue = value; this.dispatchEvent(new Event("close")); }
  remove() { this.isConnected = false; }
}
function fixture() {
  const dialog = new Dialog();
  const activeElement = new Element();
  const document = { activeElement, createElement: () => dialog, body: { append() {} } };
  return { document, dialog, activeElement };
}

test("account change uses a visible application modal and requires explicit confirmation", async () => {
  const { document, dialog, activeElement } = fixture();
  const result = confirmGoogleAccountChange(document);
  assert.equal(dialog.opened, true);
  assert.equal(dialog.cancel.focused, true, "cancel is the safe default focus");
  dialog.confirm.onclick();
  assert.equal(await result, true);
  assert.equal(dialog.isConnected, false);
  assert.equal(activeElement.focused, true);
});

test("cancel button preserves the existing account", async () => {
  const { document, dialog } = fixture();
  const result = confirmGoogleAccountChange(document);
  dialog.cancel.onclick();
  assert.equal(await result, false);
});

test("Escape/native dialog dismissal never confirms account change", async () => {
  const { document, dialog } = fixture();
  const result = confirmGoogleAccountChange(document);
  dialog.close();
  assert.equal(await result, false);
});

test("repeated clicks share one modal and cleanup permits retry", async () => {
  const { document, dialog } = fixture();
  const first = confirmGoogleAccountChange(document);
  assert.equal(confirmGoogleAccountChange(fixture().document), first);
  dialog.cancel.onclick();
  await first;
  const next = fixture();
  const second = confirmGoogleAccountChange(next.document);
  assert.notEqual(second, first);
  next.dialog.cancel.onclick();
  assert.equal(await second, false);
});

test("modal failure is reported and does not leave the change button permanently blocked", async () => {
  const broken = fixture();
  broken.dialog.showModal = () => { throw new Error("dialog failed"); };
  await assert.rejects(confirmGoogleAccountChange(broken.document), /dialog failed/);
  assert.equal(broken.dialog.isConnected, false);
  const retry = fixture();
  const result = confirmGoogleAccountChange(retry.document);
  retry.dialog.cancel.onclick();
  assert.equal(await result, false);
});
