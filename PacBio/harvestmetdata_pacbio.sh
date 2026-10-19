#!/bin/bash
# Harvest PacBio (Revio/Sequel) run metadata into a DataPLANT ARC assay, using
# ARCtrl. Handles TWO different sample-directory layouts, auto-detected per
# sample directory:
#
#   (A) Facility-repackaged -- a directory holding just the final demuxed
#       BAM (+.pbi), read via `samtools view -H` (header only, never the
#       read body, so this is fast/safe no matter how large the BAM is).
#   (B) Native on-instrument Revio output -- a directory holding
#       hifi_reads/, fail_reads/, metadata/, pb_formats/, statistics/
#       subdirectories. Parsed from the small XML/JSON/txt files in those
#       subdirectories (never the BAMs), which carry considerably richer
#       metadata than a BAM header alone: exact kit lot numbers/expiry
#       dates, well/loading info, movie-wide HiFi yield & quality stats,
#       and per-barcode demultiplexing counts.
#
# Usage:
#   RUN_DIR=/path/to/pacbio_project ARC_PATH=/path/to/arc ASSAY_NAME=myassay \
#     bash harvest_pacbio_metadata.sh
#
# RUN_DIR is the project directory that CONTAINS the batches (e.g.
# pacbio_p1406/, with Batch1/, Batch2/, ... inside it, each holding one
# subdirectory per sample). If RUN_DIR has no Batch*/ subdirectories, it is
# itself treated as a single batch. One row is written per sample found
# (one per BAM for layout (A); one per BioSample/barcode for layout (B)).
#
# Everything needed is in this one file -- including the bundled ENA "Raw
# sequencing reads" Swate template, embedded below as base64 -- so copying
# just this file to wherever it needs to run is enough, PROVIDED `samtools`
# is also available (set SAMTOOLS=/path/to/samtools if it's not on PATH) --
# only needed for layout (A); layout (B) needs no external tool at all.

set -euo pipefail

# ---------------------------------------------------------------------------
# How ARCtrl/python are made available on this cluster. arctrl currently
# only works inside this venv (a different Python version is on the rest
# of the cluster). Same venv the ONT harvester uses.
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

# Only the BAM *header* is ever read (via `samtools view -H`), so this is
# fast and safe regardless of how large the BAM bodies are.
SAMTOOLS="${SAMTOOLS:-samtools}"
if ! command -v "${SAMTOOLS}" >/dev/null 2>&1; then
    echo "samtools not found (looked for '${SAMTOOLS}' on PATH)." >&2
    echo "Set SAMTOOLS=/path/to/samtools and re-run." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# EDIT ME: defaults, or set as environment variables before running.
# ---------------------------------------------------------------------------
RUN_DIR="${RUN_DIR:-/path/to/pacbio_project}"
ARC_PATH="${ARC_PATH:-/path/to/your/arc}"
ASSAY_NAME="${ASSAY_NAME:-my_assay}"


echo "started pacbio_harvest run of ${ASSAY_NAME}/$(basename "${RUN_DIR}") at ${SECONDS} seconds"

"${PYTHON}" - \
    --run-dir "${RUN_DIR}" \
    --arc-path "${ARC_PATH}" \
    --assay-name "${ASSAY_NAME}" \
    --samtools "${SAMTOOLS}" <<'PYEOF'
"""Harvest metadata from a PacBio (Revio/Sequel) sequencing project directory
and write it into a DataPLANT ARC's ISA assay table (isa.assay.xlsx) using
ARCtrl.

Two sample-directory shapes are supported, auto-detected per sample directory
(so a single RUN_DIR can mix both, e.g. different batches delivered by
different means):

  (A) Facility-repackaged -- just the final demuxed BAM, no instrument
      metadata alongside it:

        RUN_DIR/
          Batch1/
            <sample>_CELL1/
              <movie>.hifi_reads.bc####.bam[.pbi]
            checksums_*.sha256 | sha256sum*.txt | ...   (naming is
                                                           inconsistent across
                                                           batches -- every
                                                           variant seen is
                                                           handled)
          Batch2/
            ...

      For each such sample directory, this script:
        1. Picks the primary BAM (preferring one with "hifi_reads" in the
           name if more than one *.bam is present).
        2. Runs `samtools view -H` on it -- ONLY the header, never the read
           body, so this is fast/cheap regardless of BAM size -- and parses
           the @RG line (including its semicolon-delimited DS field, which
           carries most of the useful PacBio run/chemistry/barcode metadata)
           and the @PG lines (one per processing step: ccs, pbtrim, jasmine,
           lima, ...).
        3. Looks up that BAM's checksum in whichever checksum manifest file
           it can find (batch- or sample-level, whatever naming convention
           was used).
        4. Records file size and whether a .pbi index is present.

  (B) Native on-instrument Revio output -- one directory per movie, holding
      hifi_reads/, fail_reads/, metadata/, pb_formats/, statistics/:

        RUN_DIR/
          <sample>_run1/
            metadata/<movie>.metadata.xml            run/instrument/kit/
                                                        software-version XML
            statistics/<movie>.ccs_report.txt         movie-wide HiFi yield/
                                                        quality stats
            statistics/<movie>.hifi_reads.lima_summary.txt
            statistics/<movie>.hifi_reads.lima_counts.txt   per-barcode demux
                                                              counts
            pb_formats/<movie>.hifi_reads.<barcode>.consensusreadset.xml
                                                       exact read count/yield
                                                        for that barcode's BAM
            hifi_reads/<movie>.hifi_reads.<barcode>.bam[.pbi]

      For each such sample directory, this script parses metadata.xml (one
      row per BioSample/barcode found in it -- usually one, but a pooled well
      with several BioSamples is handled the same way), cross-references the
      matching consensusreadset.xml, ccs_report.txt and lima stats, and
      records the matching BAM's file size / .pbi presence. Only the small
      XML/JSON/txt files are ever read -- never the BAM itself.

If RUN_DIR itself has no Batch*/ subdirectories, it is treated as a single
batch (its direct subdirectories are the sample directories).

Writes TWO sheets into the assay's isa.assay.xlsx, same split as the ONT
harvester:
  - "Reads"           fields from DataPLANT's official ENA - Raw sequencing
                       reads Swate template (embedded below) that map onto
                       PacBio run metadata.
  - "run_information"  everything else harvested that has no home in the ENA
                       template -- chemistry/kit identifiers, barcode info,
                       base modification / kinetics flags, checksums, etc.

One row per sample BAM found. Re-running for the same RUN_DIR updates
matching rows in place instead of duplicating them, keyed on (run_id,
sample_name) for run_information and on (sample_name, movie_name) for Reads
(movie_name disambiguates a sample that was re-run on a second SMRT Cell --
common with PacBio, unlike a single ONT flow-cell run).
"""

