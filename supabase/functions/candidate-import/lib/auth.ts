import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { CandidateImportConfig } from "./contracts.ts";
import { ImportError } from "./errors.ts";

export interface AuthenticatedCaller {
  jwt: string;
  userId: string;
  client: SupabaseClient;
}

export function bearerToken(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer\s+([^\s]+)$/i);
  if (!match) {
    throw new ImportError("CAPABILITY_REQUIRED", "Authentication is required.", false, 401);
  }
  return match[1];
}

export async function authenticateCaller(
  request: Request,
  config: CandidateImportConfig,
): Promise<AuthenticatedCaller> {
  const jwt = bearerToken(request);
  const client = createClient(config.supabaseUrl, config.anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const { data, error } = await client.auth.getUser(jwt);
  if (error || !data.user) {
    throw new ImportError("CAPABILITY_REQUIRED", "Authentication is required.", false, 401);
  }
  return { jwt, userId: data.user.id, client };
}
