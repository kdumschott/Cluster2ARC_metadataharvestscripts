#!/bin/bash
# Harvest ONT/MinKNOW run metadata into a DataPLANT ARC assay, using ARCtrl.
#
# Usage:
#   RUN_DIR=/path/to/run ARC_PATH=/path/to/arc ASSAY_NAME=myassay \
#     bash harvest_ont_metadata.sh
#
# Everything needed is in this one file -- including the bundled ENA "Raw
# sequencing reads" Swate template, embedded below as base64 -- so copying
# just this file to wherever it needs to run is enough.

set -euo pipefail

# ---------------------------------------------------------------------------
# How ARCtrl/python are made available on this cluster. arctrl currently
# only works inside this venv (a different Python version is on the rest
# of the cluster).
# ---------------------------------------------------------------------------
ARCTRL_VENV="/mnt/bin/arctrl/arctrl_v3.1.0-venv"
source "${ARCTRL_VENV}/bin/activate"

# The venv's bin/ doesn't reliably expose a bare "python3" on PATH in every
# environment it's run from, so resolve the interpreter by its actual path
# instead of relying on PATH lookup.
PYTHON=""
for candidate in python3 python3.11 python3.10 python; do
    if [[ -x "${ARCTRL_VENV}/bin/${candidate}" ]]; then
        PYTHON="${ARCTRL_VENV}/bin/${candidate}"
        break
    fi
done
if [[ -z "${PYTHON}" ]]; then
    echo "No python executable found in ${ARCTRL_VENV}/bin -- contents:" >&2
    ls -la "${ARCTRL_VENV}/bin" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# EDIT ME: defaults, or set as environment variables before running.
# ---------------------------------------------------------------------------
RUN_DIR="${RUN_DIR:-/path/to/ont_run_output}"
ARC_PATH="${ARC_PATH:-/path/to/your/arc}"
ASSAY_NAME="${ASSAY_NAME:-my_assay}"


echo "started ont_harvest run of ${ASSAY_NAME}/$(basename "${RUN_DIR}") at ${SECONDS} seconds"

"${PYTHON}" - \
    --run-dir "${RUN_DIR}" \
    --arc-path "${ARC_PATH}" \
    --assay-name "${ASSAY_NAME}" <<'PYEOF'
"""Harvest metadata from an Oxford Nanopore (ONT/MinKNOW) run output directory
and write it into a DataPLANT ARC's ISA assay table (isa.assay.xlsx) using ARCtrl.

Reads only the small, structured MinKNOW files:
  - final_summary_*.txt   (run/flow-cell/instrument metadata, file counts)
  - sample_sheet_*.csv    (per-sample flow cell product code / kit / sample IDs)

Deliberately does NOT parse report.json / report.md / report_*.html /
sequencing_summary.txt (the latter can be tens of GB and holds per-read
data, not run metadata).

Writes TWO sheets into the assay's isa.assay.xlsx:
  - "Reads"           the fields from DataPLANT's official ENA - Raw sequencing
                       reads Swate template (embedded in this script) that
                       map onto ONT run metadata: Input [Sample Name], the
                       sequencing platform, and library layout (always
                       "single-end" for nanopore sequencing).
  - "run_information"  everything else harvested from the ONT output files that
                       has no home in the ENA template.

One row per sample_sheet.csv row (handles both single-sample and multiplexed/
barcoded runs). Re-running for the same run directory updates matching rows in
place instead of duplicating them, keyed on sample name (run_information is
additionally keyed on the ONT run ID, since "Reads" has no run-id column).
"""

import argparse
import base64
import csv
import glob
import os
import sys
import tempfile

from arctrl import (
    ArcTable,
    CompositeCell,
    CompositeHeader,
    IOType,
    OntologyAnnotation,
    XlsxController,
)

ENA_TABLE_NAME = "Reads"
RUN_INFO_TABLE_NAME = "run_information"

# Bundled ENA "Raw sequencing reads" Swate template, base64-encoded so the
# whole harvester -- including this data asset -- is a single self-contained
# file. Decoded to a temp file on demand by load_ena_reads_table() below.
ENA_TEMPLATE_B64 = """
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
ABUAGQUAAEciAAAAAA==
"""

