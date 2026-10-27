import { assert, equal, rejects } from "./assert.ts";
import { preflightOoxml } from "../lib/ooxml-preflight.ts";
import { parseAndValidateWorkbook } from "../lib/parser.ts";
import { sha256Hex } from "../lib/normalization.ts";

Deno.test("canonical workbook reproduces frozen high-level evidence and remains non-clean", async () => {
  const url = new URL(
    "../../../../01_Baseline/CATO_IL_Core_MedicationRequest_Mapping_V_4.xlsx",
    import.meta.url,
  );
  const bytes = await Deno.readFile(url);
  equal(await sha256Hex(bytes), "3c7e551109ab814712c3b7bbbbbda4d41b457327452e4eee7746e698283fdc46");
  await rejects(
    () => preflightOoxml(bytes, 10_485_760, 52_428_800),
    /Active or external workbook content/,
  );
  const result = await parseAndValidateWorkbook(bytes, {
    requestId: "40000000-0000-4000-8000-000000000001",
    validationAttemptId: "40000000-0000-4000-8000-000000000002",
    versionLabel: "canonical-v4",
  });
  equal(result.summary.candidateCount, 293);
  equal(result.summary.acceptedCount, 292);
  equal(result.summary.quarantinedCount, 1);
  equal(result.summary.warningCount, 5);
  equal(result.summary.errorCount, 1);
  assert(result.summary.errorCount > 0, "Canonical workbook must not pass CLEAN_IMPORT");
});