import argparse
import base64
import glob
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

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
# (Identical to the copy bundled in harvest_ont_metadata.sh -- same official
# DataPLANT template, platform-agnostic.)
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
# PacBio instrument model (from the @RG PM tag) -> OBI term. Every ID below
# was checked directly against the OBI ontology source (obi.owl), not just a
# search engine summary -- only PM:REVIO is confirmed empirically from an
# actual BAM header at the time this script was written; the rest map the
# PM-tag spelling PacBio software is documented to use, but haven't been
# seen in a real file here yet. If a sample's PM tag doesn't match any key
# below, platform_cell() falls back to a bare free-text term instead of
# failing, so an unrecognised/future PM value is still visible in the sheet.
# ---------------------------------------------------------------------------
PLATFORM_TERMS = {
    "REVIO": ("PacBio Revio", "OBI", "OBI:0003922"),
    "SEQUELIIE": ("PacBio Sequel IIe", "OBI", "OBI:0003921"),
    "SEQUELII": ("PacBio Sequel II", "OBI", "OBI:0002633"),
    "SEQUEL": ("PacBio Sequel", "OBI", "OBI:0002632"),
    "RS": ("PacBio RS II", "OBI", "OBI:0002012"),
    "RSII": ("PacBio RS II", "OBI", "OBI:0002012"),
}


def infer_platform(pm_tag):
    return PLATFORM_TERMS.get((pm_tag or "").upper().replace(" ", ""))


# ---------------------------------------------------------------------------
# BAM header parsing -- only ever reads the header (`samtools view -H`),
# never the read body, so this stays fast and cheap regardless of BAM size.
# ---------------------------------------------------------------------------
def run_samtools_header(samtools_bin, bam_path):
    result = subprocess.run(
        [samtools_bin, "view", "-H", bam_path],
        capture_output=True, text=True, check=True,
    )
    return result.stdout


def parse_rg_ds(ds_value):
    """Parse the @RG DS field's semicolon-delimited KEY=VALUE pairs."""
    out = {}
    for part in ds_value.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        key, _, value = part.partition("=")
        out[key.strip()] = value.strip()
    return out


def parse_bam_header(samtools_bin, bam_path):
    """Returns {'rg': {tag: value, ..., 'DS_parsed': {...}}, 'pg': {ID: {tag: value}}}."""
    header_text = run_samtools_header(samtools_bin, bam_path)
    rg = {}
    pg_by_id = {}
    for line in header_text.splitlines():
        if line.startswith("@RG"):
            for field in line.split("\t")[1:]:
                if ":" not in field:
                    continue
                tag, _, value = field.partition(":")
                rg[tag] = value
            if "DS" in rg:
                rg["DS_parsed"] = parse_rg_ds(rg["DS"])
        elif line.startswith("@PG"):
            fields = {}
            for field in line.split("\t")[1:]:
                if ":" not in field:
                    continue
                tag, _, value = field.partition(":")
                fields[tag] = value
            pg_id = fields.get("ID", "")
            if pg_id:
                pg_by_id[pg_id] = fields
    return {"rg": rg, "pg": pg_by_id}


# ---------------------------------------------------------------------------
# Sample / BAM / checksum discovery
# ---------------------------------------------------------------------------
def discover_batches(run_dir):
    batch_dirs = sorted(
        d for d in glob.glob(os.path.join(run_dir, "Batch*")) if os.path.isdir(d)
    )
    return batch_dirs if batch_dirs else [run_dir]


def discover_sample_dirs(batch_dir):
    return sorted(
        d for d in glob.glob(os.path.join(batch_dir, "*")) if os.path.isdir(d)
    )


