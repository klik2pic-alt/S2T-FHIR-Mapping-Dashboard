import { assert, equal, rejects } from "./assert.ts";
import { preflightOoxml } from "../lib/ooxml-preflight.ts";
import { parseAndValidateWorkbook } from "../lib/parser.ts";
import { SHEET_CONTRACTS } from "../lib/contracts.ts";
import { workbookFixture } from "./workbook-fixture.ts";

const context = {
  requestId: "10000000-0000-4000-8000-000000000001",
  validationAttemptId: "10000000-0000-4000-8000-000000000002",
  versionLabel: "test-v1",
};

Deno.test("valid governed XLSX structure parses 293 rows and keeps O/P distinct", async () => {
  const bytes = await workbookFixture();
  const preflight = preflightOoxml(bytes, 10_485_760, 52_428_800);
  assert(preflight.sheetCount >= 3);
  const result = await parseAndValidateWorkbook(bytes, context);
  equal(result.rows.length, 293);
  equal(SHEET_CONTRACTS["S2T MedicationRequestCato"].headers[14], "Exceptions handling");
  equal(SHEET_CONTRACTS["S2T MedicationRequestCato"].headers[15], "Notes");
  equal(result.summary.errorCount, 0);
});

Deno.test("missing sheet and renamed governed header are rejected", async () => {
  await rejects(async () =>
    parseAndValidateWorkbook(
      await workbookFixture({ omitSheet: "Cato Status Mapping" }),
      context,
    ), /Required sheet/);
  await rejects(async () =>
    parseAndValidateWorkbook(
      await workbookFixture({ renameHeader: true }),
      context,
    ), /headers do not match/);
});

Deno.test("formula in governed range is never evaluated and blocks its row", async () => {
  const result = await parseAndValidateWorkbook(await workbookFixture({ formula: true }), context);
  assert(result.findings.some((finding) => finding.code === "CLEAN_IMPORT_INTEGRITY"));
  const row = result.rows.find((item) =>
    item.sourceSheetName === "S2T MedicationRequestCato" && item.sourceRowNumber === 2
  )!;
  equal(row.candidateDisposition, "QUARANTINED");
  assert(row.rawSourceRow.orderedRawCells.some((cell) => cell.type === "formula"));
});

Deno.test("row number is excluded from source hash and duplicate logical identity is detected", async () => {
  const result = await parseAndValidateWorkbook(
    await workbookFixture({ duplicateMainRows: true }),
    context,
  );
  const first = result.rows.find((row) =>
    row.sourceSheetName === "S2T MedicationRequestCato" && row.sourceRowNumber === 2
  )!;
  const second = result.rows.find((row) =>
    row.sourceSheetName === "S2T MedicationRequestCato" && row.sourceRowNumber === 3
  )!;
  equal(first.sourceRowHash, second.sourceRowHash);
  equal(first.logicalKey, second.logicalKey);
  assert(result.findings.some((finding) => finding.code === "DUPLICATE_SOURCE_ROW"));
  assert(result.findings.some((finding) => finding.code === "DUPLICATE_LOGICAL_IDENTITY"));
  const logicalOnly = await parseAndValidateWorkbook(
    await workbookFixture({ duplicateLogicalOnly: true }),
    context,
  );
  const logicalFirst = logicalOnly.rows.find((row) =>
    row.sourceSheetName === "S2T MedicationRequestCato" && row.sourceRowNumber === 2
  )!;
  const logicalSecond = logicalOnly.rows.find((row) =>
    row.sourceSheetName === "S2T MedicationRequestCato" && row.sourceRowNumber === 3
  )!;
  assert(logicalFirst.sourceRowHash !== logicalSecond.sourceRowHash);
  equal(logicalFirst.logicalKey, logicalSecond.logicalKey);
  assert(!logicalOnly.findings.some((finding) => finding.code === "DUPLICATE_SOURCE_ROW"));
  assert(logicalOnly.findings.some((finding) => finding.code === "DUPLICATE_LOGICAL_IDENTITY"));
});

Deno.test("validation enforces cardinality and Decision Status without weakening warnings", async () => {
  const cardinality = await parseAndValidateWorkbook(
    await workbookFixture({ invalidCardinality: true }),
    context,
  );
  assert(
    cardinality.findings.some((finding) =>
      finding.code === "INVALID_CARDINALITY" && finding.severity === "ERROR"
    ),
  );
  const decision = await parseAndValidateWorkbook(
    await workbookFixture({ unknownDecision: true }),
    context,
  );
  assert(decision.findings.some((finding) => finding.code === "UNKNOWN_DECISION_STATUS"));
  const warning = await parseAndValidateWorkbook(
    await workbookFixture({ warningOnly: true }),
    context,
  );
  assert(
    warning.findings.some((finding) =>
      finding.code === "INVALID_CARDINALITY" && finding.severity === "WARNING"
    ),
  );
  equal(warning.summary.errorCount, 0);
});

Deno.test("zero accepted rows is explicit and status/guidance row semantics are frozen", async () => {
  const result = await parseAndValidateWorkbook(
    await workbookFixture({ formulaAll: true }),
    context,
  );
  equal(result.summary.acceptedCount, 0);
  assert(result.findings.some((finding) => finding.code === "ZERO_ACCEPTED_ROWS"));
  const statusRows = result.rows.filter((row) => row.mappingKind === "STATUS_MAPPING_RULE");
  equal(statusRows.find((row) => row.sourceRowNumber === 17)?.decisionStatus, "OPEN");
  assert(
    statusRows.filter((row) => row.sourceRowNumber !== 17).every((row) =>
      row.decisionStatus === "FINAL"
    ),
  );
  const guidance3 = result.rows.find((row) =>
    row.mappingKind === "GOVERNANCE_GUIDANCE" && row.sourceRowNumber === 3
  )!;
  equal(guidance3.subtype.guidanceScope, "GLOBAL_MAPPING_POLICY");
  equal(guidance3.subtype.decisionTopic, "NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING");
});

Deno.test("raw evidence preserves source types, values, coordinates, and normalized values", async () => {
  const result = await parseAndValidateWorkbook(await workbookFixture(), context);
  const row = result.rows[0];
  equal(row.rawSourceRow.sheet, row.sourceSheetName);
  equal(row.rawSourceRow.row, row.sourceRowNumber);
  equal(row.rawSourceRow.range, row.sourceCellRange);
  equal(row.rawSourceRow.orderedRawCells.length, 17);
  equal(row.rawSourceRow.orderedRawCells[14].header, "Exceptions handling");
  equal(row.rawSourceRow.orderedRawCells[15].header, "Notes");
  const manifest = result.sheetManifest.find((entry) =>
    entry.sheetName === "S2T MedicationRequestCato"
  )!;
  equal(manifest.rawHeaders?.[14].value, "Exceptions handling");
  equal(manifest.normalizedHeaders?.[15], "Notes");
});