# Exact header text expected in the bundled ENA template's "Reads" table, in
# column order. Checked at runtime so a template update that changes columns
# fails loudly instead of silently mis-mapping data.
EXPECTED_ENA_HEADERS = [
    "Input [Sample Name]",
    "Component [next generation sequencing instrument model]",
    "Characteristic [Sequencing Library Name]",
    "Characteristic [library source]",
    "Parameter [Library selection]",
    "Parameter [library strategy]",
    "Parameter [library layout]",
    "Characteristic [MD5 Checksum]",
    "Output [Data]",
]

# ---------------------------------------------------------------------------
# ONT flow cell product code (+ instrument hostname, to disambiguate flow
# cells that run on more than one instrument) -> platform, with an OBI term
# per Ontology_terms_outputsheetheadings.ods.
#
# Flongle is deliberately NOT treated as a fourth platform: it's an adapter/
# flow-cell format run on a MinION or GridION, not a sequencer instrument in
# its own right (no OBI/EFO term exists for it either -- GENEPIO:0004433 is
# the only match anywhere, and its own definition flags it as "a placeholder
# pending replacement by an appropriate term from another ontology"). So
# FLO-FLG flow cells resolve to whichever real instrument ran them, same as
# FLO-MIN below; the Flongle fact itself is still captured, just under
# Parameter [flow cell product code] in run_information rather than forced
# into this instrument-model concept.
# ---------------------------------------------------------------------------
PLATFORM_TERMS = {
    "PromethION": ("Oxford Nanopore PromethION", "OBI", "OBI:0002752"),
    "MinION": ("Oxford Nanopore MinION", "OBI", "OBI:0002750"),
    "GridION": ("Oxford Nanopore GridION Mk1", "OBI", "OBI:0002751"),
}


def infer_platform(flow_cell_product_code, instrument_id):
    code = (flow_cell_product_code or "").upper()
    inst = (instrument_id or "").upper()
    if code.startswith("FLO-PRO"):
        return "PromethION"
    if code.startswith("FLO-MIN") or code.startswith("FLO-FLG"):
        # Both flow cell formats run on either a MinION or a GridION;
        # disambiguate via the instrument hostname convention (GridION:
        # "GXB...", MinION connected via MinIT/mk1C: "MN..."). Left blank if
        # neither pattern matches.
        if inst.startswith("GXB"):
            return "GridION"
        if inst.startswith("MN"):
            return "MinION"
    return ""


def parse_final_summary(path):
    """Parse MinKNOW's final_summary_*.txt (simple key=value lines)."""
    data = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or "=" not in line:
                continue
            key, _, value = line.partition("=")
            data[key.strip()] = value.strip()
    return data


def parse_sample_sheet(path):
    """Parse MinKNOW's sample_sheet_*.csv. Returns list of row dicts."""
    with open(path, "r", encoding="utf-8", newline="") as fh:
        reader = csv.DictReader(fh)
        return [row for row in reader]


def yes_no(flag_value):
    return "Yes" if str(flag_value).strip() == "1" else "No"


def split_datetime(iso_string):
    """Split a MinKNOW ISO-8601 timestamp into (date, time-with-offset)."""
    if not iso_string or "T" not in iso_string:
        return "", ""
    date_part, _, time_part = iso_string.partition("T")
    return date_part, time_part


# ---------------------------------------------------------------------------
# Cell factories
# ---------------------------------------------------------------------------
def term_cell(value):
    return CompositeCell.create_term_from_string(str(value) if value else "")


def free_text_cell(value):
    return CompositeCell.free_text(str(value) if value else "")


def blank_term_cell(_value):
    return CompositeCell.empty_term()


def blank_data_cell(_value):
    return CompositeCell.empty_data()


def blank_free_text_cell(_value):
    return CompositeCell.free_text("")


def platform_cell(platform_name):
    if platform_name in PLATFORM_TERMS:
        name, tsr, tan = PLATFORM_TERMS[platform_name]
        return CompositeCell.create_term_from_string(name, tsr, tan)
    return CompositeCell.create_term_from_string(platform_name or "")


