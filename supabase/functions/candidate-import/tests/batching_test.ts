import { assert, equal } from "./assert.ts";
import { createBatches } from "../lib/batching.ts";
import { parseAndValidateWorkbook } from "../lib/parser.ts";
import { MAX_BATCH_BYTES, MAX_BATCH_ROWS } from "../lib/contracts.ts";
import { workbookFixture } from "./workbook-fixture.ts";

Deno.test("batches have stable numbering/digests and stay within limits", async () => {
  const result = await parseAndValidateWorkbook(await workbookFixture(), {
    requestId: "20000000-0000-4000-8000-000000000001",
    validationAttemptId: "20000000-0000-4000-8000-000000000002",
    versionLabel: "batch-v1",
  });
  const first = await createBatches(result.rows);
  const second = await createBatches(result.rows);
  assert(first.length >= 2);
  first.forEach((batch, index) => {
    equal(batch.batchNumber, index);
    assert(batch.rows.length <= MAX_BATCH_ROWS);
    assert(batch.encodedBytes <= MAX_BATCH_BYTES);
    equal(batch.digest, second[index].digest);
  });
});

Deno.test("batching enforces the 250-row boundary and never emits an empty batch", async () => {
  const result = await parseAndValidateWorkbook(await workbookFixture(), {
    requestId: "20000000-0000-4000-8000-000000000003",
    validationAttemptId: "20000000-0000-4000-8000-000000000004",
    versionLabel: "batch-boundary-v1",
  });
  const batches = await createBatches(result.rows.slice(0, 251));
  equal(batches[0].rows.length, 250);
  equal(batches[1].rows.length, 1);
  equal(batches.reduce((count, batch) => count + batch.rows.length, 0), 251);
  assert(batches.every((batch) => batch.rows.length > 0));
  assert(batches.every((batch) => batch.rows.length <= MAX_BATCH_ROWS));
  equal((await createBatches([])).length, 0);
});

Deno.test("batching splits on the encoded byte guard before the row guard", async () => {
  const result = await parseAndValidateWorkbook(await workbookFixture(), {
    requestId: "20000000-0000-4000-8000-000000000005",
    validationAttemptId: "20000000-0000-4000-8000-000000000006",
    versionLabel: "batch-byte-v1",
  });
  const rows = result.rows.slice(0, 200).map((row, index) => ({
    ...row,
    subtype: { ...row.subtype, deterministicPadding: `${index}:` + "x".repeat(20_000) },
  }));
  const batches = await createBatches(rows);
  assert(batches.length > 1);
  assert(batches.every((batch) => batch.rows.length < MAX_BATCH_ROWS));
  assert(batches.every((batch) => batch.encodedBytes <= MAX_BATCH_BYTES));
});
