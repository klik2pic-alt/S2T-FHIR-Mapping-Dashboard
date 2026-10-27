import ExcelJS from "exceljs";
import {
  LOGICAL_KEY_VERSION,
  type MappingKind,
  MAX_BATCH_BYTES,
  MAX_BATCH_ROWS,
  MAX_COMPRESSED_DEFAULT,
  MAX_EXPANDED_DEFAULT,
  MAX_SHEETS,
  NORMALIZATION_VERSION,
  PARSER_NAME,
  PARSER_VERSION,
  RAW_HASH_SCHEMA,
  RAW_SCHEMA_ID,
  RAW_SCHEMA_VERSION,
  type RawCell,
  RESOURCE_CONFIG_ID,
  SHEET_CONTRACTS,
  type SheetManifestEntry,
  SPEC_VERSION,
  type StagedRow,
  STAGING_SCHEMA,
  type ValidationResult,
} from "./contracts.ts";
import { ImportError } from "./errors.ts";
import {
  canonicalJson,
  columnName,
  digestCanonical,
  identityNorm,
  normalizeText,
  sha256Hex,
} from "./normalization.ts";
import { validateRows, VALIDATION_CONFIGURATION, zeroAcceptedFinding } from "./validation.ts";

const GUIDANCE_IDENTITIES: Record<number, readonly [string, string]> = {
  3: ["GLOBAL_MAPPING_POLICY", "NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING"],
  4: ["MEDICATION_COMPOSITION", "PRESCRIBED_DRUG_INGREDIENT_REPRESENTATION"],
  5: ["DOSAGE_TIMING", "PO_DURATION_CLINICAL_SIGNIFICANCE"],
  6: ["PATIENT_IDENTITY", "CATO_SSN_PATIENT_IDENTIFIER_SEMANTICS"],
  7: ["TREATMENT_PLAN_ACCESS", "PATIENT_IDENTIFIER_FOR_PLAN_RETRIEVAL"],
};

const GUIDANCE_STATUS: Record<string, string> = {
  "אושר": "FINAL",
  "דיון קליני": "OPEN",
  "לא ניתן למפות": "DO NOT MAP",
  "הוחלט לא למפות": "DO NOT MAP",
};

const KNOWN_SHEET_CLASSIFICATION: Record<string, SheetManifestEntry["classification"]> = {
  Profile: "WIP_PROFILE",
  "CATO Route Mapping": "WIP_ROUTE_MAPPING",
  ValueSet: "OUT_OF_SCOPE",
  "דוגמאות ב-JSON": "EXAMPLE_ONLY",
};

export const FROZEN_CONFIGURATION = {
  schema: "candidate-import-configuration-v1",
  specification: SPEC_VERSION,
  parser: `${PARSER_NAME}@${PARSER_VERSION}`,
  rawSchema: `${RAW_SCHEMA_ID}-${RAW_SCHEMA_VERSION}`,
  normalization: NORMALIZATION_VERSION,
  logicalKey: LOGICAL_KEY_VERSION,
  staging: STAGING_SCHEMA,
  limits: {
    maximumCompressedBytes: MAX_COMPRESSED_DEFAULT,
    maximumExpandedBytes: MAX_EXPANDED_DEFAULT,
    maximumSheets: MAX_SHEETS,
    maximumBatchRows: MAX_BATCH_ROWS,
    maximumBatchBytes: MAX_BATCH_BYTES,
  },
  sheets: SHEET_CONTRACTS,
  guidanceIdentities: GUIDANCE_IDENTITIES,
  guidanceStatus: GUIDANCE_STATUS,
  validation: VALIDATION_CONFIGURATION,
};

export async function configurationDigest(): Promise<string> {
  return digestCanonical(FROZEN_CONFIGURATION);
}

function jsonSafeValue(value: ExcelJS.CellValue): RawCell["value"] {
  if (value === null || value === undefined) return null;
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
    return value;
  }
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "object") {
    return JSON.parse(JSON.stringify(value)) as Record<string, unknown>;
  }
  return String(value);
}

