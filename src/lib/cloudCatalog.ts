export const CLOUD_AUTO_ATTEMPTS = 4;
export const CLOUD_RETRY_DELAYS_MS = [900, 1800, 3600] as const;

export function cloudRetryDelay(attempt: number): number {
  return CLOUD_RETRY_DELAYS_MS[attempt - 1] ?? 0;
}

interface CloudAttemptOptions {
  maxAttempts?: number;
  onAttempt?: (attempt: number) => void;
  wait?: (milliseconds: number) => Promise<void>;
}

function defaultWait(milliseconds: number): Promise<void> {
  return new Promise((resolve) => globalThis.setTimeout(resolve, milliseconds));
}

export async function runCloudCatalogAttempts<T>(
  fetchCatalog: () => Promise<T>,
  {
    maxAttempts = CLOUD_AUTO_ATTEMPTS,
    onAttempt,
    wait = defaultWait,
  }: CloudAttemptOptions = {},
): Promise<{ result: T; attempts: number }> {
  const limit = Math.max(1, Math.trunc(maxAttempts));
  let lastError: unknown;
  for (let attempt = 1; attempt <= limit; attempt += 1) {
    onAttempt?.(attempt);
    try {
      return { result: await fetchCatalog(), attempts: attempt };
    } catch (error) {
      lastError = error;
      if (attempt < limit) await wait(cloudRetryDelay(attempt));
    }
  }
  throw lastError instanceof Error ? lastError : new Error(String(lastError));
}