def pick_primary_bam(sample_dir):
    bams = sorted(glob.glob(os.path.join(sample_dir, "*.bam")))
    if not bams:
        return None, []
    hifi = [b for b in bams if "hifi_reads" in os.path.basename(b)]
    chosen = hifi[0] if hifi else bams[0]
    return chosen, bams


CHECKSUM_FILENAME_RE = re.compile(r"(sha256|checksum|sum)", re.IGNORECASE)
HEX64_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def find_checksum(bam_path, sample_dir, batch_dir):
    """Search sample-level, then batch-level files for a line matching this
    BAM's basename, handling both 'hash  filename' and 'filename  hash'
    orderings and an optional sha256sum-style leading '*' binary marker."""
    target = os.path.basename(bam_path)
    candidates = []
    for directory in (sample_dir, batch_dir):
        for path in glob.glob(os.path.join(directory, "*")):
            name = os.path.basename(path)
            if os.path.isfile(path) and CHECKSUM_FILENAME_RE.search(name):
                candidates.append(path)

    for manifest in candidates:
        try:
            with open(manifest, "r", encoding="utf-8", errors="ignore") as fh:
                lines = fh.readlines()
        except OSError:
            continue
        for line in lines:
            tokens = line.split()
            if len(tokens) < 2:
                continue
            hexes = [t for t in tokens if HEX64_RE.match(t)]
            names = [t.lstrip("*") for t in tokens if not HEX64_RE.match(t)]
            if not hexes or not names:
                continue
            if any(os.path.basename(n) == target for n in names):
                return hexes[0]
    return ""


def yes_no(flag):
    return "Yes" if flag else "No"


# ---------------------------------------------------------------------------
# Native on-instrument Revio layout (hifi_reads/, metadata/, pb_formats/,
# statistics/, fail_reads/) -- an alternative to the facility-repackaged
# layout above. Detected per sample directory; only ever reads the small
# XML/JSON/txt files below, never a BAM.
# ---------------------------------------------------------------------------
NATIVE_LAYOUT_SUBDIRS = ("hifi_reads", "metadata", "pb_formats", "statistics")


def is_native_layout(sample_dir):
    return all(os.path.isdir(os.path.join(sample_dir, d)) for d in NATIVE_LAYOUT_SUBDIRS)


def strip_namespaces(root):
    """PacBio's metadata/DataSet XML mixes several XML namespaces in one
    document (a default xmlns plus per-element xmlns like pbmeta:/pbsample:).
    Rather than tracking each namespace URI (brittle across PacBio software
    versions), strip every element's namespace so plain tag-name lookups
    (.find("WellSample") etc.) work regardless of which namespace a given
    PacBio software version put a given element in."""
    for el in root.iter():
        if "}" in el.tag:
            el.tag = el.tag.split("}", 1)[1]
    return root


def parse_xml_stripped(path):
    return strip_namespaces(ET.parse(path).getroot())


def find_metadata_xml(metadata_dir):
    """Picks the real, final metadata.xml -- Revio also writes intermediate
    '<movie>_basic_preview_4hr.metadata.xml' / '..._full_preview_23hr....'
    snapshots partway through a movie, which must NOT be mistaken for the
    final one."""
    candidates = [
        p for p in glob.glob(os.path.join(metadata_dir, "*.metadata.xml"))
        if "_preview_" not in os.path.basename(p)
    ]
    if not candidates:
        return None
    # Exactly one expected; if more than one somehow matches, the shortest
    # filename is the plain "<movie>.metadata.xml".
    return min(candidates, key=len)


def automation_params(automation_params_el):
    if automation_params_el is None:
        return {}
    return {
        child.get("Name"): child.get("SimpleValue")
        for child in automation_params_el.findall("AutomationParameter")
    }


def parse_barcodes_fasta(secondary_el):
    """Secondary/BarcodesFasta is the full barcode panel, base64-encoded.
    Returns {barcode_id: sequence}, e.g. {'bc1015': 'CGCATGACACGTGTGT', ...}."""
    if secondary_el is None:
        return {}
    fasta_el = secondary_el.find("BarcodesFasta")
    if fasta_el is None or not (fasta_el.text or "").strip():
        return {}
    try:
        decoded = base64.b64decode(fasta_el.text.strip()).decode("utf-8", errors="ignore")
    except (ValueError, UnicodeDecodeError):
        return {}
    seqs, name = {}, None
    for line in decoded.splitlines():
        line = line.strip()
        if line.startswith(">"):
            name = line[1:].strip()
        elif line and name:
            seqs[name] = line
            name = None
    return seqs


def first_line(value):
    return (value or "").split("\n", 1)[0].strip()


