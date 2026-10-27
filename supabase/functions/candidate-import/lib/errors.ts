export type PublicErrorCode =
  | "FILE_TYPE_INVALID"
  | "FILE_SCHEMA_INVALID"
  | "FILE_TOO_LARGE"
  | "DUPLICATE_ROW_IDENTITY"
  | "IMPORT_VALIDATION_FAILED"
  | "ZERO_ACCEPTED_ROWS"
  | "CANDIDATE_CHANGED"
  | "CAPABILITY_REQUIRED"
  | "IMPORT_CONFLICT"
  | "VERSION_LABEL_CONFLICT"
  | "INTERNAL_IMPORT_ERROR";

const STATUS: Record<PublicErrorCode, number> = {
  FILE_TYPE_INVALID: 400,
  FILE_SCHEMA_INVALID: 400,
  FILE_TOO_LARGE: 413,
  DUPLICATE_ROW_IDENTITY: 422,
  IMPORT_VALIDATION_FAILED: 422,
  ZERO_ACCEPTED_ROWS: 422,
  CANDIDATE_CHANGED: 409,
  CAPABILITY_REQUIRED: 403,
  IMPORT_CONFLICT: 409,
  VERSION_LABEL_CONFLICT: 409,
  INTERNAL_IMPORT_ERROR: 500,
};

const MESSAGES: Record<PublicErrorCode, string> = {
  FILE_TYPE_INVALID: "The uploaded file is not a supported XLSX workbook.",
  FILE_SCHEMA_INVALID: "The workbook does not match the governed import specification.",
  FILE_TOO_LARGE: "The workbook exceeds the allowed size.",
  DUPLICATE_ROW_IDENTITY: "The workbook contains duplicate governed row identities.",
  IMPORT_VALIDATION_FAILED: "The workbook did not pass governed validation.",
  ZERO_ACCEPTED_ROWS: "The workbook contains no accepted governed rows.",
  CANDIDATE_CHANGED: "The Candidate changed; refresh before retrying.",
  CAPABILITY_REQUIRED: "The governed account is not authorized for this operation.",
  IMPORT_CONFLICT: "The import request conflicts with its current state.",
  VERSION_LABEL_CONFLICT: "The mapping version label is already reserved.",
  INTERNAL_IMPORT_ERROR: "The import could not be completed.",
};

export class ImportError extends Error {
  readonly reference: string;
  constructor(
    readonly code: PublicErrorCode,
    message = MESSAGES[code],
    readonly retryable = false,
    readonly status = STATUS[code],
    readonly requestId: string | null = null,
    reference: string = crypto.randomUUID(),
  ) {
    super(message);
    this.name = "ImportError";
    this.reference = reference;
  }
}

export function mapDatabaseError(error: unknown, requestId: string | null): ImportError {
  const source = error as { code?: string; message?: string } | null;
  const raw = source?.message ?? "";
  const known = Object.keys(MESSAGES).find((code) => raw.startsWith(`${code}:`)) as
    | PublicErrorCode
    | undefined;
  if (known) return new ImportError(known, MESSAGES[known], false, STATUS[known], requestId);
  if (source?.code === "42501") {
    return new ImportError("CAPABILITY_REQUIRED", undefined, false, 403, requestId);
  }
  if (source?.code === "40001") {
    return new ImportError("CANDIDATE_CHANGED", undefined, true, 409, requestId);
  }
  if (source?.code === "23505") {
    return new ImportError("IMPORT_CONFLICT", undefined, false, 409, requestId);
  }
  if (source?.code === "P0002") {
    return new ImportError("IMPORT_CONFLICT", "Import request not found.", false, 404, requestId);
  }
  return new ImportError("INTERNAL_IMPORT_ERROR", undefined, false, 500, requestId);
}

export function errorResponse(error: ImportError): Response {
  return Response.json({
    error: {
      code: error.code,
      message: error.message,
      retryable: error.retryable,
      requestId: error.requestId,
      reference: error.reference,
    },
  }, { status: error.status });
}
