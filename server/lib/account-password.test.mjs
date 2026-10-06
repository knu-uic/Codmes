import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeAccountId, hashAccountPassword, verifyAccountPassword, validateAccountPassword } from './account-password.mjs';
test('Codmes IDs are normalized and bounded',()=>{
  assert.equal(normalizeAccountId('  My.Account-1 '),'my.account-1');
  for(const value of ['', 'ab', 'with spaces', 'a'.repeat(65)]) assert.throws(()=>normalizeAccountId(value),{status:400});
});
test('password hashes are salted, versioned, verified and never plaintext',async()=>{
  const password='correct horse battery staple';
  const a=await hashAccountPassword(password),b=await hashAccountPassword(password);
  assert.notEqual(a,b);assert.ok(!a.includes(password));
  assert.equal(await verifyAccountPassword(password,a),true);
  assert.equal(await verifyAccountPassword('wrong',a),false);
  assert.equal(await verifyAccountPassword(password,'google-sign-in-only'),false);
  assert.equal(await verifyAccountPassword('x'.repeat(129),a),false);
});
test('short, excessively long and trivial passwords are rejected',()=>{
  for(const p of ['short','x'.repeat(15),'x'.repeat(129),'123456789012345']) assert.throws(()=>validateAccountPassword(p),{status:400});
});