def parse_run_metadata_xml(metadata_xml_path):
    """Parses a Revio <movie>.metadata.xml into (shared, bio_samples):
    `shared` is one dict of fields common to the whole movie; `bio_samples`
    is a list of per-BioSample dicts (usually length 1, but a pooled well
    with several biological samples is handled the same way)."""
    root = parse_xml_stripped(metadata_xml_path)
    run_el = root.find(".//Run")
    subreadset_el = root.find(".//SubreadSet")
    collection_md = root.find(".//CollectionMetadata")
    if collection_md is None:
        return None, []

    well_sample = collection_md.find("WellSample")
    automation = collection_md.find("Automation")
    secondary = collection_md.find("Secondary")
    primary = collection_md.find("Primary")
    cell_pac = collection_md.find("CellPac")
    control_kit = collection_md.find("ControlKit")
    template_prep_kit = collection_md.find("TemplatePrepKit")
    binding_kit_el = collection_md.find("BindingKit")
    sequencing_kit_el = collection_md.find("SequencingKitPlate")
    component_versions = collection_md.find("ComponentVersions")

    versions = {}
    if component_versions is not None:
        versions = {
            v.get("Name"): first_line(v.get("Version"))
            for v in component_versions.findall("VersionInfo")
        }

    primary_params = automation_params(automation.find("AutomationParameters") if automation is not None else None)
    secondary_params = automation_params(secondary.find("AutomationParameters") if secondary is not None else None)
    barcode_seqs = parse_barcodes_fasta(secondary)

    cpg_enabled = secondary_params.get("CpG", "").strip().lower() == "true"
    mod_types = ["5mC (CpG)"] if cpg_enabled else []

    # The authoritative on/off switch for whether kinetics tags were kept in
    # the CCS output is Primary/CCSOptions/IncludeKinetics; fall back to the
    # Secondary analysis config's own Kinetics flag if that's absent.
    ccs_options = primary.find("CCSOptions") if primary is not None else None
    include_kinetics_text = (
        ccs_options.findtext("IncludeKinetics", "") if ccs_options is not None
        else secondary_params.get("Kinetics", "")
    )
    kinetics_retained = (include_kinetics_text or "").strip().lower() == "true"

    demux_preset = secondary_params.get("DemultiplexPreset", "")
    barcode_mode = "Symmetric" if "SYMMETRIC" in demux_preset.upper() else ""

    shared = {
        "run_id": (run_el.get("TimeStampedName") if run_el is not None else "") or "",
        "run_uuid": (run_el.get("UniqueId") if run_el is not None else "") or "",
        # Used as the Reads sheet's library-name analog -- same role the BAM
        # header's LB tag plays for the facility-repackaged layout: a
        # readable container label, not a formal wet-lab library identifier.
        "_library_name": (subreadset_el.get("Name") if subreadset_el is not None else "") or "",
        "chip_type": (run_el.get("ChipType") if run_el is not None else "") or "",
        "movie_name": collection_md.get("Context", ""),
        "instrument_id": collection_md.get("InstrumentId", ""),
        "well_sample_name": well_sample.get("Name", "") if well_sample is not None else "",
        "well_name": well_sample.findtext("WellName", "") if well_sample is not None else "",
        "loading_concentration": well_sample.findtext("OnPlateLoadingConcentration", "") if well_sample is not None else "",
        "insert_size_target": well_sample.findtext("InsertSize", "") if well_sample is not None else "",
        "smrt_cell_id": cell_pac.get("Barcode", "") if cell_pac is not None else "",
        "smrt_cell_kit": cell_pac.get("PartNumber", "") if cell_pac is not None else "",
        "smrt_cell_lot": cell_pac.get("LotNumber", "") if cell_pac is not None else "",
        "smrt_cell_expiry": cell_pac.get("ExpirationDate", "") if cell_pac is not None else "",
        "control_kit_pn": control_kit.get("PartNumber", "") if control_kit is not None else "",
        "template_prep_kit": template_prep_kit.get("Name", "") if template_prep_kit is not None else "",
        "binding_kit": (binding_kit_el.get("PartNumber", "") if binding_kit_el is not None else "") or primary_params.get("BindingKitPartNumber", ""),
        "sequencing_kit": sequencing_kit_el.get("PartNumber", "") if sequencing_kit_el is not None else "",
        "sequencing_kit_lot": sequencing_kit_el.get("LotNumber", "") if sequencing_kit_el is not None else "",
        "sequencing_kit_expiry": sequencing_kit_el.get("ExpirationDate", "") if sequencing_kit_el is not None else "",
        "movie_length_min": primary_params.get("MovieLength", ""),
        "demux_preset": demux_preset,
        "barcode_mode": barcode_mode,
        "read_type": "CCS" if (well_sample is not None and well_sample.findtext("IsCCS", "").strip().lower() == "true") else "",
        "basecaller_version": versions.get("basecaller", ""),
        "ics_version": versions.get("ics", ""),
        "ccs_version": versions.get("ccs", ""),
        "jasmine_version": versions.get("jasmine", ""),
        "lima_version": versions.get("lima", ""),
        "kinetics_retained": yes_no(kinetics_retained),
        "base_mod_called": yes_no(bool(mod_types)),
        "base_mod_types": ", ".join(mod_types),
    }

    bio_samples = []
    if well_sample is not None:
        bio_samples_el = well_sample.find("BioSamples")
        if bio_samples_el is not None:
            for bio in bio_samples_el.findall("BioSample"):
                barcode_full = ""
                dna_barcodes = bio.find("DNABarcodes")
                if dna_barcodes is not None:
                    dna_barcode = dna_barcodes.find("DNABarcode")
                    if dna_barcode is not None:
                        barcode_full = dna_barcode.get("Name", "")
                barcode_id = barcode_full.split("--")[0] if barcode_full else ""
                bio_samples.append({
                    "sample_name": bio.get("Name", ""),
                    "barcode_id": barcode_id,
                    "barcode_seq": barcode_seqs.get(barcode_id, ""),
                })
    return shared, bio_samples