function readCell(cell: ExcelJS.Cell, column: string, header: string | null): RawCell {
  const value = cell.value;
  if (value && typeof value === "object" && ("formula" in value || "sharedFormula" in value)) {
    return { column, header, type: "formula", value: jsonSafeValue(value) };
  }
  if (value === null || value === undefined || value === "") {
    return { column, header, type: "blank", value: null };
  }
  if (value instanceof Date) return { column, header, type: "date", value: value.toISOString() };
  if (typeof value === "number") return { column, header, type: "number", value };
  if (typeof value === "boolean") return { column, header, type: "boolean", value };
  if (typeof value === "object" && "error" in value) {
    return { column, header, type: "error", value: jsonSafeValue(value) };
  }
  return { column, header, type: "string", value: jsonSafeValue(value) };
}

function cellText(cell: RawCell): string | null {
  if (cell.type === "blank" || cell.type === "formula") return null;
  if (cell.type === "date") return String(cell.value);
  if (typeof cell.value === "object") {
    const rich = cell.value && "richText" in cell.value
      ? (cell.value.richText as Array<{ text?: string }>).map((part) => part.text ?? "").join("")
      : null;
    const text = rich ?? (cell.value && "text" in cell.value ? String(cell.value.text) : null);
    return text === null ? null : normalizeText(text) || null;
  }
  return normalizeText(cell.value) || null;
}

function asInteger(value: string | null): number | null {
  return value !== null && /^-?\d+$/.test(value) ? Number(value) : null;
}

async function logicalKey(tuple: string[]): Promise<string> {
  return `me:v1:${await sha256Hex(tuple.join("|"))}`;
}

