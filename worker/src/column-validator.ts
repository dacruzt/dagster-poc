/**
 * Column Validator - Validates file structure against schemas.
 * Schemas are provided by the caller (loaded from DynamoDB dataset configs).
 */

// ─── Types ──────────────────────────────────────────────────────

export interface ColumnDef {
  name: string;
  type: "string" | "date" | "number";
}

export interface FileSchema {
  requiredColumns: ColumnDef[];
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
}

// ─── Validators ─────────────────────────────────────────────────

function isValidDate(value: string): boolean {
  if (!value || value.trim() === "") return false;

  // Try ISO format, common date formats
  const parsed = Date.parse(value.trim());
  if (!isNaN(parsed)) return true;

  // Try MM/DD/YYYY, DD/MM/YYYY patterns
  const datePatterns = [
    /^\d{1,2}\/\d{1,2}\/\d{2,4}$/,
    /^\d{4}-\d{2}-\d{2}$/,
    /^\d{1,2}-\d{1,2}-\d{2,4}$/,
  ];

  return datePatterns.some((p) => p.test(value.trim()));
}

function isValidNumber(value: string): boolean {
  if (!value || value.trim() === "") return false;
  return !isNaN(Number(value.trim()));
}

function validateType(value: string, type: string): boolean {
  switch (type) {
    case "date":
      return isValidDate(value);
    case "number":
      return isValidNumber(value);
    case "string":
      return true; // Any non-empty presence is valid for string
    default:
      return true;
  }
}

// ─── CSV Validation ─────────────────────────────────────────────

/**
 * Validate CSV headers and first row against a schema.
 */
export function validateCsvColumns(
  headers: string[],
  firstRow: Record<string, string>,
  schema: { requiredColumns: ColumnDef[] }
): ValidationResult {
  const errors: string[] = [];
  const normalizedHeaders = headers.map((h) => h.toLowerCase().trim());

  for (const col of schema.requiredColumns) {
    const colName = col.name.toLowerCase();
    const headerIndex = normalizedHeaders.indexOf(colName);

    if (headerIndex === -1) {
      errors.push(`Missing required column '${col.name}'`);
      continue;
    }

    // Validate type using the first row's value
    const actualHeader = headers[headerIndex];
    const value = firstRow[actualHeader];

    if (col.type !== "string" && value !== undefined && value.trim() !== "") {
      if (!validateType(value, col.type)) {
        errors.push(
          `Column '${col.name}' expected type '${col.type}' but got value '${value}'`
        );
      }
    }
  }

  return { valid: errors.length === 0, errors };
}

// ─── JSON Validation ────────────────────────────────────────────

/**
 * Validate a JSON record against a schema.
 */
export function validateJsonFields(
  record: unknown,
  schema: { requiredColumns: ColumnDef[] }
): ValidationResult {
  const errors: string[] = [];

  if (typeof record !== "object" || record === null) {
    return { valid: false, errors: ["First record is not a valid JSON object"] };
  }

  const obj = record as Record<string, unknown>;
  const keys = Object.keys(obj).map((k) => k.toLowerCase());

  for (const col of schema.requiredColumns) {
    const colName = col.name.toLowerCase();

    if (!keys.includes(colName)) {
      errors.push(`Missing required field '${col.name}'`);
      continue;
    }

    // Find the actual key (preserving original case)
    const actualKey = Object.keys(obj).find(
      (k) => k.toLowerCase() === colName
    )!;
    const value = obj[actualKey];

    if (col.type !== "string" && value !== undefined && value !== null) {
      if (!validateType(String(value), col.type)) {
        errors.push(
          `Field '${col.name}' expected type '${col.type}' but got value '${value}'`
        );
      }
    }
  }

  return { valid: errors.length === 0, errors };
}
