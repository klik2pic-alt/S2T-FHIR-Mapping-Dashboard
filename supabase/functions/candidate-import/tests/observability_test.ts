import { assert, equal } from "./assert.ts";
import {
  createValidationPhaseLogger,
  type ValidationPhase,
  type ValidationPhaseFields,
} from "../lib/observability.ts";
import { parseAndValidateWorkbook } from "../lib/parser.ts";
import { workbookFixture } from "./workbook-fixture.ts";

Deno.test("validation phase logging emits only explicitly allowlisted safe fields", () => {
  const records: string[] = [];
  const times = [100, 112, 129];
  const logger = createValidationPhaseLogger(
    {
      requestId: "50000000-0000-4000-8000-000000000001",
      validationAttemptId: "50000000-0000-4000-8000-000000000002",
      correlationId: "50000000-0000-4000-8000-000000000003",
    },
    (record) => records.push(record),
    () => times.shift()!,
  );

  logger("validation-request-received");
  logger("row-validation-complete", {
    governedRowCount: 293,
    acceptedCount: 292,
    quarantinedCount: 1,
    workbookContents: "sensitive-cell-value",
    accessToken: "secret-access-token",
    signedUrl: "https://storage.invalid/private-signed-url",
    authorization: "Bearer secret-jwt",
  } as unknown as ValidationPhaseFields);

  equal(records.length, 2);
  const first = JSON.parse(records[0]) as Record<string, unknown>;
  const second = JSON.parse(records[1]) as Record<string, unknown>;
  equal(first.phase, "validation-request-received");
  equal(first.elapsedMs, 12);
  equal(first.totalElapsedMs, 12);
  equal(second.phase, "row-validation-complete");
  equal(second.elapsedMs, 17);
  equal(second.totalElapsedMs, 29);
  equal(second.governedRowCount, 293);
  equal(second.acceptedCount, 292);
  equal(second.quarantinedCount, 1);
  for (
    const forbidden of [
      "workbookContents",
      "sensitive-cell-value",
      "accessToken",
      "secret-access-token",
      "signedUrl",
      "private-signed-url",
      "authorization",
      "secret-jwt",
    ]
  ) {
    assert(!records[1].includes(forbidden));
  }
});

Deno.test("parser reports parse, normalization, and row-validation boundaries", async () => {
  const phases: Array<{ phase: ValidationPhase; fields: ValidationPhaseFields }> = [];
  const result = await parseAndValidateWorkbook(await workbookFixture(), {
    requestId: "50000000-0000-4000-8000-000000000004",
    validationAttemptId: "50000000-0000-4000-8000-000000000005",
    versionLabel: "observability-v1",
    onPhase: (phase, fields) => phases.push({ phase, fields }),
  });

  equal(phases.length, 3);
  equal(phases[0].phase, "exceljs-parse-complete");
  assert((phases[0].fields.worksheetCount ?? 0) >= 3);
  equal(phases[1].phase, "normalization-complete");
  equal(phases[1].fields.governedRowCount, result.rows.length);
  equal(phases[2].phase, "row-validation-complete");
  equal(phases[2].fields.governedRowCount, result.summary.candidateCount);
  equal(phases[2].fields.acceptedCount, result.summary.acceptedCount);
  equal(phases[2].fields.quarantinedCount, result.summary.quarantinedCount);
});

Deno.test("observability sink failures cannot interrupt validation behavior", () => {
  const logger = createValidationPhaseLogger(
    {
      requestId: "50000000-0000-4000-8000-000000000006",
      validationAttemptId: "50000000-0000-4000-8000-000000000007",
      correlationId: "50000000-0000-4000-8000-000000000008",
    },
    () => {
      throw new Error("unavailable log sink");
    },
    () => 100,
  );
  logger("validation-request-received");
});
