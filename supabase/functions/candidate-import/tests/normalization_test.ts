import { assert, equal } from "./assert.ts";
import { canonicalJson, digestCanonical, normalizeText } from "../lib/normalization.ts";

Deno.test("header normalization is NFKC, NBSP-aware, multiline, and case-sensitive", () => {
  equal(normalizeText("Ａ\u00a0 B\r\nC  D"), "A B C D");
  equal(normalizeText("FHIR"), "FHIR");
  assert(normalizeText("FHIR") !== normalizeText("fhir"));
});

Deno.test("canonical JSON sorts object properties recursively", async () => {
  equal(canonicalJson({ z: 1, a: { y: 2, b: 3 } }), '{"a":{"b":3,"y":2},"z":1}');
  equal(await digestCanonical({ b: 2, a: 1 }), await digestCanonical({ a: 1, b: 2 }));
});

Deno.test("canonical JSON follows deterministic JCS primitives and UTF-16 property order", () => {
  equal(
    canonicalJson({ "\ud83d\ude00": -0, "\u0080": 1, a: [true, null, "\n"] }),
    '{"a":[true,null,"\\n"],"\u0080":1,"\ud83d\ude00":0}',
  );
});
