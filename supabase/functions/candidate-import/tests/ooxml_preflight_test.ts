import { strToU8, zipSync } from "fflate";
import { assert, rejects } from "./assert.ts";
import { preflightOoxml } from "../lib/ooxml-preflight.ts";
import { workbookFixture } from "./workbook-fixture.ts";

function withUnsupportedCentralCompression(bytes: Uint8Array): Uint8Array {
  const copy = bytes.slice();
  const view = new DataView(copy.buffer);
  for (let offset = 0; offset <= copy.byteLength - 46; offset++) {
    if (view.getUint32(offset, true) === 0x02014b50) {
      view.setUint16(offset + 10, 99, true);
      return copy;
    }
  }
  throw new Error("Fixture central directory was not found");
}

Deno.test("malformed ZIP and compressed/expanded limits are rejected", async () => {
  await rejects(() => preflightOoxml(new Uint8Array([1, 2, 3]), 100, 100), /supported XLSX/);
  const bytes = await workbookFixture();
  await rejects(() => preflightOoxml(bytes, 1, 52_428_800), /allowed size/);
  await rejects(() => preflightOoxml(bytes, 10_485_760, 100), /expanded workbook/);
  await rejects(
    () => preflightOoxml(withUnsupportedCentralCompression(bytes), 10_485_760, 52_428_800),
    /compression method/,
  );
});

Deno.test("macro and external relationship content is rejected", async () => {
  const base = {
    "[Content_Types].xml": strToU8(
      '<Types><Override ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>',
    ),
    "_rels/.rels": strToU8(
      '<Relationships><Relationship Id="rId1" Type="x" Target="xl/workbook.xml"/></Relationships>',
    ),
    "xl/workbook.xml": strToU8('<workbook><sheets><sheet name="x"/></sheets></workbook>'),
  };
  const macro = zipSync({ ...base, "xl/vbaProject.bin": new Uint8Array([1]) });
  await rejects(() => preflightOoxml(macro, 10_485_760, 52_428_800), /Active or external/);
  const external = zipSync({
    ...base,
    "_rels/.rels": strToU8(
      '<Relationships><Relationship Id="rId1" Type="x" Target="https://example.invalid" TargetMode="External"/></Relationships>',
    ),
  });
  await rejects(() => preflightOoxml(external, 10_485_760, 52_428_800), /External OOXML/);
  const disguisedExternal = zipSync({
    ...base,
    "_rels/.rels": strToU8(
      '<Relationships><Relationship Id="rId1" Type="x" Target="https://example.invalid"/></Relationships>',
    ),
  });
  await rejects(
    () => preflightOoxml(disguisedExternal, 10_485_760, 52_428_800),
    /External OOXML/,
  );
  assert(true);
});

Deno.test("unsafe ZIP paths and absent internal relationship targets are rejected", async () => {
  const traversal = zipSync({
    "../evil": strToU8("x"),
    "[Content_Types].xml": strToU8("x"),
  });
  await rejects(() => preflightOoxml(traversal, 10_485_760, 52_428_800), /Unsafe XLSX/);
  const missingTarget = zipSync({
    "[Content_Types].xml": strToU8(
      '<Types><Override ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>',
    ),
    "_rels/.rels": strToU8(
      '<Relationships><Relationship Id="rId1" Type="x" Target="xl/missing.xml"/></Relationships>',
    ),
    "xl/workbook.xml": strToU8('<workbook><sheets><sheet name="x"/></sheets></workbook>'),
  });
  await rejects(
    () => preflightOoxml(missingTarget, 10_485_760, 52_428_800),
    /target is missing/,
  );
});
