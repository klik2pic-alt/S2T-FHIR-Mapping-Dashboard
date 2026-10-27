import type { FindingCode, FindingSeverity, StagedRow, ValidationFinding } from "./contracts.ts";
import { digestCanonical, identityNorm, normalizeText } from "./normalization.ts";

const ALLOWED_DECISION_VALUES = ["FINAL", "WIP", "OPEN", "DO NOT MAP", "N/A"] as const;
const ALLOWED_DECISIONS = new Set<string>(ALLOWED_DECISION_VALUES);
const CARDINALITY = /^(0|[1-9]\d*)\.\.(\*|0|[1-9]\d*)$/;
const APPROVED_BLANK_TARGETS = new Set([
  "dosageinstruction.timing.repeat.bounds[x]",
  "dosageinstruction.timing.repeat.boundsduration***",
  "dosageinstruction.timing.repeat.boundsrange***",
  "dosageinstruction.timing.repeat.boundsperiod***",
]);

export const VALIDATION_CONFIGURATION = {
  schema: "candidate-import-validation-configuration-v1",
  allowedDecisionStatuses: ALLOWED_DECISION_VALUES,
  cardinalityPattern: CARDINALITY.source,
  approvedBlankCardinalityTargets: [...APPROVED_BLANK_TARGETS].sort(),
  statusTarget: "MedicationRequest.status",
  formulaPolicy: "ERROR_IN_GOVERNED_RANGE",
  duplicatePolicies: ["SOURCE_ROW_HASH", "LOGICAL_KEY"],
  cleanImport: {
    maximumErrors: 0,
    maximumQuarantinedRows: 0,
    minimumAcceptedRows: 1,
  },
} as const;

async function finding(
  code: FindingCode,
  severity: FindingSeverity,
  safeMessage: string,
  row?: StagedRow,
  collisionGroup?: string,
  field?: string,
): Promise<ValidationFinding> {
  const evidence = row
    ? {
      schema: "candidate-import-finding",
      version: "v1",
      sheetName: row.sourceSheetName,
      rowNumber: row.sourceRowNumber,
      cellRange: row.sourceCellRange,
      field: field ?? null,
      sourceRowHash: row.sourceRowHash,
      logicalKey: row.logicalKey,
      collisionGroup: collisionGroup ?? null,
    }
    : {
      schema: "candidate-import-finding",
      version: "v1",
      collisionGroup: collisionGroup ?? null,
    };
  return {
    code,
    severity,
    safeMessage,
    ...(row
      ? {
        sourceSheetName: row.sourceSheetName,
        sourceRowNumber: row.sourceRowNumber,
        sourceCellRange: row.sourceCellRange,
        sourceRowHash: row.sourceRowHash,
      }
      : {}),
    ...(field ? { field } : {}),
    ...(collisionGroup ? { collisionGroup } : {}),
    fingerprint: await digestCanonical({ code, severity, evidence }),
    evidence,
    internalDiagnosticReference: crypto.randomUUID(),
  };
}

