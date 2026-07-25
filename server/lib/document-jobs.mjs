import { randomUUID } from "node:crypto";

const jobs = new Map();
const MAX_RETAINED_JOBS = 20;

export function startDocumentJob({ path, title = "", kind = "pdf-normalization" }) {
  const now = new Date().toISOString();
  const job = {
    id: randomUUID(),
    kind,
    path: String(path || ""),
    title: String(title || "").trim() || String(path || "").split("/").at(-1) || "PDF",
    status: "running",
    stage: "inspecting",
    stageLabel: "PDF 검사 중",
    progress: 0.02,
    completedUnits: 0,
    totalUnits: null,
    startedAt: now,
    updatedAt: now,
    completedAt: null,
    message: ""
  };
  jobs.set(job.id, job);
  pruneJobs();
  return { ...job };
}

export function updateDocumentJob(id, patch = {}) {
  const current = jobs.get(id);
  if (!current) return null;
  const next = {
    ...current,
    ...patch,
    progress: clampProgress(patch.progress ?? current.progress),
    updatedAt: new Date().toISOString()
  };
  jobs.set(id, next);
  return { ...next };
}

export function finishDocumentJob(id, { status = "completed", message = "", ...patch } = {}) {
  return updateDocumentJob(id, {
    ...patch,
    status,
    stage: status === "completed" ? "completed" : "failed",
    stageLabel: status === "completed" ? "처리 완료" : "처리 실패",
    progress: status === "completed" ? 1 : patch.progress,
    message,
    completedAt: new Date().toISOString()
  });
}

export function listDocumentJobs({ includeCompleted = true } = {}) {
  return Array.from(jobs.values())
    .filter((job) => includeCompleted || job.status === "running")
    .sort((a, b) => String(b.startedAt).localeCompare(String(a.startedAt)))
    .map((job) => ({ ...job }));
}

function pruneJobs() {
  const ordered = Array.from(jobs.values())
    .sort((a, b) => String(b.startedAt).localeCompare(String(a.startedAt)));
  for (const job of ordered.slice(MAX_RETAINED_JOBS)) jobs.delete(job.id);
}

function clampProgress(value) {
  const number = Number(value);
  return Number.isFinite(number) ? Math.min(1, Math.max(0, number)) : 0;
}
