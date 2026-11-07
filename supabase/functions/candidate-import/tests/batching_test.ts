import { assert, equal, rejects } from "./assert.ts";
import {
  createBatches,
  JSONB_SIZE_RESERVE,
  MAX_STAGING_PAYLOAD_BYTES,
  type StagingBatch,
} from "../lib/batching.ts";
import { parseAndValidateWorkbook } from "../lib/parser.ts";
import { MAX_BATCH_BYTES, MAX_BATCH_ROWS, type StagedRow } from "../lib/contracts.ts";
import { canonicalJson, sha256Hex, utf8Size } from "../lib/normalization.ts";
import { workbookFixture } from "./workbook-fixture.ts";

const encoder = new TextEncoder();

async function legacyCreateBatches(rows: StagedRow[]): Promise<StagingBatch[]> {
  const batches: StagedRow[][] = [];
  let current: StagedRow[] = [];
  for (const row of rows) {
    if (utf8Size([row]) > MAX_BATCH_BYTES - JSONB_SIZE_RESERVE) {
      throw new Error("One normalized governed row exceeds the staging limit.");
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
      encodedBytes: encoder.encode(canonicalPayload).byteLength,
      digest: await sha256Hex(canonicalPayload),
    };
  }));
}

function assertSameBatches(actual: StagingBatch[], expected: StagingBatch[]): void {
  equal(actual.length, expected.length);
  actual.forEach((batch, index) => {
    const reference = expected[index];
    equal(batch.batchNumber, reference.batchNumber);
    equal(batch.rows.length, reference.rows.length);
    batch.rows.forEach((row, rowIndex) => assert(row === reference.rows[rowIndex]));
    equal(batch.canonicalPayload, reference.canonicalPayload);
    equal(batch.canonicalPayload, canonicalJson(batch.rows));
    equal(batch.encodedBytes, reference.encodedBytes);
    equal(batch.encodedBytes, encoder.encode(batch.canonicalPayload).byteLength);
    equal(batch.digest, reference.digest);
  });
}

function rowWithCanonicalBytes(
  source: StagedRow,
  targetBytes: number,
  marker: string,
): StagedRow {
  const withoutPadding = {
    ...source,
    subtype: { ...source.subtype, deterministicPadding: marker },
  } as StagedRow;
  const baseBytes = encoder.encode(canonicalJson(withoutPadding)).byteLength;
  assert(targetBytes >= baseBytes);
  const padded = {
    ...source,
    subtype: {
      ...source.subtype,
      deterministicPadding: marker + "x".repeat(targetBytes - baseBytes),
    },
  } as StagedRow;
  equal(encoder.encode(canonicalJson(padded)).byteLength, targetBytes);
  return padded;
}

async function fixtureRows(): Promise<StagedRow[]> {
  const result = await parseAndValidateWorkbook(await workbookFixture(), {
    requestId: "20000000-0000-4000-8000-000000000001",
    validationAttemptId: "20000000-0000-4000-8000-000000000002",
    versionLabel: "batch-v1",
  });
  return result.rows;
}

Deno.test("optimized batching preserves legacy boundaries, ordering, payloads, and digests", async () => {
  const rows = await fixtureRows();
  const optimized = await createBatches(rows);
  const legacy = await legacyCreateBatches(rows);
  assertSameBatches(optimized, legacy);

  const repeated = await createBatches(rows);
  assertSameBatches(repeated, optimized);
  optimized.forEach((batch, index) => {
    equal(batch.batchNumber, index);
    assert(batch.rows.length <= MAX_BATCH_ROWS);
    assert(batch.encodedBytes <= MAX_STAGING_PAYLOAD_BYTES);
  });
});

Deno.test("canonical 293-row fixture keeps the exact 250 plus 43 row boundary", async () => {
  const batches = await createBatches(await fixtureRows());
  equal(batches.length, 2);
  equal(batches[0].rows.length, 250);
  equal(batches[1].rows.length, 43);
  equal(batches.reduce((count, batch) => count + batch.rows.length, 0), 293);
});

Deno.test("batching enforces the row boundary and never emits an empty batch", async () => {
  const rows = await fixtureRows();
  const batches = await createBatches(rows.slice(0, 251));
  equal(batches[0].rows.length, 250);
  equal(batches[1].rows.length, 1);
  equal(batches.reduce((count, batch) => count + batch.rows.length, 0), 251);
  assert(batches.every((batch) => batch.rows.length > 0));
  assert(batches.every((batch) => batch.rows.length <= MAX_BATCH_ROWS));
  equal((await createBatches([])).length, 0);
});

Deno.test("batching preserves the exact encoded-byte boundary and splits one byte over", async () => {
  const source = (await fixtureRows())[0];
  const firstRowBytes = 10_000;
  const secondRowBytes = MAX_STAGING_PAYLOAD_BYTES - 3 - firstRowBytes;
  const first = rowWithCanonicalBytes(source, firstRowBytes, "first:");
  const exactSecond = rowWithCanonicalBytes(source, secondRowBytes, "exact:");
  const exact = await createBatches([first, exactSecond]);
  equal(exact.length, 1);
  equal(exact[0].encodedBytes, MAX_STAGING_PAYLOAD_BYTES);

  const oneByteOver = rowWithCanonicalBytes(source, secondRowBytes + 1, "over:");
  const split = await createBatches([first, oneByteOver]);
  equal(split.length, 2);
  equal(split[0].rows.length, 1);
  equal(split[1].rows.length, 1);
  assert(split.every((batch) => batch.encodedBytes <= MAX_STAGING_PAYLOAD_BYTES));
});

Deno.test("batching rejects one normalized row over the exact payload guard", async () => {
  const source = (await fixtureRows())[0];
  const oversized = rowWithCanonicalBytes(source, MAX_STAGING_PAYLOAD_BYTES - 1, "oversized:");
  await rejects(() => createBatches([oversized]), /exceeds the staging limit/);
});

Deno.test("encoded-byte hotspot fixture preserves legacy byte-driven boundaries", async () => {
  const rows = (await fixtureRows()).slice(0, 200).map((row, index) => ({
    ...row,
    subtype: { ...row.subtype, deterministicPadding: `${index}:` + "x".repeat(20_000) },
  } as StagedRow));
  const optimized = await createBatches(rows);
  const legacy = await legacyCreateBatches(rows);
  assertSameBatches(optimized, legacy);
  assert(optimized.length > 1);
  assert(optimized.every((batch) => batch.rows.length < MAX_BATCH_ROWS));
  assert(optimized.every((batch) => batch.encodedBytes <= MAX_STAGING_PAYLOAD_BYTES));
});