# Only the specific labels below are extracted from ccs_report.txt (rather
# than parsing every line generically) so a label this script doesn't
# recognise is simply ignored instead of needing to match a brittle full
# schema of the file.
CCS_REPORT_FIELDS = {
    "ZMWs input": "movie_zmws_input",
    "HiFi Reads": "movie_hifi_reads",
    "HiFi Yield (bp)": "movie_hifi_yield_bp",
    "HiFi Read Length (mean, bp)": "movie_hifi_len_mean",
    "HiFi Read Length N50 (bp)": "movie_hifi_len_n50",
    "HiFi Read Quality (median)": "movie_hifi_rq_median",
    "HiFi Number of Passes (mean)": "movie_hifi_passes_mean",
}
CCS_REPORT_PCT_FIELDS = {
    "Base quality >=Q30 (bp)": "movie_q30_pct",
}
CCS_REPORT_LINE_RE = re.compile(r"^(.+?)\s*:\s*([\d,]+)(?:\s*\(([\d.]+)%\))?\s*$")


def parse_ccs_report(path):
    out = {}
    if not path or not os.path.isfile(path):
        return out
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            m = CCS_REPORT_LINE_RE.match(line.rstrip("\n"))
            if not m:
                continue
            label, count, pct = m.group(1).strip(), m.group(2), m.group(3)
            if label in CCS_REPORT_FIELDS:
                out[CCS_REPORT_FIELDS[label]] = count.replace(",", "")
            if label in CCS_REPORT_PCT_FIELDS and pct is not None:
                out[CCS_REPORT_PCT_FIELDS[label]] = pct
    return out


def parse_lima_counts(path, barcode_id):
    """Returns (count, mean_score) for one barcode from a lima_counts.txt
    table, or ('', '') if not found / file missing."""
    if not path or not os.path.isfile(path):
        return "", ""
    with open(path, "r", encoding="utf-8", errors="ignore") as fh:
        lines = [l.rstrip("\n") for l in fh]
    if not lines:
        return "", ""
    header = lines[0].split("\t")
    try:
        name_idx = header.index("IdxFirstNamed")
        counts_idx = header.index("Counts")
        score_idx = header.index("MeanScore")
    except ValueError:
        return "", ""
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) <= max(name_idx, counts_idx, score_idx):
            continue
        if fields[name_idx] == barcode_id:
            return fields[counts_idx], fields[score_idx]
    return "", ""


def parse_consensusreadset_xml(path):
    if not path or not os.path.isfile(path):
        return "", ""
    try:
        root = parse_xml_stripped(path)
    except ET.ParseError:
        return "", ""
    return root.findtext(".//NumRecords", ""), root.findtext(".//TotalLength", "")


def find_native_bam(subdir, movie_name, barcode_id):
    """Looks for <movie>.hifi_reads.<barcode>.bam under subdir (hifi_reads/
    or fail_reads/), falling back to a glob if the exact name doesn't match."""
    exact = os.path.join(subdir, f"{movie_name}.hifi_reads.{barcode_id}.bam")
    if os.path.isfile(exact):
        return exact
    matches = [m for m in glob.glob(os.path.join(subdir, f"*{barcode_id}*.bam")) if not m.endswith(".pbi")]
    return matches[0] if matches else None


