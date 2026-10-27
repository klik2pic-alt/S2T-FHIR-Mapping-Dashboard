export const SPEC_VERSION = "CATO-MEDICATIONREQUEST-XLSX-v1";
export const PARSER_NAME = "exceljs";
export const PARSER_VERSION = "4.4.0";
export const BUCKET_DEFAULT = "s2t-candidate-imports";
export const MAX_COMPRESSED_DEFAULT = 10_485_760;
export const MAX_EXPANDED_DEFAULT = 52_428_800;
export const MAX_SHEETS = 64;
export const MAX_BATCH_ROWS = 250;
export const MAX_BATCH_BYTES = 2_097_152;
export const XLSX_MEDIA_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
export const RESOURCE_CONFIG_ID = "medication-request-cato";
export const RAW_SCHEMA_ID = "candidate-import-raw-row";
export const RAW_SCHEMA_VERSION = "v1";
export const RAW_HASH_SCHEMA = "candidate-import-raw-row-v1";
export const NORMALIZATION_VERSION = "nfkc-ws-v1";
export const LOGICAL_KEY_VERSION = "v1";
export const STAGING_SCHEMA = "candidate-import-staging-v1";

export const SHEET_CONTRACTS = {
  "S2T MedicationRequestCato": {
    order: 2,
    headerRow: 1,
    ranges: [[2, 239]] as const,
    columns: 17,
    governedColumnRange: "A:Q",
    candidateRange: "A2:Q239",
    classification: "AUTHORITATIVE",
    mappingKind: "ELEMENT_MAPPING",
    headers: [
      "Source System",
      "Interface Type",
      "Interface Name",
      "Field / Expression",
      "Profile where element is defined",
      "Fixed Value",
      "Transformation Rules",
      "Source Business Definition",
      "Target Element name (FHIR)",
      "Cardinality",
      "Bindings to ValueSet",
      "Mandated code system",
      "Irrelevant under s2t",
      "Example",
      "Exceptions handling",
      "Notes",
      "Decision Status",
    ],
  },
  "Cato Status Mapping": {
    order: 1,
    headerRow: 5,
    ranges: [[7, 13], [15, 15], [17, 17]] as const,
    columns: 8,
    governedColumnRange: "A:H",
    candidateRange: "A7:H13;A15:H15;A17:H17",
    classification: "AUTHORITATIVE",
    mappingKind: "STATUS_MAPPING_RULE",
    headers: [
      "#",
      "CATO Status",
      "משמעות קלינית",
      "FHIR status",
      "MedAdministration?",
      "הערות / כללי מיפוי",
      "סטטוס מיפוי",
      "",
    ],
  },
  "הנחיות נוספות מעודכן": {
    order: 6,
    headerRow: 2,
    ranges: [[3, 7], [9, 49]] as const,
    columns: 6,
    governedColumnRange: "A:F",
    candidateRange: "A3:F7;A9:F49",
    classification: "AUTHORITATIVE",
    mappingKind: "GOVERNANCE_GUIDANCE",
    headers: [
      "סטטוס/חומרה",
      "נושא ההחלטה",
      "אלמנט FHIR",
      "הנחות יסוד",
      "הערות",
      "הערות 17.09.2026",
    ],
  },
} as const;

export type MappingKind =
  | "ELEMENT_MAPPING"
  | "STATUS_MAPPING_RULE"
  | "GOVERNANCE_GUIDANCE";
export type CandidateDisposition = "ACCEPTED" | "QUARANTINED";
export type FindingSeverity = "ERROR" | "WARNING" | "ACCEPTED_EXCEPTION";
export type FindingCode =
  | "DUPLICATE_SOURCE_ROW"
  | "DUPLICATE_LOGICAL_IDENTITY"
  | "REQUIRED_TARGET_FHIR_PATH"
  | "INVALID_CARDINALITY"
  | "UNKNOWN_DECISION_STATUS"
  | "STATUS_MAPPING_CONTRACT"
  | "GOVERNANCE_GUIDANCE_CONTRACT"
  | "ZERO_ACCEPTED_ROWS"
  | "CLEAN_IMPORT_INTEGRITY";

export interface RawCell {
  column: string;
  header: string | null;
  type: "blank" | "string" | "number" | "boolean" | "date" | "error" | "formula";
  value: string | number | boolean | null | Record<string, unknown>;
}

export interface StagedRow {
  sourceSheetName: string;
  sourceRowNumber: number;
  sourceCellRange: string;
  rawSchemaId: typeof RAW_SCHEMA_ID;
  rawSchemaVersion: typeof RAW_SCHEMA_VERSION;
  rawSourceRow: {
    schema: typeof RAW_HASH_SCHEMA;
    sheet: string;
    row: number;
    range: string;
    orderedRawCells: RawCell[];
    normalizedValues: string[];
  };
  sourceRowHash: string;
  normalizationAlgorithmVersion: typeof NORMALIZATION_VERSION;
  mappingKind: MappingKind;
  candidateDisposition: CandidateDisposition;
  decisionStatus: string;
  logicalKeyAlgorithmVersion: typeof LOGICAL_KEY_VERSION;
  logicalKey: string;
  logicalKeyComponents: Record<string, unknown>;
  subtype: Record<string, unknown>;
}

export interface ValidationFinding {
  code: FindingCode;
  severity: FindingSeverity;
  safeMessage: string;
  sourceSheetName?: string;
  sourceRowNumber?: number;
  sourceCellRange?: string;
  field?: string;
  sourceRowHash?: string;
  collisionGroup?: string;
  fingerprint: string;
  evidence: Record<string, unknown>;
  internalDiagnosticReference: string;
}

export interface SheetManifestEntry {
  sheetName: string;
  sheetOrder: number;
  classification:
    | "AUTHORITATIVE"
    | "WIP_PROFILE"
    | "WIP_ROUTE_MAPPING"
    | "EXAMPLE_ONLY"
    | "OUT_OF_SCOPE";
  isPresent: boolean;
  isAuthoritative: boolean;
  headerRowNumber: number | null;
  candidateRange: string | null;
  governedColumnRange: string | null;
  candidateRowCount: number | null;
  notes: string | null;
  rawHeaders?: RawCell[];
  normalizedHeaders?: string[];
}

export interface ValidationResult {
  schema: typeof STAGING_SCHEMA;
  requestId: string;
  validationAttemptId: string;
  resourceConfigId: typeof RESOURCE_CONFIG_ID;
  sourceSystem: "CATO";
  fhirResource: "MedicationRequest";
  parser: { name: typeof PARSER_NAME; version: typeof PARSER_VERSION };
  importSpecificationVersion: typeof SPEC_VERSION;
  configurationDigest: string;
  artifactSha256: string;
  versionLabel: string;
  sheetManifest: SheetManifestEntry[];
  rows: StagedRow[];
  findings: ValidationFinding[];
  summary: {
    candidateCount: number;
    acceptedCount: number;
    warningCount: number;
    errorCount: number;
    quarantinedCount: number;
  };
}

export interface CandidateImportConfig {
  supabaseUrl: string;
  anonKey: string;
  serviceRoleKey: string;
  serviceActorId: string;
  bucket: string;
  spec: string;
  maxCompressedBytes: number;
  maxExpandedBytes: number;
}
