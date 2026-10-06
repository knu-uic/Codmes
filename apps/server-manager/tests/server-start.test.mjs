import test from "node:test";
import assert from "node:assert/strict";
import {existingServerChoice, resetWarning, resetConfirmationFields, resetConfirmed, RESET_CONFIRMATION} from "../src/server-start.ts";

const setup = {existingServer:true, maskedAccount:{id:"j***69",email:"j***69@gmail.com"},resetAllowed:true,resetUnavailableReason:null};
test("existing server offers continuation and a separate destructive fresh start", () => {
  const html = existingServerChoice(setup);
  assert.match(html, /기존 서버로 계속하기/);
  assert.match(html, /새 서버로 시작하기/);
  assert.match(html, /j\*\*\*69@gmail.com/);
  assert.doesNotMatch(html, /j\*\*\*69<\/strong>/);
  assert.match(existingServerChoice({...setup,maskedAccount:{id:"a***",email:""}}), /a\*\*\*/);
  assert.match(existingServerChoice({...setup,maskedAccount:null}), /기존/);
});
test("unsafe storage disables reset and account hints/errors are HTML escaped", () => {
  const html = existingServerChoice({...setup,maskedAccount:{id:"<script>",email:""},resetAllowed:false,resetUnavailableReason:"<unsafe>"});
  assert.match(html, /disabled/);
  assert.match(html, /&lt;script&gt;/);
  assert.match(html, /&lt;unsafe&gt;/);
  assert.doesNotMatch(html, /<script>/);
});
test("deletion needs the exact phrase and an affirmative acknowledgement", () => {
  assert.equal(resetConfirmed(RESET_CONFIRMATION,true),true);
  assert.equal(resetConfirmed(RESET_CONFIRMATION,false),false);
  assert.equal(resetConfirmed("",true),false);
  assert.equal(resetConfirmed(RESET_CONFIRMATION+" ",true),false);
  assert.match(resetConfirmationFields(), /required/);
});
test("warning covers server-wide loss, deferred backup and preservation of other devices", () => {
  const html = resetWarning();
  for (const word of ["계정","프로필","기기","파일","플러그인","로컬","Google","백업"]) assert.ok(html.includes(word),word);
});
