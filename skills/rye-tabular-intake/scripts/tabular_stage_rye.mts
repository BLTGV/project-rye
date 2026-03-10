#!/usr/bin/env node
import { CliError, getString, runCli, type HelpSpec } from "./lib/cli.mts";
import {
  isMappedRecord,
  isSourceRow,
  appendLineage,
  type MappedRecord,
  type RyeStageRecord,
  type SourceRow,
} from "./lib/contracts.mts";
import { validateSchemaFile } from "./lib/json_schema.mts";
import { buildStageProperties, RYE_TABULAR_INTAKE } from "./lib/rye_contracts.mts";
import { readNdjson, writeNdjson } from "./lib/ndjson.mts";

const help: HelpSpec = {
  name: "tabular_stage_rye.mts",
  summary: "Wrap extracted or mapped rows in a Rye staging envelope for load tracking.",
  usage: [
    "node skills/rye-tabular-intake/scripts/tabular_stage_rye.mts [--input <ndjson>] [--node-type <value>]",
  ],
  options: [
    { flag: "--input <path>", description: "Optional NDJSON input file. Default: stdin." },
    { flag: "--node-type <value>", description: "Node type for Rye staging records. Default: rye_tabular_intake_stage_row." },
    { flag: "--status <value>", description: "Ingest status to attach. Default: extracted." },
    { flag: "--label-prefix <value>", description: "Optional prefix added to generated labels." },
    { flag: "--help", description: "Print command help." },
  ],
  examples: [
    "node skills/rye-tabular-intake/scripts/tabular_extract.mts --input data/customers.csv | node skills/rye-tabular-intake/scripts/tabular_stage_rye.mts",
    "node skills/rye-tabular-intake/scripts/tabular_map.mts --input /tmp/source.ndjson --module mappings/customers_to_contacts.mts | node skills/rye-tabular-intake/scripts/tabular_stage_rye.mts --status mapped",
  ],
};

await runCli(help, async (args) => {
  const inputPath = getString(args, "input");
  const nodeType = getString(args, "node-type") ?? RYE_TABULAR_INTAKE.defaultStageNodeType;
  const status = getString(args, "status") ?? "extracted";
  const labelPrefix = getString(args, "label-prefix");

  for await (const value of readNdjson(inputPath)) {
    if (!isSourceRow(value) && !isMappedRecord(value)) {
      throw new CliError(
        "unsupported_stage_input",
        "tabular_stage_rye.mts accepts only source_row or mapped_record input.",
        "Run tabular_extract.mts first, or stage the output of tabular_map.mts.",
      );
    }
    writeNdjson(await buildStageRecord(value, nodeType, status, labelPrefix));
  }
});

async function buildStageRecord(
  input: SourceRow | MappedRecord,
  nodeType: string,
  status: string,
  labelPrefix?: string,
): Promise<RyeStageRecord> {
  const baseLabel = `${input.source.table_name} row ${input.source.row_number}`;
  const label = labelPrefix ? `${labelPrefix} ${baseLabel}` : baseLabel;
  const properties = buildStageProperties({ record: input, status });

  const record: RyeStageRecord = {
    kind: "rye_stage_record",
    node_type: nodeType,
    label,
    source: input.source,
    lineage: appendLineage(input.lineage, `stage:${status}`),
    properties,
  };

  await assertStageProperties(record.properties, input.source.table_name, input.source.row_number);
  return record;
}

async function assertStageProperties(properties: Record<string, unknown>, tableName: string, rowNumber: number): Promise<void> {
  const errors = await validateSchemaFile("rye_stage_properties.schema.json", properties);
  if (errors.length > 0) {
    throw new CliError(
      "invalid_stage_properties",
      `Stage properties for ${tableName} row ${rowNumber} do not match the Rye tabular-intake schema.`,
      errors.join("; "),
      [`Check the source row values and any mapping output before staging.`],
    );
  }
}
