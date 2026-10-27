import { MAX_BATCH_BYTES, MAX_BATCH_ROWS, type StagedRow } from "./contracts.ts";
import { canonicalJson, sha256Hex, utf8Size } from "./normalization.ts";
import { ImportError } from "./errors.ts";

// PostgreSQL stores jsonb in a binary representation. Keep a bounded reserve
// below its 2 MiB pg_column_size guard instead of assuming UTF-8 JSON size is identical.
export const JSONB_SIZE_RESERVE = 65_536;

export interface StagingBatch {
  batchNumber: number;
  rows: StagedRow[];
  canonicalPayload: string;
  encodedBytes: number;
  digest: string;
}

export async function createBatches(rows: StagedRow[]): Promise<StagingBatch[]> {
  const batches: StagedRow[][] = [];
  let current: StagedRow[] = [];
  for (const row of rows) {
    if (utf8Size([row]) > MAX_BATCH_BYTES - JSONB_SIZE_RESERVE) {
      throw new ImportError(
        "FILE_TOO_LARGE",
        "One normalized governed row exceeds the staging limit.",
      );
    }
    const proposed = [...current, row];
    if (
      current.length > 0 &&
      (proposed.length > MAX_BATCH_ROWS ||
        utf8Size(proposed) > MAX_BATCH_BYTES - JSONB_SIZE_RESERVE)
    ) {
      batches.push(current);
      current = [row];
    } else {
      current = proposed;
    }
  }
  if (current.length) batches.push(current);
  return Promise.all(batches.map(async (batchRows, batchNumber) => {
    const canonicalPayload = canonicalJson(batchRows);
    return {
      batchNumber,
      rows: batchRows,
      canonicalPayload,
      encodedBytes: new TextEncoder().encode(canonicalPayload).byteLength,
      digest: await sha256Hex(canonicalPayload),
    };
  }));
}