def build_native_layout_samples(sample_dir):
    """Yields one run_info values dict per BioSample/barcode found in this
    native-layout sample directory's metadata.xml."""
    metadata_dir = os.path.join(sample_dir, "metadata")
    metadata_xml = find_metadata_xml(metadata_dir)
    if metadata_xml is None:
        print(f"WARNING: no (non-preview) *.metadata.xml found in {metadata_dir}, skipping", file=sys.stderr)
        return
    try:
        shared, bio_samples = parse_run_metadata_xml(metadata_xml)
    except ET.ParseError as exc:
        print(f"WARNING: failed to parse {metadata_xml}: {exc}, skipping", file=sys.stderr)
        return
    if not bio_samples:
        print(f"WARNING: no BioSample found in {metadata_xml}, skipping", file=sys.stderr)
        return

    movie_name = shared["movie_name"]
    stats_dir = os.path.join(sample_dir, "statistics")
    pb_formats_dir = os.path.join(sample_dir, "pb_formats")
    hifi_dir = os.path.join(sample_dir, "hifi_reads")

    movie_ccs_stats = parse_ccs_report(os.path.join(stats_dir, f"{movie_name}.ccs_report.txt"))
    lima_counts_path = os.path.join(stats_dir, f"{movie_name}.hifi_reads.lima_counts.txt")

    for bio in bio_samples:
        barcode_id = bio["barcode_id"]
        bam_path = find_native_bam(hifi_dir, movie_name, barcode_id) if barcode_id else None
        sample_zmw_count, sample_barcode_score = (
            parse_lima_counts(lima_counts_path, barcode_id) if barcode_id else ("", "")
        )

        consensus_xml = (
            os.path.join(pb_formats_dir, f"{movie_name}.hifi_reads.{barcode_id}.consensusreadset.xml")
            if barcode_id else None
        )
        consensus_num_records, consensus_total_length_bp = parse_consensusreadset_xml(consensus_xml)

        file_size = str(os.path.getsize(bam_path)) if bam_path and os.path.exists(bam_path) else ""
        pbi_present = bool(bam_path) and os.path.exists(bam_path + ".pbi")
        # No checksum manifest has been seen alongside this layout; still
        # check, in case one shows up in some deliveries -- find_checksum()
        # just returns "" if nothing matches.
        checksum = find_checksum(bam_path, sample_dir, sample_dir) if bam_path else ""

        # Start from "" for every key used by either sample-directory layout
        # (ALL_RUN_INFO_KEYS is defined further down, alongside
        # RUN_INFO_COLUMN_DEFS -- fine at call time since this only runs
        # inside main()), so columns only the facility-repackaged layout
        # populates render blank here instead of raising a KeyError in
        # upsert_row.
        values = {**{key: "" for key in ALL_RUN_INFO_KEYS}, **shared}
        values.update({
            "sample_name": bio["sample_name"] or os.path.basename(sample_dir),
            "barcode_seq": bio["barcode_seq"],
            "sample_zmw_count": sample_zmw_count,
            "sample_barcode_score": sample_barcode_score,
            "consensus_num_records": consensus_num_records,
            "consensus_total_length_bp": consensus_total_length_bp,
            "sha256_checksum": checksum,
            "file_size_bytes": file_size,
            "pbi_present": yes_no(pbi_present),
            "file_path": bam_path or "",
            "_pm_tag": "REVIO",
        })
        values.update(movie_ccs_stats)
        yield values


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


def platform_cell(platform_match):
    if platform_match:
        name, tsr, tan = platform_match
        return CompositeCell.create_term_from_string(name, tsr, tan)
    return CompositeCell.create_term_from_string("")


def single_end_cell(_value):
    # A HiFi/CCS read is one consensus sequence per ZMW/molecule -- no R1/R2
    # pairing applies, same reasoning the ONT harvester uses for nanopore.
    return CompositeCell.create_term_from_string("single-end", "DPBO", "DPBO:0000086")


def passthrough_cell(value):
    """value is already a fully-built CompositeCell."""
    return value


# ---------------------------------------------------------------------------
# "run_information" column definitions: (header, value_key, cell_factory)
# ---------------------------------------------------------------------------
# As with the ONT harvester: column headers use a real ontology term's own
# preferred label wherever a term is attached; columns with no verified term
# (PacBio-specific chemistry/kit/QC concepts mostly have none in OBI/EDAM/NCIT
# yet) keep a plain descriptive name instead of inventing an ID.
RUN_INFO_COLUMN_DEFS = [
    (CompositeHeader.input(IOType.sample()), "sample_name", free_text_cell),
    (CompositeHeader.protocol_ref(), "_blank", blank_free_text_cell),
    (CompositeHeader.parameter(OntologyAnnotation("Run Identifier", "NCIT", "NCIT:C117058")), "run_id", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie name")), "movie_name", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("SMRT Cell identifier")), "smrt_cell_id", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("Instrument Identification Number", "NCIT", "NCIT:C178947")), "instrument_id", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("binding kit")), "binding_kit", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("sequencing kit")), "sequencing_kit", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("SMRT Cell kit")), "smrt_cell_kit", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("basecaller version")), "basecaller_version", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("instrument control software version")), "ics_version", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie length (minutes)")), "movie_length_min", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("frame rate (Hz)")), "frame_rate_hz", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("chemistry")), "chemistry", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("read type")), "read_type", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("barcode sequence")), "barcode_seq", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("barcode count in pool")), "barcode_count", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("barcode mode")), "barcode_mode", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("CCS software version")), "ccs_version", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("demultiplexing (lima) software version")), "lima_version", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("base modification calling enabled")), "base_mod_called", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("base modification types called")), "base_mod_types", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("kinetics retained in output")), "kinetics_retained", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("SHA256 Checksum")), "sha256_checksum", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("file size (bytes)")), "file_size_bytes", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("PBI index present")), "pbi_present", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("source file path")), "file_path", term_cell),
    # The columns below are only ever populated from the native on-instrument
    # Revio layout (metadata.xml / ccs_report.txt / lima stats /
    # consensusreadset.xml) -- blank for samples harvested from a BAM header
    # alone, since that layout doesn't carry this information.
    (CompositeHeader.parameter(OntologyAnnotation("Run UUID")), "run_uuid", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("chip type")), "chip_type", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("WellSample name (as entered at loading)")), "well_sample_name", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("well position")), "well_name", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("on-plate loading concentration (pM)")), "loading_concentration", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("target insert size (bp)")), "insert_size_target", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("SMRT Cell lot number")), "smrt_cell_lot", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("SMRT Cell expiration date")), "smrt_cell_expiry", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("control kit part number")), "control_kit_pn", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("template prep kit")), "template_prep_kit", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("sequencing kit lot number")), "sequencing_kit_lot", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("sequencing kit expiration date")), "sequencing_kit_expiry", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("demultiplex preset")), "demux_preset", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("jasmine software version")), "jasmine_version", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie HiFi ZMWs input")), "movie_zmws_input", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie HiFi reads")), "movie_hifi_reads", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie HiFi yield (bp)")), "movie_hifi_yield_bp", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie HiFi read length mean (bp)")), "movie_hifi_len_mean", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie HiFi read length N50 (bp)")), "movie_hifi_len_n50", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie HiFi read quality (median)")), "movie_hifi_rq_median", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie HiFi number of passes (mean)")), "movie_hifi_passes_mean", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("movie base quality >=Q30 (%)")), "movie_q30_pct", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("this barcode's ZMW count (lima)")), "sample_zmw_count", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("this barcode's mean barcode score (lima)")), "sample_barcode_score", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("number of HiFi reads (this BAM)")), "consensus_num_records", term_cell),
    (CompositeHeader.parameter(OntologyAnnotation("total bases (this BAM)")), "consensus_total_length_bp", term_cell),
]