async function validateOne(row: StagedRow): Promise<ValidationFinding[]> {
  const findings: ValidationFinding[] = [];
  for (const cell of row.rawSourceRow.orderedRawCells.filter((item) => item.type === "formula")) {
    findings.push(
      await finding(
        "CLEAN_IMPORT_INTEGRITY",
        "ERROR",
        "Formula cells are not allowed in governed workbook ranges.",
        row,
        undefined,
        cell.column,
      ),
    );
  }
  if (!ALLOWED_DECISIONS.has(row.decisionStatus)) {
    findings.push(
      await finding(
        "UNKNOWN_DECISION_STATUS",
        "ERROR",
        "The governed Decision Status is blank or unsupported.",
        row,
        undefined,
        "Decision Status",
      ),
    );
  }
  if (row.mappingKind === "ELEMENT_MAPPING") {
    const target = normalizeText(row.subtype.targetFhirPath);
    const cardinality = normalizeText(row.subtype.cardinalityRaw);
    if (!target) {
      findings.push(
        await finding(
          "REQUIRED_TARGET_FHIR_PATH",
          "ERROR",
          "A target FHIR path is required for an element mapping.",
          row,
          undefined,
          "Target Element name (FHIR)",
        ),
      );
    }
    if (
      !cardinality && APPROVED_BLANK_TARGETS.has(identityNorm(target)) &&
      row.decisionStatus === "DO NOT MAP"
    ) {
      findings.push(
        await finding(
          "INVALID_CARDINALITY",
          "WARNING",
          "An approved historical blank-cardinality exception was preserved.",
          row,
          undefined,
          "Cardinality",
        ),
      );
    } else if (!CARDINALITY.test(cardinality)) {
      findings.push(
        await finding(
          "INVALID_CARDINALITY",
          "ERROR",
          "Cardinality does not match the governed syntax.",
          row,
          undefined,
          "Cardinality",
        ),
      );
    }
  } else if (row.mappingKind === "STATUS_MAPPING_RULE") {
    if (
      row.subtype.targetFhirPath !== "MedicationRequest.status" ||
      !normalizeText(row.subtype.sourceStatusValue) || !normalizeText(row.subtype.targetStatusValue)
    ) {
      findings.push(
        await finding(
          "STATUS_MAPPING_CONTRACT",
          "ERROR",
          "The status mapping does not satisfy the fixed MedicationRequest.status contract.",
          row,
        ),
      );
    }
  } else {
    if (
      !normalizeText(row.subtype.guidanceScope) || !normalizeText(row.subtype.decisionTopic) ||
      !normalizeText(row.subtype.decisionTopicRaw)
    ) {
      findings.push(
        await finding(
          "GOVERNANCE_GUIDANCE_CONTRACT",
          "ERROR",
          "The governance guidance scope or decision topic is missing.",
          row,
        ),
      );
    }
    if (
      row.rawSourceRow.orderedRawCells.some((cell) => cell.column === "E" && cell.type === "error")
    ) {
      findings.push(
        await finding(
          "GOVERNANCE_GUIDANCE_CONTRACT",
          "WARNING",
          "An optional source note contains a preserved Excel error value.",
          row,
          undefined,
          "E",
        ),
      );
    }
  }
  return findings;
}

async function duplicateFindings(
  rows: StagedRow[],
  selector: (row: StagedRow) => string,
  code: "DUPLICATE_SOURCE_ROW" | "DUPLICATE_LOGICAL_IDENTITY",
): Promise<ValidationFinding[]> {
  const groups = new Map<string, StagedRow[]>();
  for (const row of rows) groups.set(selector(row), [...(groups.get(selector(row)) ?? []), row]);
  const findings: ValidationFinding[] = [];
  for (const [value, group] of groups) {
    if (group.length < 2) continue;
    const collisionGroup = await digestCanonical({ code, value });
    for (const row of group) {
      findings.push(
        await finding(
          code,
          "ERROR",
          code === "DUPLICATE_SOURCE_ROW"
            ? "A governed source-row identity occurs more than once."
            : "A governed logical mapping identity occurs more than once.",
          row,
          collisionGroup,
        ),
      );
    }
  }
  return findings;
}

export async function validateRows(rows: StagedRow[]): Promise<ValidationFinding[]> {
  const findings = (await Promise.all(rows.map(validateOne))).flat();
  findings.push(
    ...await duplicateFindings(rows, (row) => row.sourceRowHash, "DUPLICATE_SOURCE_ROW"),
  );
  findings.push(
    ...await duplicateFindings(rows, (row) => row.logicalKey, "DUPLICATE_LOGICAL_IDENTITY"),
  );
  const rejected = new Set(
    findings.filter((item) => item.severity === "ERROR" && item.sourceRowHash)
      .map((item) => `${item.sourceSheetName}\0${item.sourceRowNumber}\0${item.sourceCellRange}`),
  );
  for (const row of rows) {
    if (rejected.has(`${row.sourceSheetName}\0${row.sourceRowNumber}\0${row.sourceCellRange}`)) {
      row.candidateDisposition = "QUARANTINED";
    }
  }
  return findings;
}

export function zeroAcceptedFinding(): Promise<ValidationFinding> {
  return finding("ZERO_ACCEPTED_ROWS", "ERROR", "The workbook contains no accepted governed rows.");
}
