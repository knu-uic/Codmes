import test from "node:test";
import assert from "node:assert/strict";
import {
  collectRelatedImages,
  normalizeRelatedImageUrls,
  redactRelatedImageUrlsForModel,
  relatedImagePolicyLines,
  renderSelectedFigureTokens
} from "./openai-compatible-runtime.mjs";

test("normalizes MCP-relative related image URLs for runtime evidence", () => {
  const output = normalizeRelatedImageUrls({
    structuredContent: {
      related_images: [{ asset_id: 49, reference: "[그림:49]", number: 1, description: "학문기초교양 필터", url: "/api/notice-assets/49/content" }]
    }
  }, "http://127.0.0.1:8000/api/mcp");

  assert.equal(
    output.structuredContent.related_images[0].url,
    "http://127.0.0.1:8000/api/notice-assets/49/content"
  );
});

test("keeps image URLs out of model-visible tool evidence", () => {
  const evidence = normalizeRelatedImageUrls({
    content: [{ type: "text", text: JSON.stringify({ related_images: [
      { asset_id: 49, reference: "[그림:49]", description: "필터", url: "/api/notice-assets/49/content" }
    ] }) }],
    structuredContent: { related_images: [
      { asset_id: 49, reference: "[그림:49]", description: "필터", url: "/api/notice-assets/49/content" }
    ] }
  }, "http://127.0.0.1:8000/api/mcp");

  const modelEvidence = redactRelatedImageUrlsForModel(evidence);
  const nestedText = JSON.parse(modelEvidence.content[0].text);

  assert.equal(modelEvidence.structuredContent.related_images[0].url, undefined);
  assert.equal(nestedText.related_images[0].url, undefined);
  assert.equal(nestedText.related_images[0].reference, "[그림:49]");
  assert.equal(collectRelatedImages(evidence)[0].url, "http://127.0.0.1:8000/api/notice-assets/49/content");
});

test("resolves only model-selected figure tokens from the current tool evidence", () => {
  const evidence = normalizeRelatedImageUrls({ related_images: [
    { asset_id: 49, number: 1, description: "학문기초교양 필터", url: "/api/notice-assets/49/content" },
    { asset_id: 50, number: 2, description: "균형교양 필터", url: "/api/notice-assets/50/content" }
  ] }, "http://127.0.0.1:8000/api/mcp");
  const allowed = new Map(collectRelatedImages(evidence).map((image) => [String(image.asset_id), image]));

  const answer = renderSelectedFigureTokens("필터 방법입니다.\n[그림:49]\n[그림:999]", allowed);

  assert.match(answer, /!\[그림 1 · 학문기초교양 필터\]\(http:\/\/127\.0\.0\.1:8000/);
  assert.doesNotMatch(answer, /notice-assets\/50/);
  assert.match(answer, /\[그림:999\]/);
});

test("image policy delegates placement to the model and forbids an automatic gallery", () => {
  const policy = relatedImagePolicyLines().join("\n");

  assert.match(policy, /optional visual evidence/);
  assert.match(policy, /materially helps/);
  assert.match(policy, /zero, one, or multiple images/);
  assert.match(policy, /before or after their explanation, or consecutively/);
  assert.match(policy, /exact \[그림:assetId\] token/);
  assert.match(policy, /Image URLs are intentionally hidden/);
  assert.match(policy, /do not append every available image/i);
});