def single_end_cell(_value):
    return CompositeCell.create_term_from_string("single-end", "DPBO", "DPBO:0000086")


def passthrough_cell(value):
    """value is already a fully-built CompositeCell."""
    return value


# ---------------------------------------------------------------------------
# "run_information" column definitions: (header, value_key, cell_factory)
# ---------------------------------------------------------------------------
# Column names use the ontology term's own preferred label (e.g. NCIT:C117058's
# label "Run Identifier") wherever a term is attached, rather than a
# custom-invented phrase, so the header text matches what the term actually
# is called. Columns with no matching ontology term keep a plain descriptive
# name since there's no term label to take it from.
RUN_INFO_COLUMN_DEFS = [
    (CompositeHeader.input(IOType.sample()), "sample_name", free_text_cell),
    (CompositeHeader.protocol_ref(), "_blank", blank_free_text_cell),
    (CompositeHeader.parameter(OntologyAnnotation("Run Identifier", "NCIT", "NCIT:C117058")), "run_id", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("Flow cell identifier", "EDAM", "EDAM:data_3733")), "flow_cell_id", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("flow cell position")), "position", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("flow cell product code")), "flow_cell_product_code", term_cell),
    (CompositeHeader.component(OntologyAnnotation("library preparation kit", "GENEPIO", "GENEPIO:0000085")), "kit", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("Instrument Identification Number", "NCIT", "NCIT:C178947")), "instrument", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("experiment identifier", "AFO", "AFO:AFR_0002009")), "protocol_group_id", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("Start Date", "NCIT", "NCIT:C68616")), "start_date", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("Start Time", "NCIT", "NCIT:C78441")), "start_time", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("End Date", "NCIT", "NCIT:C68617")), "stop_date", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("End Time", "NCIT", "NCIT:C82573")), "stop_time", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("basecalling enabled")), "basecalling_enabled", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("pod5 file count")), "pod5_file_count", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("fastq file count")), "fastq_file_count", term_cell),
]


def build_run_info_values(summary, sample_row):
    sample_name = sample_row.get("sample_id") or sample_row.get("experiment_id") or summary.get("sample_id", "")
    run_id = sample_row.get("protocol_run_id") or summary.get("protocol_run_id", "")
    start_date, start_time = split_datetime(summary.get("started", ""))
    stop_date, stop_time = split_datetime(summary.get("acquisition_stopped", ""))
    return {
        "sample_name": sample_name,
        "_blank": "",
        "run_id": run_id,
        "flow_cell_id": sample_row.get("flow_cell_id") or summary.get("flow_cell_id", ""),
        "position": sample_row.get("position_id") or summary.get("position", ""),
        "flow_cell_product_code": sample_row.get("flow_cell_product_code", ""),
        "kit": sample_row.get("kit", ""),
        "instrument": summary.get("instrument", ""),
        "protocol_group_id": sample_row.get("experiment_id") or summary.get("protocol_group_id", ""),
        "start_date": start_date,
        "start_time": start_time,
        "stop_date": stop_date,
        "stop_time": stop_time,
        "basecalling_enabled": yes_no(summary.get("basecalling_enabled", "0")),
        "pod5_file_count": summary.get("pod5_files_in_final_dest", ""),
        "fastq_file_count": summary.get("fastq_files_in_final_dest", ""),
    }


def build_ena_column_defs(template_headers):
    h = template_headers
    return [
        (h[0], "sample_name", free_text_cell),
        (h[1], "platform_cell", passthrough_cell),
        (h[2], "_blank_library_name", blank_term_cell),
        (h[3], "_blank_library_source", blank_term_cell),
        (h[4], "_blank_library_selection", blank_term_cell),
        (h[5], "_blank_library_strategy", blank_term_cell),
        (h[6], "_single_end", single_end_cell),
        (h[7], "_blank_md5", blank_term_cell),
        (h[8], "_blank_output_data", blank_data_cell),
    ]


