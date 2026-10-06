export class ReadinessTimeoutError extends Error {
  readonly lastError: unknown;
  constructor(lastError: unknown) {
    super("서버 준비 시간이 초과되었습니다.");
    this.lastError = lastError;
  }
}

export class ReadinessCancelledError extends Error {}

// A single caller owns polling; obsolete screens cannot finish over a newer one.
export async function waitForReadiness<T>(
  probe: () => Promise<T>,
  options: {
    isCurrent: () => boolean;
    timeoutMs?: number;
    intervalMs?: number;
    now?: () => number;
    wait?: (milliseconds: number) => Promise<void>;
  },
): Promise<T> {
  const now = options.now ?? (() => performance.now());
  const wait = options.wait ?? (milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)));
  const deadline = now() + (options.timeoutMs ?? 60_000);
  let lastError: unknown;
  while (options.isCurrent()) {
    try {
      const result = await probe();
      if (!options.isCurrent()) throw new ReadinessCancelledError();
      return result;
    } catch (error) {
      if (!options.isCurrent() || error instanceof ReadinessCancelledError) throw new ReadinessCancelledError();
      lastError = error;
    }
    const remaining = deadline - now();
    if (remaining <= 0) throw new ReadinessTimeoutError(lastError);
    await wait(Math.min(options.intervalMs ?? 1_000, remaining));
    if (now() >= deadline) throw new ReadinessTimeoutError(lastError);
  }
  throw new ReadinessCancelledError();
}
