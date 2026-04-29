function rowValue(input, field) {
  return input.kind === "source_row" ? input.row[field] : input.record[field];
}

function numberValue(input, field) {
  const parsed = Number.parseFloat(String(rowValue(input, field) ?? ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

export const mapping = {
  name: "invoice_rows_to_demo_invoices"
};

export function groupKey(input) {
  return String(rowValue(input, "Invoice Number") ?? "").trim();
}

export function reduce(group) {
  const invoiceNumber = group.key;
  const first = group.records[0];
  let totalAmount = 0;

  for (const record of group.records) {
    totalAmount += numberValue(record, "Quantity") * numberValue(record, "Unit Price");
  }

  return {
    destination_table: "demo_invoices",
    operation: "upsert",
    record: {
      invoice_number: invoiceNumber,
      customer_external_id: String(rowValue(first, "Customer External ID") ?? "").trim(),
      invoice_date: String(rowValue(first, "Invoice Date") ?? "").trim(),
      currency: String(rowValue(first, "Currency") ?? "").trim(),
      line_count: group.records.length,
      total_amount: Number(totalAmount.toFixed(2))
    },
    meta: {
      source_invoice_rows: group.source_set.row_count
    }
  };
}