# Keys used above for columns whose value is a fixed constant (blank or
# always "single-end") rather than anything harvested -- each needs its own
# dict entry (even though the factories ignore it) so upsert_row's column<->key
# lookup doesn't collide across columns that would otherwise share one key.
_ENA_CONSTANT_KEYS = [
    "_blank_library_name",
    "_blank_library_source",
    "_blank_library_selection",
    "_blank_library_strategy",
    "_single_end",
    "_blank_md5",
    "_blank_output_data",
]


def build_ena_values(summary, sample_row, run_info_values):
    platform_name = infer_platform(run_info_values["flow_cell_product_code"], run_info_values["instrument"])
    values = {
        "sample_name": run_info_values["sample_name"],
        "platform_cell": platform_cell(platform_name),
    }
    values.update({key: "" for key in _ENA_CONSTANT_KEYS})
    return values


# ---------------------------------------------------------------------------
# Generic table create/update helpers, shared by both sheets.
# ---------------------------------------------------------------------------
def default_cell_for_header(header):
    if header.IsDataColumn:
        return CompositeCell.empty_data()
    if header.IsTermColumn:
        return CompositeCell.empty_term()
    return CompositeCell.empty_free_text()


def find_matching_row_index(table, key_col_indices, key_values):
    for row_index in range(table.RowCount):
        row = table.GetRow(row_index)
        if all(row[idx].GetContent()[0] == val for idx, val in zip(key_col_indices, key_values)):
            return row_index
    return None


def upsert_row(table, column_defs, values, key_fields):
    """Add or update one row in `table` for the given column_defs/values,
    matching an existing row on `key_fields`. Works whether `table` already
    has its columns defined (e.g. loaded from the bundled ENA template, or an
    existing ARC assay) or is a bare ArcTable.init() with zero columns."""
    if table.ColumnCount == 0:
        for header, key, factory in column_defs:
            table.AddColumn(header, [factory(values[key])])
        return "created"

    header_strings = [str(h) for h in table.Headers]
    col_index_by_key = {}
    # Capture this ONCE, before any column is appended below -- not
    # re-checked per column, since AddColumnFill's own phantom row (see next
    # comment) would otherwise make every later iteration this loop think
    # the table already had a real row.
    had_rows_before_adding_columns = table.RowCount > 0
    for (header, key, _) in column_defs:
        target = str(header)
        if target in header_strings:
            col_index_by_key[key] = header_strings.index(target)
        else:
            new_index = table.ColumnCount
            if had_rows_before_adding_columns:
                # AddColumnFill backfills the new column with this default
                # for every row the table already has -- the behavior this
                # call exists for.
                table.AddColumnFill(header, default_cell_for_header(header))
            else:
                # On a table with zero rows, AddColumnFill has a surprising
                # side effect: it silently creates one phantom all-blank row
                # (RowCount 0 -> 1) before any real data is ever added. Hit
                # on literally every first-ever write to a bundled template
                # table like "Reads" (always needs at least one appended
                # column beyond the template's own), this would otherwise
                # leave the real data for that first sample sitting in row 1
                # with an invalid blank row 0 in front of it. AddColumn with
                # an empty list has no such side effect.
                table.AddColumn(header, [])
            header_strings.append(target)
            col_index_by_key[key] = new_index

    key_indices = [col_index_by_key[k] for k in key_fields]
    key_values = [str(values[k]) for k in key_fields]
    match_row = find_matching_row_index(table, key_indices, key_values)

    full_row = [default_cell_for_header(h) for h in table.Headers]
    for (header, key, factory) in column_defs:
        full_row[col_index_by_key[key]] = factory(values[key])

    if match_row is not None:
        for col_index, cell in enumerate(full_row):
            table.SetCellAt(col_index, match_row, cell)
        return "updated"

    table.AddRow(full_row)
    return "appended"


