import { unzipSync } from "fflate";
import { ImportError } from "./errors.ts";
import { MAX_SHEETS, XLSX_MEDIA_TYPE } from "./contracts.ts";

const decoder = new TextDecoder();
const ZIP_LOCAL = 0x04034b50;
const ZIP_CENTRAL = 0x02014b50;
const ZIP_EOCD = 0x06054b50;

export interface ZipEntryMetadata {
  path: string;
  compressedSize: number;
  expandedSize: number;
  compressionMethod: number;
}

export interface OoxmlPreflightResult {
  mediaType: typeof XLSX_MEDIA_TYPE;
  sheetCount: number;
  compressedBytes: number;
  expandedBytes: number;
  entries: ZipEntryMetadata[];
}

function findEocd(view: DataView): number {
  const minimum = Math.max(0, view.byteLength - 65_557);
  for (let offset = view.byteLength - 22; offset >= minimum; offset--) {
    if (view.getUint32(offset, true) === ZIP_EOCD) return offset;
  }
  return -1;
}

function safePath(path: string): boolean {
  if (!path || path.includes("\\") || path.startsWith("/") || path.includes(":")) return false;
  const normalized = path.endsWith("/") ? path.slice(0, -1) : path;
  if (!normalized) return false;
  const segments = normalized.split("/");
  return !segments.some((segment) => segment === ".." || segment === "." || segment === "");
}