# Every key any column factory might look up, across BOTH sample-directory
# layouts. Used to pre-fill a values dict with "" for whichever columns the
# current sample's layout doesn't populate, so upsert_row never KeyErrors
# regardless of which layout produced a given row.
ALL_RUN_INFO_KEYS = [key for _header, key, _factory in RUN_INFO_COLUMN_DEFS]

# Flags in jasmine's recorded command line (@PG CL) that indicate which base
# modification(s) were called. Extend this list if other flags are seen.
JASMINE_MOD_FLAGS = {
    "--6ma": "6mA",
    "--5mc": "5mC",
    "--m6a": "6mA",
    "--cpg": "5mC (CpG)",
}


def build_run_info_values(sample_name, batch_dir, sample_dir, bam_path, header):
    rg = header["rg"]
    ds = rg.get("DS_parsed", {})
    pg = header["pg"]

    movie_name = rg.get("PU", "")
    # PacBio's own movie-naming convention bakes the instrument serial into
    # the first underscore-delimited token: m<serial>_<date>_<time>_s<slot>.
    instrument_match = re.match(r"^m(\d+)_", movie_name)
    instrument_id = instrument_match.group(1) if instrument_match else ""

    jasmine_cl = pg.get("jasmine", {}).get("CL", "")
    mod_types = sorted({label for flag, label in JASMINE_MOD_FLAGS.items() if flag in jasmine_cl})

    # str(...) up front, not left for the cell factory: term_cell/free_text_cell
    # treat a falsy value (0, not just None/"") as "blank", which would wrongly
    # hide a genuine 0-byte file size instead of reporting it.
    file_size = str(os.path.getsize(bam_path)) if os.path.exists(bam_path) else ""
    pbi_present = os.path.exists(bam_path + ".pbi")
    checksum = find_checksum(bam_path, sample_dir, batch_dir)

    # Start from "" for every key used by either sample-directory layout, so
    # the columns only the native layout populates (lot numbers, well info,
    # yield stats, ...) render blank here instead of raising a KeyError in
    # upsert_row.
    return {
        **{key: "" for key in ALL_RUN_INFO_KEYS},
        "sample_name": sample_name,
        "_blank": "",
        "run_id": ds.get("RUNID", ""),
        "movie_name": movie_name,
        "smrt_cell_id": ds.get("SMRTCELLID", ""),
        "instrument_id": instrument_id,
        "binding_kit": ds.get("BINDINGKIT", ""),
        "sequencing_kit": ds.get("SEQUENCINGKIT", ""),
        "smrt_cell_kit": ds.get("SMRTCELLKIT", ""),
        "basecaller_version": ds.get("BASECALLERVERSION", ""),
        "ics_version": ds.get("ICSVERSION", ""),
        "movie_length_min": ds.get("MOVIELENGTH", ""),
        "frame_rate_hz": ds.get("FRAMERATEHZ", ""),
        "chemistry": rg.get("CM", ""),
        "read_type": ds.get("READTYPE", ""),
        "barcode_seq": rg.get("BC", ""),
        "barcode_count": ds.get("BarcodeCount", ""),
        "barcode_mode": ds.get("BarcodeMode", ""),
        "ccs_version": pg.get("ccs", {}).get("VN", ""),
        "lima_version": pg.get("lima", {}).get("VN", ""),
        "base_mod_called": yes_no(mod_types),
        "base_mod_types": ", ".join(mod_types),
        "kinetics_retained": yes_no("--keep-kinetics" in jasmine_cl),
        "sha256_checksum": checksum,
        "file_size_bytes": file_size,
        "pbi_present": yes_no(pbi_present),
        "file_path": bam_path,
    }