def load_ena_reads_table():
    """Decode the embedded ENA template to a temp file, load its 'Reads'
    table structure, then remove the temp file -- it's only needed for this
    one read."""
    raw_bytes = base64.b64decode(ENA_TEMPLATE_B64)
    fd, tmp_path = tempfile.mkstemp(suffix=".xlsx")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(raw_bytes)
        template_assay = XlsxController.Assay().from_xlsx_file(tmp_path)
    finally:
        os.remove(tmp_path)

    template_table = template_assay.GetTable(ENA_TABLE_NAME)
    actual_headers = [str(h) for h in template_table.Headers]
    if actual_headers != EXPECTED_ENA_HEADERS:
        sys.exit(
            "Bundled ENA template's 'Reads' table headers don't match what this "
            "script expects. The template may have been updated -- review "
            "EXPECTED_ENA_HEADERS / build_ena_column_defs() in this script.\n"
            f"Expected: {EXPECTED_ENA_HEADERS}\n"
            f"Found:    {actual_headers}"
        )
    empty_table = ArcTable.init(ENA_TABLE_NAME)
    for h in template_table.Headers:
        empty_table.AddColumn(h, [])
    return empty_table


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, help="Path to the ONT/MinKNOW run output directory")
    parser.add_argument("--arc-path", required=True, help="Path to the target ARC root directory")
    parser.add_argument("--assay-name", required=True, help="Name of the assay under <arc-path>/assays/<assay-name>")
    parser.add_argument("--dry-run", action="store_true", help="Parse and print what would be written, without touching the ARC")
    args = parser.parse_args()

    run_dir = os.path.abspath(args.run_dir)
    assay_file = os.path.join(args.arc_path, "assays", args.assay_name, "isa.assay.xlsx")

    final_summary_matches = glob.glob(os.path.join(run_dir, "final_summary_*.txt"))
    sample_sheet_matches = glob.glob(os.path.join(run_dir, "sample_sheet_*.csv"))
    if not final_summary_matches:
        sys.exit(f"No final_summary_*.txt found in {run_dir}")
    if not sample_sheet_matches:
        sys.exit(f"No sample_sheet_*.csv found in {run_dir}")
    if not args.dry_run and not os.path.isfile(assay_file):
        sys.exit(f"Assay file not found: {assay_file}")

    summary = parse_final_summary(final_summary_matches[0])
    sample_rows = parse_sample_sheet(sample_sheet_matches[0])

    run_info_rows = [build_run_info_values(summary, row) for row in sample_rows]
    ena_rows = [build_ena_values(summary, row, ri) for row, ri in zip(sample_rows, run_info_rows)]

    if args.dry_run:
        for ri, ena in zip(run_info_rows, ena_rows):
            print("run_information:", ri)
            print("Reads platform:", ena["platform_cell"].GetContent())
        return

    assay = XlsxController.Assay().from_xlsx_file(assay_file)

    run_info_table = assay.TryGetTable(RUN_INFO_TABLE_NAME)
    run_info_is_new = run_info_table is None
    if run_info_is_new:
        run_info_table = ArcTable.init(RUN_INFO_TABLE_NAME)

    reads_table = assay.TryGetTable(ENA_TABLE_NAME)
    reads_is_new = reads_table is None
    if reads_is_new:
        reads_table = load_ena_reads_table()

    results = []
    for values, ena_values in zip(run_info_rows, ena_rows):
        outcome = upsert_row(run_info_table, RUN_INFO_COLUMN_DEFS, values, key_fields=["run_id", "sample_name"])
        ena_column_defs = build_ena_column_defs(reads_table.Headers)
        ena_outcome = upsert_row(reads_table, ena_column_defs, ena_values, key_fields=["sample_name"])
        results.append((values["sample_name"], outcome, ena_outcome))

    def write_back(table, is_new, table_name):
        if is_new:
            assay.AddTable(table)
        else:
            table_names = list(assay.TableNames)
            assay.SetTableAt(table_names.index(table_name), table)

    write_back(run_info_table, run_info_is_new, RUN_INFO_TABLE_NAME)
    write_back(reads_table, reads_is_new, ENA_TABLE_NAME)
    XlsxController.Assay().to_xlsx_file(assay_file, assay)

    for sample_name, run_info_outcome, reads_outcome in results:
        print(f"{sample_name}: run_information={run_info_outcome}, Reads={reads_outcome}")


if __name__ == "__main__":
    main()
PYEOF

echo "finished ont_harvest run of ${ASSAY_NAME}/$(basename "${RUN_DIR}") after ${SECONDS} seconds"
