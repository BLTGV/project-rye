function normalizedActiveFlag(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  return ["y", "yes", "true", "1"].includes(normalized);
}

function normalizedLocation(row, prefix) {
  const street = String(row[`${prefix} Street`] ?? "").trim();
  const city = String(row[`${prefix} City`] ?? "").trim();
  const state = String(row[`${prefix} State`] ?? "").trim();

  if (!street && !city && !state) {
    return null;
  }

  return { street, city, state };
}

function sameLocation(left, right) {
  return Boolean(left) &&
    Boolean(right) &&
    left.street === right.street &&
    left.city === right.city &&
    left.state === right.state;
}

export const mapping = {
  name: "org_profiles_to_demo_entities"
};

export function transform(input) {
  if (input.kind !== "source_row") {
    return null;
  }

  const row = input.row;
  const orgCode = String(row["Org Code"] ?? "").trim();
  const billing = normalizedLocation(row, "Billing");
  const shipping = normalizedLocation(row, "Shipping");

  const records = [
    {
      destination_table: "demo_orgs",
      operation: "upsert",
      record: {
        org_code: orgCode,
        legal_name: String(row["Legal Name"] ?? "").trim(),
        industry: String(row.Industry ?? "").trim(),
        is_active: normalizedActiveFlag(row.Active)
      }
    }
  ];

  if (billing) {
    records.push({
      destination_table: "demo_locations",
      operation: "upsert",
      record: {
        location_code: `${orgCode}:billing`,
        org_code: orgCode,
        location_type: "billing",
        street: billing.street,
        city: billing.city,
        state: billing.state
      }
    });
  }

  if (shipping && !sameLocation(billing, shipping)) {
    records.push({
      destination_table: "demo_locations",
      operation: "upsert",
      record: {
        location_code: `${orgCode}:shipping`,
        org_code: orgCode,
        location_type: "shipping",
        street: shipping.street,
        city: shipping.city,
        state: shipping.state
      }
    });
  }

  return records;
}
