import { MAX_BATCH_BYTES, MAX_BATCH_ROWS, type StagedRow } from "./contracts.ts";
import { canonicalJson, sha256Hex } from "./normalization.ts";
import { ImportError } from "./errors.ts";

// PostgreSQL stores jsonb in a binary representation. Keep a bounded reserve
// below its 2 MiB pg_column_size guard instead of assuming UTF-8 JSON size is identical.
export const JSONB_SIZE_RESERVE = 65_536;
export const MAX_STAGING_PAYLOAD_BYTES = MAX_BATCH_BYTES - JSONB_SIZE_RESERVE;

const encoder = new TextEncoder();

export interface StagingBatch {
  batchNumber: number;
  rows: StagedRow[];
  canonicalPayload: string;
  encodedBytes: number;
  digest: string;
}

export async function createBatches(rows: StagedRow[]): Promise<StagingBatch[]> {
  const batches: Omit<StagingBatch, "digest">[] = [];
  let currentRows: StagedRow[] = [];
  let currentCanonicalRows: string[] = [];
  let currentEncodedBytes = 2; // Opening and closing JSON array brackets.

  const finishCurrentBatch = () => {
    if (currentRows.length === 0) return;
    const canonicalPayload = `[${currentCanonicalRows.join(",")}]`;
    batches.push({
      batchNumber: batches.length,
      rows: currentRows,
      canonicalPayload,
      encodedBytes: currentEncodedBytes,
    });
    currentRows = [];
    currentCanonicalRows = [];
    currentEncodedBytes = 2;
  };

  for (const row of rows) {
    const canonicalRow = canonicalJson(row);
    const rowEncodedBytes = encoder.encode(canonicalRow).byteLength;
    if (rowEncodedBytes + 2 > MAX_STAGING_PAYLOAD_BYTES) {
      throw new ImportError(
        "FILE_TOO_LARGE",
        "One normalized governed row exceeds the staging limit.",
      );
    }
    const proposedEncodedBytes = currentEncodedBytes +
      (currentRows.length === 0 ? 0 : 1) + rowEncodedBytes;
    if (
      currentRows.length > 0 &&
      (currentRows.length + 1 > MAX_BATCH_ROWS ||
        proposedEncodedBytes > MAX_STAGING_PAYLOAD_BYTES)
    ) {
      finishCurrentBatch();
    }
    currentRows.push(row);
    currentCanonicalRows.push(canonicalRow);
    currentEncodedBytes += (currentRows.length === 1 ? 0 : 1) + rowEncodedBytes;
  }
  finishCurrentBatch();

  return Promise.all(batches.map(async (batch) => ({
    ...batch,
    digest: await sha256Hex(batch.canonicalPayload),
  })));
}
