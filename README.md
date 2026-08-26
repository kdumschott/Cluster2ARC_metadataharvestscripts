## Metadata2ARCassay_ONT

A semi-automated metadata harvesting pipeline to extract relevant information from ONT sequencing run reports and annotate ARC assay metadata tables.

#### To run

 `RUN_DIR=/path/to/run ARC_PATH=/path/to/arc ASSAY_NAME=myassay bash harvest_ont_metadata.sh`

 #### Description

 The script harvests the relevant MinKNOW metadata and adds them to the isa.assay.xlsx sheets as follows:

<img width="1124" height="496" alt="Image" src="https://github.com/user-attachments/assets/2f508065-943c-45e0-b808-e1cf50b18798" />

 #### Expected Output

`started ont_harvest run of ONT_metadataharvest/RUN_NAME_HERE at 0 seconds Cannot retrieve metadata: Assay file does not contain "isa_assay" or "Assay" sheet. Ribes_fruits_cDNA_batch6_prom: run_information=created, Reads=appended finished ont_harvest run of ONT_metadataharvest/20260805_1738_1E_PBM32781_1b6a4fa8 after 1 seconds`

The warning `Cannot retrieve metadata: Assay file does not contain "isa_assay" or "Assay" sheet.` is from the ARCtrl regarding the ENA template sheet and can be ignored.
