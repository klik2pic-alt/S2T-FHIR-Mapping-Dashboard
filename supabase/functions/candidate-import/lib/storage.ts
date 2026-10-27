import type { SupabaseClient } from "@supabase/supabase-js";
import type { CandidateImportConfig } from "./contracts.ts";
import { ImportError } from "./errors.ts";

export function objectPath(requestId: string): string {
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(requestId)
  ) {
    throw new ImportError(
      "IMPORT_CONFLICT",
      "Invalid import request identifier.",
      false,
      400,
      requestId,
    );
  }
  return `medication-request-cato/${requestId.toLowerCase()}/source.xlsx`;
}

export async function createUploadTarget(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
): Promise<Record<string, unknown>> {
  const path = objectPath(requestId);
  const { data, error } = await service.storage.from(config.bucket).createSignedUploadUrl(path, {
    upsert: false,
  });
  if (error || !data) {
    throw new ImportError("INTERNAL_IMPORT_ERROR", undefined, false, 500, requestId);
  }
  return {
    signedUrl: data.signedUrl,
    upsert: false,
    expiresInSeconds: 7200,
  };
}

export async function downloadObject(
  service: SupabaseClient,
  config: CandidateImportConfig,
  requestId: string,
): Promise<Uint8Array> {
  const { data, error } = await service.storage.from(config.bucket).download(objectPath(requestId));
  if (error || !data) {
    throw new ImportError(
      "IMPORT_CONFLICT",
      "The expected upload is not available.",
      true,
      409,
      requestId,
    );
  }
  return new Uint8Array(await data.arrayBuffer());
}