async function buildRow(
  worksheet: ExcelJS.Worksheet,
  rowNumber: number,
  headers: Array<string | null>,
  kind: MappingKind,
): Promise<StagedRow> {
  const width = headers.length;
  const rawCells = Array.from({ length: width }, (_, offset) => {
    const column = columnName(offset + 1);
    return readCell(worksheet.getCell(rowNumber, offset + 1), column, headers[offset]);
  });
  const normalized = rawCells.map((cell) => cellText(cell));
  const range = `A${rowNumber}:${columnName(width)}${rowNumber}`;
  const sourceRowHash = await digestCanonical({
    schema: RAW_HASH_SCHEMA,
    sheet: worksheet.name,
    orderedRawCells: rawCells,
  });
  let decisionStatus = "";
  let components: Record<string, unknown>;
  let subtype: Record<string, unknown>;

  if (kind === "ELEMENT_MAPPING") {
    decisionStatus = normalizeText(normalized[16]).toUpperCase();
    const tuple = [
      kind,
      "CATO",
      "MedicationRequest",
      identityNorm(normalized[8]),
      identityNorm(normalized[0]),
      identityNorm(normalized[1]),
      identityNorm(normalized[2]),
      identityNorm(normalized[3]),
      identityNorm(normalized[5]),
    ];
    components = {
      mappingKind: kind,
      sourceSystem: "CATO",
      fhirResource: "MedicationRequest",
      targetFhirPath: identityNorm(normalized[8]),
      sourceSystemRaw: identityNorm(normalized[0]),
      interfaceType: identityNorm(normalized[1]),
      interfaceName: identityNorm(normalized[2]),
      sourceExpression: identityNorm(normalized[3]),
      fixedValue: identityNorm(normalized[5]),
      canonicalTuple: tuple,
    };
    const cardinality = normalized[9];
    const match = cardinality?.match(/^(0|[1-9]\d*)\.\.(\*|0|[1-9]\d*)$/);
    subtype = {
      targetFhirPath: normalized[8],
      sourceSystemRaw: normalized[0],
      interfaceType: normalized[1],
      interfaceName: normalized[2],
      sourceExpression: normalized[3],
      profileContext: normalized[4],
      fixedValue: normalized[5],
      transformationRule: normalized[6],
      sourceBusinessDefinition: normalized[7],
      cardinalityRaw: cardinality,
      cardinalityMin: match ? Number(match[1]) : null,
      cardinalityMax: match && match[2] !== "*" ? Number(match[2]) : null,
      cardinalityMaxUnbounded: Boolean(match && match[2] === "*"),
      valuesetBinding: normalized[10],
      mandatedCodeSystem: normalized[11],
      irrelevantUnderS2tRaw: normalized[12],
      exampleValue: normalized[13],
      exceptionHandling: normalized[14],
      notes: normalized[15],
    };
  } else if (kind === "STATUS_MAPPING_RULE") {
    decisionStatus = rowNumber === 17 ? "OPEN" : "FINAL";
    const tuple = [
      kind,
      "CATO",
      "MedicationRequest.status",
      identityNorm(normalized[1]),
      identityNorm(normalized[3]),
    ];
    components = {
      mappingKind: kind,
      sourceSystem: "CATO",
      targetFhirPath: "MedicationRequest.status",
      sourceStatusValue: identityNorm(normalized[1]),
      targetStatusValue: identityNorm(normalized[3]),
      canonicalTuple: tuple,
    };
    subtype = {
      sourceStatusValue: normalized[1],
      targetFhirPath: "MedicationRequest.status",
      targetStatusValue: normalized[3],
      sourceSequence: asInteger(normalized[0]),
      sourceBusinessDefinition: normalized[2],
      relatedResourceNote: normalized[4],
      transformationRule: normalized[5],
      mappingEvidenceStatusRaw: normalized[6],
      notes: normalized[7],
    };
  } else {
    decisionStatus = GUIDANCE_STATUS[normalizeText(normalized[0])] ?? "";
    const translatedIdentity = GUIDANCE_IDENTITIES[rowNumber];
    const [guidanceScope, decisionTopic] = translatedIdentity ??
      ["GLOBAL_MAPPING_POLICY", "NO_SOURCE_NO_INFERENCE_AND_CHOICE_HANDLING"];
    const identityScope = translatedIdentity ? guidanceScope : normalized[2];
    const identityTopic = translatedIdentity ? decisionTopic : normalized[1];
    const tuple = [
      kind,
      "CATO",
      "MedicationRequest",
      identityNorm(identityScope),
      identityNorm(identityTopic),
    ];
    components = {
      mappingKind: kind,
      sourceSystem: "CATO",
      fhirResource: "MedicationRequest",
      targetFhirPathOrScope: identityNorm(identityScope),
      decisionTopic: identityNorm(identityTopic),
      canonicalTuple: tuple,
    };
    subtype = {
      guidanceScope,
      decisionTopic,
      guidanceText: normalized[3],
      guidanceStatusRaw: normalized[0],
      targetFhirPathOrScopeRaw: normalized[2],
      decisionTopicRaw: normalized[1],
      notes: normalized[4],
      reviewNotes: normalized[5],
    };
  }
  return {
    sourceSheetName: worksheet.name,
    sourceRowNumber: rowNumber,
    sourceCellRange: range,
    rawSchemaId: RAW_SCHEMA_ID,
    rawSchemaVersion: RAW_SCHEMA_VERSION,
    rawSourceRow: {
      schema: RAW_HASH_SCHEMA,
      sheet: worksheet.name,
      row: rowNumber,
      range,
      orderedRawCells: rawCells,
      normalizedValues: normalized.map((value) => value ?? ""),
    },
    sourceRowHash,
    normalizationAlgorithmVersion: NORMALIZATION_VERSION,
    mappingKind: kind,
    candidateDisposition: "ACCEPTED",
    decisionStatus,
    logicalKeyAlgorithmVersion: LOGICAL_KEY_VERSION,
    logicalKey: await logicalKey(components.canonicalTuple as string[]),
    logicalKeyComponents: components,
    subtype,
  };
}

