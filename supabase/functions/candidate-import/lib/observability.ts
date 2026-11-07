export type ValidationPhase =
  | "validation-request-received"
  | "lease-acquired"
  | "storage-download-complete"
  | "ooxml-preflight-complete"
  | "exceljs-parse-complete"
  | "normalization-complete"
  | "row-validation-complete"
  | "batching-complete"
  | "batch-stage-start"
  | "batch-stage-complete"
  | "execution-fingerprint-complete"
  | "validation-completion-complete";

export interface ValidationPhaseFields {
  compressedBytes?: number;
  expandedBytes?: number;
  zipEntryCount?: number;
  worksheetCount?: number;
  governedRowCount?: number;
  acceptedCount?: number;
  warningCount?: number;
  errorCount?: number;
  quarantinedCount?: number;
  batchNumber?: number;
  batchCount?: number;
  batchRowCount?: number;
  encodedBatchBytes?: number;
}

interface ValidationLogContext {
  requestId: string;
  validationAttemptId: string;
  correlationId: string;
}

export type ValidationLogSink = (serializedRecord: string) => void;

export function createValidationPhaseLogger(
  context: ValidationLogContext,
  sink: ValidationLogSink = console.info,
  clock: () => number = performance.now.bind(performance),
): (phase: ValidationPhase, fields?: ValidationPhaseFields) => void {
  const startedAt = clock();
  let previousAt = startedAt;

  return (phase, fields = {}) => {
    const observedAt = clock();
    const record: Record<string, string | number> = {
      route: "validate",
      category: "validation-phase",
      requestId: context.requestId,
      validationAttemptId: context.validationAttemptId,
      correlationId: context.correlationId,
      phase,
      elapsedMs: Math.round(observedAt - previousAt),
      totalElapsedMs: Math.round(observedAt - startedAt),
    };
    previousAt = observedAt;

    const safeFields: ValidationPhaseFields = {
      compressedBytes: fields.compressedBytes,
      expandedBytes: fields.expandedBytes,
      zipEntryCount: fields.zipEntryCount,
      worksheetCount: fields.worksheetCount,
      governedRowCount: fields.governedRowCount,
      acceptedCount: fields.acceptedCount,
      warningCount: fields.warningCount,
      errorCount: fields.errorCount,
      quarantinedCount: fields.quarantinedCount,
      batchNumber: fields.batchNumber,
      batchCount: fields.batchCount,
      batchRowCount: fields.batchRowCount,
      encodedBatchBytes: fields.encodedBatchBytes,
    };
    for (const [key, value] of Object.entries(safeFields)) {
      if (value !== undefined) record[key] = value;
    }
    try {
      sink(JSON.stringify(record));
    } catch {
      // Observability must never change Candidate import behavior.
    }
  };
}
