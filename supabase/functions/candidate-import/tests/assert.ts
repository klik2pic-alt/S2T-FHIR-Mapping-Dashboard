export function assert(condition: unknown, message = "Assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

export function equal<T>(actual: T, expected: T, message = "Values differ"): void {
  if (!Object.is(actual, expected)) {
    throw new Error(`${message}: actual=${String(actual)} expected=${String(expected)}`);
  }
}

export async function rejects(
  fn: () => unknown | Promise<unknown>,
  pattern?: RegExp,
): Promise<void> {
  try {
    await fn();
  } catch (error) {
    if (pattern && !pattern.test(error instanceof Error ? error.message : String(error))) {
      throw error;
    }
    return;
  }
  throw new Error("Expected rejection");
}
