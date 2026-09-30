## Cluster Metadata to ARC isa sheets

This repository contains scripts for transcribing metadata from the cluster to ARC study and assay isa.xlsx files



### Metadata2ARCassay_ONT

A script to extract relevant information from ONT sequencing run reports and annotate ARC assay metadata tables.

#### To run

 `RUN_DIR=/path/to/run ARC_PATH=/path/to/arc ASSAY_NAME=myassay bash harvest_ont_metadata.sh`

 #### Description

 The script harvests the relevant MinKNOW metadata and adds them to the isa.assay.xlsx sheets as follows:

<img width="1124" height="496" alt="Image" src="https://github.com/user-attachments/assets/2f508065-943c-45e0-b808-e1cf50b18798" />

 #### Expected Output

`started ont_harvest run of ONT_metadataharvest/RUN_NAME_HERE at 0 seconds Cannot retrieve metadata: Assay file does not contain "isa_assay" or "Assay" sheet. Ribes_fruits_cDNA_batch6_prom: run_information=created, Reads=appended finished ont_harvest run of ONT_metadataharvest/20260805_1738_1E_PBM32781_1b6a4fa8 after 1 seconds`

The warning `Cannot retrieve metadata: Assay file does not contain "isa_assay" or "Assay" sheet.` is from the ARCtrl regarding the ENA template sheet and can be ignored.

#### Current status of what metadata is harvested and to which assay sheet

Here's the current, up-to-date mapping:

| Harvested value | Source file | Ontology term | ARC assay sheet | Column heading |
|---|---|---|---|---|
| Sample ID | `sample_sheet.csv` (`sample_id`, fallback `final_summary.txt`) | — (structural header) | run_information + Reads (ENA Template) | `Input [Sample Name]` |
| Run ID | `sample_sheet.csv`/`final_summary.txt` (`protocol_run_id`) | `NCIT:C117058` | run_information | `Parameter [Run Identifier]` |
| Flow cell ID | `sample_sheet.csv`/`final_summary.txt` (`flow_cell_id`) | `EDAM:data_3733` | run_information | `Parameter [Flow cell identifier]` |
| Flow cell position | `sample_sheet.csv`/`final_summary.txt` (`position_id`/`position`) | — none | run_information | `Parameter [flow cell position]` |
| Flow cell product code | `sample_sheet.csv` (`flow_cell_product_code`) | — none | run_information | `Parameter [flow cell product code]` |
| Library kit | `sample_sheet.csv` (`kit`) | `GENEPIO:0000085` | run_information | `Component [library preparation kit]` |
| Instrument ID | `final_summary.txt` (`instrument`) | `NCIT:C178947` | run_information | `Parameter [Instrument Identification Number]` |
| Experiment/protocol group ID | `sample_sheet.csv`/`final_summary.txt` (`experiment_id`/`protocol_group_id`) | `AFO:AFR_0002009` | run_information | `Parameter [experiment identifier]` |
| Run start date | `final_summary.txt` (`started`, date part) | `NCIT:C68616` | run_information | `Parameter [Start Date]` |
| Run start time | `final_summary.txt` (`started`, time part) | `NCIT:C78441` | run_information | `Parameter [Start Time]` |
| Run stop date | `final_summary.txt` (`acquisition_stopped`, date part) | `NCIT:C68617` | run_information | `Parameter [End Date]` |
| Run stop time | `final_summary.txt` (`acquisition_stopped`, time part) | `NCIT:C82573` | run_information | `Parameter [End Time]` |
| Basecalling enabled | `final_summary.txt` (`basecalling_enabled`) | — none | run_information | `Parameter [basecalling enabled]` |
| pod5 file count | `final_summary.txt` (`pod5_files_in_final_dest`) | — none | run_information | `Parameter [pod5 file count]` |
| fastq file count | `final_summary.txt` (`fastq_files_in_final_dest`) | — none | run_information | `Parameter [fastq file count]` |
| Sequencing platform | derived (flow cell code + instrument hostname) | `OBI:0002752`/`OBI:0002750`/`OBI:0002751` (PromethION/MinION/GridION) | Reads (ENA Template) | `Component [next generation sequencing instrument model]` |
| Library layout | derived (always "single-end" for ONT) | `DPBO:0000086` | Reads (ENA Template) | `Parameter [library layout]` |
| Library name / source / selection / strategy / MD5 / Output data | — (left blank) | — | Reads (ENA Template) | 6 columns, left for manual annotation |

