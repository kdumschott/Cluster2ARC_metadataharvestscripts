### PacBio (Revio/Sequel) outputs to ARC assay

A script to harvest metadata from a PacBio (Revio/Sequel) sequencing project and write it into an ARC isa.assay.xlsx file using ARCtrl. 

#### To run

`RUN_DIR=/path/to/pacbio_project ARC_PATH=/path/to/arc ASSAY_NAME=myassay \
  bash harvest_pacbio_metadata.sh`

  `RUN_DIR` is the project directory containing the batches (`Batch1/`, `Batch2/`, ... or, if none exist, its direct subdirectories are treated as the samples).

  #### Description

  The script detects the sample directory layout

| | **(A) Facility-repackaged** | **(B) Native on-instrument Revio output** |
|---|---|---|
| Shape | just the final demuxed `<movie>.hifi_reads.bc####.bam[.pbi]` | `hifi_reads/`, `fail_reads/`, `metadata/`, `pb_formats/`, `statistics/` subdirectories |
| Source read | `samtools view -H` on the BAM — header only, never the read body | small XML/JSON/txt files only — `metadata.xml`, `ccs_report.txt`, `lima_summary/counts.txt`, `consensusreadset.xml` — the BAM itself is never opened |
| What it gets | run/chemistry/barcode info from the `@RG`/`@PG` tags | far richer: exact kit lot numbers & expiry dates, well/loading info, movie-wide HiFi yield & quality stats, per-barcode demux counts |

A single `RUN_DIR` can mix both layouts (different batches delivered differently) — detection and parsing happen per sample directory.

The metadata is then written into one of two sheets:

- `Reads` — the official DataPLANT ENA “Raw sequencing reads” template fields (sample name, instrument model as an OBI term, library name, `single-end` layout), plus one extra `Parameter [movie name]` column appended beyond the template, needed because PacBio samples are routinely resequenced on a second SMRT Cell — keying rows on `(sample, movie)` instead of sample alone stops a resequenced sample from overwriting its first row.\
- `run_information` — everything else: run/movie/instrument/cell/kit identifiers, software versions, barcode info, base-modification (6mA/5mC) and kinetics-retained flags, checksum, file size, .pbi presence, and (layout B only) well/loading details, lot numbers & expiry dates, and movie-wide + per-barcode yield/QC stats. Columns only layout B can populate are simply blank for layout A rows, and vice versa.

Re-running against the same `RUN_DIR` updates matching rows in place rather than duplicating them.

#### Checksum handling

The script searches both the sample directory and its batch directory for a checksum manifest, tolerating naming conventions actually seen in the real data (`checksums_*.sha256`, `sha256sum*.txt`, typos like `sha265sums*.txt`, etc.) and both `hash filename` / `filename hash` line orderings.

#### Ontology terms used
- Column headers: 6 of the Reads sheet’s 9 columns carry a term from the official template (DPBO/NCIT/GENEPIO); 2 `run_information` columns carry an NCIT term (Run Identifier, Instrument ID).
- Cell values: The instrument model resolves to an OBI term per sample (OBI:0003922 Revio, down to OBI:0002012 RS II); library layout is always single-end (DPBO:0000086).