export function inspectZipDirectory(
  bytes: Uint8Array,
  maxExpandedBytes: number,
): ZipEntryMetadata[] {
  if (
    bytes.byteLength < 22 ||
    new DataView(bytes.buffer, bytes.byteOffset).getUint32(0, true) !== ZIP_LOCAL
  ) {
    throw new ImportError("FILE_TYPE_INVALID");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const eocd = findEocd(view);
  if (eocd < 0) throw new ImportError("FILE_TYPE_INVALID", "The XLSX ZIP directory is missing.");
  const disk = view.getUint16(eocd + 4, true);
  const centralDisk = view.getUint16(eocd + 6, true);
  const entriesOnDisk = view.getUint16(eocd + 8, true);
  const entryCount = view.getUint16(eocd + 10, true);
  const centralSize = view.getUint32(eocd + 12, true);
  const centralOffset = view.getUint32(eocd + 16, true);
  if (
    disk !== 0 || centralDisk !== 0 || entriesOnDisk !== entryCount || entryCount === 0 ||
    entryCount === 0xffff || centralOffset === 0xffffffff || centralSize === 0xffffffff ||
    centralOffset + centralSize > eocd
  ) {
    throw new ImportError("FILE_TYPE_INVALID", "Unsupported or malformed XLSX ZIP directory.");
  }

  const entries: ZipEntryMetadata[] = [];
  const paths = new Set<string>();
  let expandedTotal = 0;
  let offset = centralOffset;
  for (let index = 0; index < entryCount; index++) {
    if (offset + 46 > eocd || view.getUint32(offset, true) !== ZIP_CENTRAL) {
      throw new ImportError("FILE_TYPE_INVALID", "Malformed XLSX ZIP entry.");
    }
    const flags = view.getUint16(offset + 8, true);
    const method = view.getUint16(offset + 10, true);
    const compressedSize = view.getUint32(offset + 20, true);
    const expandedSize = view.getUint32(offset + 24, true);
    const nameLength = view.getUint16(offset + 28, true);
    const extraLength = view.getUint16(offset + 30, true);
    const commentLength = view.getUint16(offset + 32, true);
    if (flags & 0x1) {
      throw new ImportError("FILE_TYPE_INVALID", "Encrypted workbooks are not accepted.");
    }
    if (method !== 0 && method !== 8) {
      throw new ImportError("FILE_TYPE_INVALID", "Unsupported XLSX ZIP compression method.");
    }
    const end = offset + 46 + nameLength + extraLength + commentLength;
    if (end > eocd) throw new ImportError("FILE_TYPE_INVALID", "Malformed XLSX ZIP entry lengths.");
    const path = decoder.decode(bytes.subarray(offset + 46, offset + 46 + nameLength));
    const key = path.toLowerCase();
    if (!safePath(path)) throw new ImportError("FILE_TYPE_INVALID", "Unsafe XLSX ZIP path.");
    if (paths.has(key)) throw new ImportError("FILE_TYPE_INVALID", "Duplicate XLSX ZIP path.");
    paths.add(key);
    expandedTotal += expandedSize;
    if (
      expandedTotal > maxExpandedBytes || expandedSize > maxExpandedBytes ||
      (expandedSize > 10_485_760 && compressedSize > 0 && expandedSize / compressedSize > 1000)
    ) {
      throw new ImportError("FILE_TOO_LARGE", "The expanded workbook exceeds the allowed size.");
    }
    entries.push({ path, compressedSize, expandedSize, compressionMethod: method });
    offset = end;
  }
  if (offset !== centralOffset + centralSize) {
    throw new ImportError("FILE_TYPE_INVALID", "XLSX ZIP directory size is inconsistent.");
  }
  return entries;
}

function xmlText(files: Record<string, Uint8Array>, path: string): string {
  const bytes = files[path];
  if (!bytes) throw new ImportError("FILE_TYPE_INVALID", `Required OOXML part is missing: ${path}`);
  return decoder.decode(bytes);
}

function relationshipSourceDirectory(relsPath: string): string {
  if (relsPath === "_rels/.rels") return "";
  const marker = "/_rels/";
  const markerAt = relsPath.lastIndexOf(marker);
  if (markerAt < 0 || !relsPath.endsWith(".rels")) {
    throw new ImportError("FILE_TYPE_INVALID", "Malformed OOXML relationship path.");
  }
  return relsPath.slice(0, markerAt + 1);
}

function resolveRelationshipTarget(relsPath: string, rawTarget: string): string {
  let target: string;
  try {
    target = decodeURIComponent(rawTarget).replace(/&amp;/g, "&");
  } catch {
    throw new ImportError("FILE_TYPE_INVALID", "Malformed OOXML relationship target.");
  }
  if (
    !target || target.includes("\\") || target.includes("?") || target.includes("#") ||
    /^[a-z][a-z0-9+.-]*:/i.test(target) || target.startsWith("//")
  ) {
    throw new ImportError("FILE_TYPE_INVALID", "External OOXML relationships are not accepted.");
  }
  const joined = target.startsWith("/")
    ? target.slice(1)
    : `${relationshipSourceDirectory(relsPath)}${target}`;
  const segments: string[] = [];
  for (const segment of joined.split("/")) {
    if (!segment || segment === ".") continue;
    if (segment === "..") {
      if (!segments.length) {
        throw new ImportError("FILE_TYPE_INVALID", "Unsafe OOXML relationship target.");
      }
      segments.pop();
    } else {
      segments.push(segment);
    }
  }
  if (!segments.length) {
    throw new ImportError("FILE_TYPE_INVALID", "Malformed OOXML relationship target.");
  }
  return segments.join("/");
}

function validateRelationships(files: Record<string, Uint8Array>): void {
  for (const [path, bytes] of Object.entries(files)) {
    if (!path.endsWith(".rels")) continue;
    const xml = decoder.decode(bytes);
    if (
      !/<(?:[A-Za-z_][\w.-]*:)?Relationships\b[^>]*>/i.test(xml) ||
      /<(?:[A-Za-z_][\w.-]*:)?parsererror\b/i.test(xml)
    ) {
      throw new ImportError("FILE_TYPE_INVALID", "Malformed OOXML relationships.");
    }
    const relationships = [
      ...xml.matchAll(/<(?:[A-Za-z_][\w.-]*:)?Relationship\b([^>]*)\/?\s*>/gi),
    ];
    if (relationships.length === 0) {
      throw new ImportError("FILE_TYPE_INVALID", "Malformed OOXML relationships.");
    }
    for (const match of relationships) {
      const attributes = match[1];
      if (
        !/\bId\s*=\s*["'][^"']+["']/i.test(attributes) ||
        !/\bType\s*=\s*["'][^"']+["']/i.test(attributes) ||
        !/\bTarget\s*=\s*["'][^"']+["']/i.test(attributes)
      ) {
        throw new ImportError("FILE_TYPE_INVALID", "Malformed OOXML relationship entry.");
      }
      if (/\bTargetMode\s*=\s*["']External["']/i.test(attributes)) {
        throw new ImportError(
          "FILE_TYPE_INVALID",
          "External OOXML relationships are not accepted.",
        );
      }
      const target = attributes.match(/\bTarget\s*=\s*["']([^"']+)["']/i)?.[1] ?? "";
      const resolved = resolveRelationshipTarget(path, target);
      if (!Object.hasOwn(files, resolved)) {
        throw new ImportError("FILE_TYPE_INVALID", "OOXML relationship target is missing.");
      }
    }
  }
}

export function preflightOoxml(
  bytes: Uint8Array,
  maxCompressedBytes: number,
  maxExpandedBytes: number,
): OoxmlPreflightResult {
  if (bytes.byteLength > maxCompressedBytes) throw new ImportError("FILE_TOO_LARGE");
  const entries = inspectZipDirectory(bytes, maxExpandedBytes);
  const paths = new Set(entries.map((entry) => entry.path));
  for (const required of ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml"]) {
    if (!paths.has(required)) {
      throw new ImportError("FILE_TYPE_INVALID", "Required OOXML parts are missing.");
    }
  }
  const suspicious = entries.find(({ path }) =>
    /(^|\/)(vbaProject\.bin|activeX|embeddings|externalLinks|oleObject)/i.test(path)
  );
  if (suspicious) {
    throw new ImportError(
      "FILE_TYPE_INVALID",
      "Active or external workbook content is not accepted.",
    );
  }

  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(bytes);
  } catch {
    throw new ImportError("FILE_TYPE_INVALID", "The XLSX ZIP package cannot be decompressed.");
  }
  const contentTypes = xmlText(files, "[Content_Types].xml");
  if (
    /macroEnabled|vnd\.ms-excel|vbaProject|activeX|oleObject/i.test(contentTypes) ||
    !contentTypes.includes(
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
    )
  ) {
    throw new ImportError("FILE_TYPE_INVALID", "Unsupported or macro-enabled workbook type.");
  }
  validateRelationships(files);
  for (const [path, content] of Object.entries(files)) {
    if (!path.endsWith(".xml") && !path.endsWith(".rels")) continue;
    const xml = decoder.decode(content);
    if (/<(?:[A-Za-z_][\w.-]*:)?(?:externalLink|ddeLink|oleObject)\b/i.test(xml)) {
      throw new ImportError("FILE_TYPE_INVALID", "External workbook references are not accepted.");
    }
  }
  const workbookXml = xmlText(files, "xl/workbook.xml");
  const sheetCount = [...workbookXml.matchAll(/<sheet\b/gi)].length;
  if (sheetCount === 0 || sheetCount > MAX_SHEETS) {
    throw new ImportError(
      "FILE_SCHEMA_INVALID",
      "Workbook sheet count is outside the governed limit.",
    );
  }
  return {
    mediaType: XLSX_MEDIA_TYPE,
    sheetCount,
    compressedBytes: bytes.byteLength,
    expandedBytes: entries.reduce((sum, entry) => sum + entry.expandedSize, 0),
    entries,
  };
}