def build_ena_column_defs(template_headers):
    h = template_headers
    return [
        (h[0], "sample_name", free_text_cell),
        (h[1], "platform_cell", passthrough_cell),
        (h[2], "library_name", term_cell),
        (h[3], "_blank_library_source", blank_term_cell),
        (h[4], "_blank_library_selection", blank_term_cell),
        (h[5], "_blank_library_strategy", blank_term_cell),
        (h[6], "_single_end", single_end_cell),
        (h[7], "_blank_md5", blank_term_cell),
        (h[8], "_blank_output_data", blank_data_cell),
        # Not part of the official ENA template -- appended purely so a
        # sample re-run on a second SMRT Cell gets its own Reads row instead
        # of overwriting the first (see key_fields in main()), and because
        # the movie name is useful provenance to have on the Reads sheet too.
        (CompositeHeader.parameter(OntologyAnnotation("movie name")), "movie_name", term_cell),
    ]


_ENA_CONSTANT_KEYS = [
    "_blank_library_source",
    "_blank_library_selection",
    "_blank_library_strategy",
    "_single_end",
    "_blank_md5",
    "_blank_output_data",
]


def build_ena_values(run_info_values):
    rg_pm = run_info_values.get("_pm_tag", "")
    values = {
        "sample_name": run_info_values["sample_name"],
        "platform_cell": platform_cell(infer_platform(rg_pm)),
        "library_name": run_info_values.get("_library_name", ""),
        "movie_name": run_info_values["movie_name"],
    }
    values.update({key: "" for key in _ENA_CONSTANT_KEYS})
    return values


# ---------------------------------------------------------------------------
# Generic table create/update helpers (identical to the ONT harvester).
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


def discover_samples(run_dir, samtools_bin):
    """Yields one run_info_values dict per sample found under run_dir,
    dispatching each sample directory to whichever layout it matches (a
    project can mix both, e.g. different batches delivered by different
    means). Skips (with a warning to stderr) anything that can't be parsed,
    rather than aborting the whole harvest."""
    for batch_dir in discover_batches(run_dir):
        for sample_dir in discover_sample_dirs(batch_dir):
            if is_native_layout(sample_dir):
                yield from build_native_layout_samples(sample_dir)
                continue

            bam_path, all_bams = pick_primary_bam(sample_dir)
            if bam_path is None:
                print(f"WARNING: no *.bam found in {sample_dir}, skipping", file=sys.stderr)
                continue
            if len(all_bams) > 1:
                print(
                    f"NOTE: {len(all_bams)} BAM files in {sample_dir}; "
                    f"using {os.path.basename(bam_path)}", file=sys.stderr,
                )
            try:
                header = parse_bam_header(samtools_bin, bam_path)
            except subprocess.CalledProcessError as exc:
                print(f"WARNING: samtools failed on {bam_path}: {exc}, skipping", file=sys.stderr)
                continue

            rg = header["rg"]
            sample_name = rg.get("SM") or os.path.basename(sample_dir)
            values = build_run_info_values(sample_name, batch_dir, sample_dir, bam_path, header)
            values["_pm_tag"] = rg.get("PM", "")
            values["_library_name"] = rg.get("LB", "")
            yield values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", required=True, help="Path to the PacBio project directory (contains Batch*/ subdirectories)")
    parser.add_argument("--arc-path", required=True, help="Path to the target ARC root directory")
    parser.add_argument("--assay-name", required=True, help="Name of the assay under <arc-path>/assays/<assay-name>")
    parser.add_argument("--samtools", default="samtools", help="Path to the samtools executable")
    parser.add_argument("--dry-run", action="store_true", help="Parse and print what would be written, without touching the ARC")
    args = parser.parse_args()

    run_dir = os.path.abspath(args.run_dir)
    assay_file = os.path.join(args.arc_path, "assays", args.assay_name, "isa.assay.xlsx")

    if not os.path.isdir(run_dir):
        sys.exit(f"Run directory not found: {run_dir}")
    if not args.dry_run and not os.path.isfile(assay_file):
        sys.exit(f"Assay file not found: {assay_file}")

    run_info_rows = list(discover_samples(run_dir, args.samtools))
    if not run_info_rows:
        sys.exit(f"No sample BAMs found under {run_dir}")
    ena_rows = [build_ena_values(values) for values in run_info_rows]

    if args.dry_run:
        for ri, ena in zip(run_info_rows, ena_rows):
            printable = {k: v for k, v in ri.items() if not k.startswith("_")}
            print("run_information:", printable)
            print("Reads platform:", ena["platform_cell"].GetContent(), "library:", ena["library_name"])
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
        ena_outcome = upsert_row(reads_table, ena_column_defs, ena_values, key_fields=["sample_name", "movie_name"])
        results.append((values["sample_name"], values["movie_name"], outcome, ena_outcome))

    def write_back(table, is_new, table_name):
        if is_new:
            assay.AddTable(table)
        else:
            table_names = list(assay.TableNames)
            assay.SetTableAt(table_names.index(table_name), table)

    write_back(run_info_table, run_info_is_new, RUN_INFO_TABLE_NAME)
    write_back(reads_table, reads_is_new, ENA_TABLE_NAME)
    XlsxController.Assay().to_xlsx_file(assay_file, assay)

    for sample_name, movie_name, run_info_outcome, reads_outcome in results:
        print(f"{sample_name} ({movie_name}): run_information={run_info_outcome}, Reads={reads_outcome}")


if __name__ == "__main__":
    main()
PYEOF

echo "finished pacbio_harvest run of ${ASSAY_NAME}/$(basename "${RUN_DIR}") after ${SECONDS} seconds"