function manifestFor(
  workbook: ExcelJS.Workbook,
  headerEvidence: Map<string, { raw: RawCell[]; normalized: string[] }>,
): SheetManifestEntry[] {
  return workbook.worksheets.map((sheet, index) => {
    const contract = SHEET_CONTRACTS[sheet.name as keyof typeof SHEET_CONTRACTS];
    return {
      sheetName: sheet.name,
      sheetOrder: index + 1,
      classification: contract?.classification ?? KNOWN_SHEET_CLASSIFICATION[sheet.name] ??
        "OUT_OF_SCOPE",
      isPresent: true,
      isAuthoritative: Boolean(contract),
      headerRowNumber: contract?.headerRow ?? null,
      candidateRange: contract?.candidateRange ?? null,
      governedColumnRange: contract?.governedColumnRange ?? null,
      candidateRowCount: contract
        ? contract.ranges.reduce((sum, [start, end]) => sum + end - start + 1, 0)
        : null,
      notes: contract ? null : "Inventoried but excluded from governed import rows",
      ...(headerEvidence.has(sheet.name)
        ? {
          rawHeaders: headerEvidence.get(sheet.name)!.raw,
          normalizedHeaders: headerEvidence.get(sheet.name)!.normalized,
        }
        : {}),
    };
  });
}

export async function parseAndValidateWorkbook(
  bytes: Uint8Array,
  context: { requestId: string; validationAttemptId: string; versionLabel: string },
): Promise<ValidationResult> {
  const workbook = new ExcelJS.Workbook();
  workbook.calcProperties.fullCalcOnLoad = false;
  try {
    await workbook.xlsx.load(bytes as unknown as ExcelJS.Buffer);
  } catch {
    throw new ImportError(
      "FILE_TYPE_INVALID",
      "The XLSX workbook cannot be parsed.",
      false,
      400,
      context.requestId,
    );
  }
  const rows: StagedRow[] = [];
  const headerEvidence = new Map<string, { raw: RawCell[]; normalized: string[] }>();
  for (const [sheetName, contract] of Object.entries(SHEET_CONTRACTS)) {
    const sheet = workbook.getWorksheet(sheetName);
    if (!sheet) {
      throw new ImportError(
        "FILE_SCHEMA_INVALID",
        `Required sheet is missing: ${sheetName}`,
        false,
        400,
        context.requestId,
      );
    }
    const rawHeaders = Array.from(
      { length: contract.columns },
      (_, offset) =>
        readCell(sheet.getCell(contract.headerRow, offset + 1), columnName(offset + 1), null),
    );
    const headers = rawHeaders.map(cellText);
    if (
      canonicalJson(headers.map(normalizeText)) !==
        canonicalJson([...contract.headers].map(normalizeText))
    ) {
      throw new ImportError(
        "FILE_SCHEMA_INVALID",
        `Governed headers do not match: ${sheetName}`,
        false,
        400,
        context.requestId,
      );
    }
    headerEvidence.set(sheetName, {
      raw: rawHeaders,
      normalized: headers.map((header) => normalizeText(header)),
    });
    for (const [start, end] of contract.ranges) {
      for (let rowNumber = start; rowNumber <= end; rowNumber++) {
        rows.push(await buildRow(sheet, rowNumber, headers, contract.mappingKind));
      }
    }
  }
  const findings = await validateRows(rows);
  const summary = {
    candidateCount: rows.length,
    acceptedCount: rows.filter((row) => row.candidateDisposition === "ACCEPTED").length,
    warningCount:
      findings.filter((finding) =>
        finding.severity === "WARNING" || finding.severity === "ACCEPTED_EXCEPTION"
      ).length,
    errorCount: findings.filter((finding) => finding.severity === "ERROR").length,
    quarantinedCount: rows.filter((row) => row.candidateDisposition === "QUARANTINED").length,
  };
  if (summary.acceptedCount === 0) {
    findings.push(await zeroAcceptedFinding());
    summary.errorCount++;
  }
  return {
    schema: STAGING_SCHEMA,
    requestId: context.requestId,
    validationAttemptId: context.validationAttemptId,
    resourceConfigId: RESOURCE_CONFIG_ID,
    sourceSystem: "CATO",
    fhirResource: "MedicationRequest",
    parser: { name: PARSER_NAME, version: PARSER_VERSION },
    importSpecificationVersion: SPEC_VERSION,
    configurationDigest: await configurationDigest(),
    artifactSha256: await sha256Hex(bytes),
    versionLabel: context.versionLabel,
    sheetManifest: manifestFor(workbook, headerEvidence),
    rows,
    findings,
    summary,
  };
}
