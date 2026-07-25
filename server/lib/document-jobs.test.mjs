import assert from "node:assert/strict";
import test from "node:test";

import {
  finishDocumentJob,
  listDocumentJobs,
  startDocumentJob,
  updateDocumentJob
} from "./document-jobs.mjs";

test("document jobs expose running progress and stop appearing as active when finished", () => {
  const job = startDocumentJob({
    path: "Notes/sample.pdf",
    title: "sample.pdf"
  });

  updateDocumentJob(job.id, {
    stage: "ocr",
    stageLabel: "OCR 처리 중",
    progress: 0.55,
    completedUnits: 55,
    totalUnits: 100
  });

  const running = listDocumentJobs({ includeCompleted: false });
  const active = running.find((candidate) => candidate.id === job.id);
  assert.equal(active?.status, "running");
  assert.equal(active?.progress, 0.55);
  assert.equal(active?.completedUnits, 55);

  finishDocumentJob(job.id, { status: "completed", message: "done" });
  assert.equal(
    listDocumentJobs({ includeCompleted: false }).some((candidate) => candidate.id === job.id),
    false
  );

  const completed = listDocumentJobs().find((candidate) => candidate.id === job.id);
  assert.equal(completed?.status, "completed");
  assert.equal(completed?.progress, 1);
  assert.ok(completed?.completedAt);
});
