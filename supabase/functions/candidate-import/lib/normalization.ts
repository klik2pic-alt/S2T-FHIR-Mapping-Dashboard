const encoder = new TextEncoder();

export function normalizeText(value: unknown): string {
  if (value === null || value === undefined) return "";
  return String(value)
    .normalize("NFKC")
    .replace(/\u00a0/g, " ")
    .replace(/\r\n?/g, "\n")
    .replace(/\s+/gu, " ")
    .trim();
}

export function identityNorm(value: unknown): string {
  return normalizeText(value).toLowerCase();
}

export function canonicalJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string" || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new TypeError("JCS forbids non-finite numbers");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const object = value as Record<string, unknown>;
    return `{${
      Object.keys(object).sort().map((key) =>
        `${JSON.stringify(key)}:${canonicalJson(object[key])}`
      ).join(",")
    }}`;
  }
  throw new TypeError(`JCS cannot serialize ${typeof value}`);
}

export async function sha256Hex(value: Uint8Array | string): Promise<string> {
  const bytes = typeof value === "string" ? encoder.encode(value) : value;
  const stableBytes = new Uint8Array(bytes.byteLength);
  stableBytes.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", stableBytes.buffer);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function digestCanonical(value: unknown): Promise<string> {
  return sha256Hex(canonicalJson(value));
}

export function utf8Size(value: unknown): number {
  return encoder.encode(canonicalJson(value)).byteLength;
}

export function hexBytea(hex: string): string {
  if (!/^[0-9a-f]{64}$/.test(hex)) throw new TypeError("Expected lowercase SHA-256 hex");
  return `\\x${hex}`;
}

export function columnName(index: number): string {
  let value = index;
  let output = "";
  while (value > 0) {
    value--;
    output = String.fromCharCode(65 + (value % 26)) + output;
    value = Math.floor(value / 26);
  }
  return output;
}
