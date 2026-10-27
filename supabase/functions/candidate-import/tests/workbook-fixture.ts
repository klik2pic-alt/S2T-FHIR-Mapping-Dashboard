import ExcelJS from "exceljs";
import { SHEET_CONTRACTS } from "../lib/contracts.ts";

export async function workbookFixture(options: {
  omitSheet?: string;
  renameHeader?: boolean;
  formula?: boolean;
  formulaAll?: boolean;
  duplicateMainRows?: boolean;
  duplicateLogicalOnly?: boolean;
  invalidCardinality?: boolean;
  unknownDecision?: boolean;
  warningOnly?: boolean;
} = {}): Promise<Uint8Array> {
  const workbook = new ExcelJS.Workbook();
  for (const [name, contract] of Object.entries(SHEET_CONTRACTS)) {
    if (name === options.omitSheet) continue;
    const sheet = workbook.addWorksheet(name);
    contract.headers.forEach((header, offset) => {
      sheet.getCell(contract.headerRow, offset + 1).value =
        options.renameHeader && name === "S2T MedicationRequestCato" && offset === 0
          ? "Renamed"
          : header;
    });
    for (const [start, end] of contract.ranges) {
      for (let row = start; row <= end; row++) {
        if (contract.mappingKind === "ELEMENT_MAPPING") {
          sheet.getCell(row, 1).value = "CATO";
          sheet.getCell(row, 2).value = "XML";
          sheet.getCell(row, 3).value = "Medication";
          sheet.getCell(row, 4).value =
            (options.duplicateMainRows || options.duplicateLogicalOnly) && row === 3
              ? "field-2"
              : `field-${row}`;
          sheet.getCell(row, 9).value = options.warningOnly && row === 2
            ? "dosageInstruction.timing.repeat.bounds[x]"
            : (options.duplicateMainRows || options.duplicateLogicalOnly) && row === 3
            ? "MedicationRequest.extension[2]"
            : `MedicationRequest.extension[${row}]`;
          sheet.getCell(row, 10).value = options.warningOnly && row === 2
            ? null
            : options.invalidCardinality && row === 2
            ? "invalid"
            : "0..1";
          sheet.getCell(row, 17).value = options.warningOnly && row === 2
            ? "DO NOT MAP"
            : options.unknownDecision && row === 2
            ? "UNKNOWN"
            : "FINAL";
          if (options.duplicateLogicalOnly && row === 3) {
            sheet.getCell(row, 16).value = "different non-identity evidence";
          }
          if ((options.formula && row === 2) || options.formulaAll) {
            sheet.getCell(row, 4).value = { formula: "1+1", result: 2 };
          }
        } else if (contract.mappingKind === "STATUS_MAPPING_RULE") {
          sheet.getCell(row, 1).value = row;
          sheet.getCell(row, 2).value = `source-${row}`;
          sheet.getCell(row, 4).value = `target-${row}`;
          if (options.formulaAll) {
            sheet.getCell(row, 2).value = { formula: "1+1", result: 2 };
          }
        } else {
          sheet.getCell(row, 1).value = "אושר";
          sheet.getCell(row, 2).value = `topic-${row}`;
          sheet.getCell(row, 3).value = `MedicationRequest.scope-${row}`;
          sheet.getCell(row, 4).value = `guidance-${row}`;
          if (options.formulaAll) {
            sheet.getCell(row, 2).value = { formula: "1+1", result: 2 };
          }
        }
      }
    }
  }
  return new Uint8Array(await workbook.xlsx.writeBuffer());
}
