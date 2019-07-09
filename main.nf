#!/usr/bin/env nextflow

// Default values for boolean flags
params.interleaved = false
params.paired = false
params.from_ncbi_sra = false
params.humann = false
params.help = false

def helpMessage() {
    log.info"""
    Usage:

    nextflow run fredhutch/geneshot <ARGUMENTS>
    
    Arguments:
      --batchfile        CSV file listing samples to analyze (see below)
      --ref_dmnd         Path to reference database in DIAMOND (.dmnd) format
      --ref_hdf5         Path to HDF5 file containing reference database metadata
      --output_folder    Folder to place outputs
      --output_prefix    Name for output files

    Options:
      --paired           Input data is paired-end FASTQ in two files (otherwise treat as single-ended)
      --interleaved      Input data is interleaved paired-end FASTQ in one file (otherwise treat as single-ended)
      --from_ncbi_sra    Input data is specified as NCBI SRA accessions (*RR*) in the `run` column
      --humann           Run the HUMAnN2 pipeline on all samples.

    Batchfile:
      The batchfile is a CSV with a header indicating which samples correspond to which files.
      The file must contain a column `name`. 
      Default is to expect a single column `fastq` pointing to a single-ended or interleaved FASTQ.
      If data is --paired, reads are specified by two columns, `fastq1` and `fastq2`.
      If data is --from_ncbi_sra, accessions are specified in the `run` column.

    """.stripIndent()
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// Show help message
if (params.help){
    helpMessage()
    exit 0
}
// --output_folder is the folder in which to place the results
params.output_folder = "./"

// --output_prefix is the name to prepend to all output files
params.output_prefix = "geneshot_output"

// Logic to handle different types of input data
if ( params.from_ncbi_sra ){

  Channel.from(file(params.batchfile))
        .splitCsv(header: true, sep: ",")
        .map { sample ->
          tuple(sample["name"], sample["run"])}
        .set{ accession_ch }

  // Download the FASTQ files
  process downloadSraFastq {
      container "quay.io/fhcrc-microbiome/get_sra:v0.4"
      cpus 4
      memory "8 GB"
      errorStrategy "retry"

      input:
      set val(sample_name), val(accession) from accession_ch

      output:
      set val(sample_name), file("${accession}.fastq.gz") into concatenate_ch

      afterScript "rm -rf *"

"""
# Cache to the local folder
mkdir -p ~/.ncbi
mkdir cache
echo '/repository/user/main/public/root = "\$PWD/cache"' > ~/.ncbi/user-settings.mkfg

# Get each read
echo "Get the FASTQ files"
fastq-dump --split-files --defline-seq '@\$ac.\$si.\$sg/\$ri' --defline-qual + --outdir \$PWD ${accession}

r1=_1.fastq
r2=_2.fastq

# If there is a second read, interleave them
if [[ -s ${accession}\$r2 ]]; then
    echo "Making paired reads"
    fastq_pair ${accession}\$r1 ${accession}\$r2
    
    echo "Interleave"
    paste ${accession}\$r1.paired.fq ${accession}\$r2.paired.fq | paste - - - - | awk -v OFS="\\n" -v FS="\\t" '{print(\$1,\$3,\$5,\$7,\$2,\$4,\$6,\$8)}' | gzip -c > "${accession}.fastq.gz"
else
    echo "Compressing"
    mv ${accession}\$r1 ${accession}.fastq
    gzip ${accession}.fastq
fi

rm -f ${accession}\$r1 ${accession}\$r2 ${accession}\$r1.paired.fq ${accession}\$r2.paired.fq

"""
  }
}
else {
  if ( params.paired ){
    assert !params.interleaved: "--paired cannot be specified together with --interleaved"

    Channel.from(file(params.batchfile))
          .splitCsv(header: true, sep: ",")
          .map { sample ->
          [sample.name, file(sample.fastq1), file(sample.fastq2)]}
          .set{ interleave_ch }

    process interleave {
      container "ubuntu:16.04"
      cpus 4
      memory "8 GB"
      errorStrategy "retry"

      input:
      set sample_name, file(fastq1), file(fastq2) from interleave_ch

      output:
      set sample_name, file("${fastq1}.interleaved.fastq.gz") into concatenate_ch

      afterScript "rm *"

      """
      set -e

      # Some basic checks that the files exist and the line numbers match
      [[ -s "${fastq1}" ]]
      [[ -s "${fastq2}" ]]
      (( \$(gunzip -c ${fastq1} | wc -l) == \$(gunzip -c ${fastq2} | wc -l) ))

      # Now interleave the files
      paste <(gunzip -c ${fastq1}) <(gunzip -c ${fastq2}) | paste - - - - | awk -v OFS="\\n" -v FS="\\t" '{print(\$1,\$3,\$5,\$7,\$2,\$4,\$6,\$8)}' | gzip -c > "${fastq1}.interleaved.fastq.gz"
      """
        
    }

  }
  else {
      // For either `interleaved` or `single` (no flags), just put the FASTQ into the same analysis queue
      Channel.from(file(params.batchfile))
          .splitCsv(header: true, sep: ",")
          .map { sample ->
          [sample.name, file(sample.fastq)]}
          .set{ concatenate_ch }

  }
}

// Concatenate reads by sample name
process concatenate {
  container "ubuntu:16.04"
  cpus 4
  memory "8 GB"
  errorStrategy "retry"
  
  input:
  set sample_name, file(fastq_list) from concatenate_ch.groupTuple()
  
  output:
  set sample_name, file("${sample_name}.fastq.gz") into correct_headers_ch

  afterScript "rm *"

  """
set -e
ls -lahtr
cat ${fastq_list} > TEMP && mv TEMP ${sample_name}.fastq.gz
  """

}

// Make sure that every read has a unique name
process correctHeaders {
  container "ubuntu:16.04"
  cpus 4
  memory "8 GB"
  errorStrategy "retry"
  
  input:
  set sample_name, file(fastq) from correct_headers_ch.groupTuple()
  
  output:
  set sample_name, file("${sample_name}.unique.headers.fastq.gz") into count_reads, metaphlan_ch, diamond_ch, humann_ch

  afterScript "rm *"

  """
set -e

gunzip -c ${fastq} | \
awk '{if(NR % 4 == 1){print("@" 1 + ((NR - 1) / 4))}else{print}}' | \
gzip -c > \
${sample_name}.unique.headers.fastq.gz
  """

}

// Count the number of input reads
process countReads {
  container "ubuntu:16.04"
  cpus 1
  memory "4 GB"
  errorStrategy "retry"
  
  input:
  set sample_name, file(fastq) from count_reads
  
  output:
  file "${sample_name}.countReads.csv" into total_counts

  afterScript "rm *"

  """
set -e

[[ -s ${fastq} ]]

n=\$(gunzip -c "${fastq}" | awk 'NR % 4 == 1' | wc -l)
echo "${sample_name},\$n" > "${sample_name}.countReads.csv"
  """

}

process countReadsSummary {
  container "ubuntu:16.04"
  cpus 1
  memory "4 GB"
  publishDir "${params.output_folder}"
  errorStrategy "retry"

  input:
  file readcount_csv_list from total_counts.collect()
  val output_prefix from params.output_prefix
  
  output:
  file "${output_prefix}.readcounts.csv" into readcounts_csv

  afterScript "rm *"

  """
set -e

echo name,n_reads > TEMP
cat ${readcount_csv_list} >> TEMP && mv TEMP ${output_prefix}.readcounts.csv
  """

}

process metaphlan2 {
    container "quay.io/fhcrc-microbiome/metaphlan@sha256:51b416458088e83d0bd8d840a5a74fb75066b2435d189c5e9036277d2409d7ea"
    cpus 16
    memory "32 GB"

    input:
    set val(sample_name), file(input_fastq) from metaphlan_ch
    
    output:
    file "${sample_name}.metaphlan.tsv" into metaphlan_for_summary, metaphlan_for_humann

    afterScript "rm *"

    """
    set -e
    metaphlan2.py --input_type fastq --tmp_dir ./ -o ${sample_name}.metaphlan.tsv ${input_fastq}
    """
}

if (params.humann) {
  process HUMAnN2_DB {
    container "quay.io/fhcrc-microbiome/humann2:v0.11.2--1"
    cpus 16
    memory "120 GB"

    output:
    file "HUMANn2_DB.tar" into humann_db

    afterScript "rm -rf *"

    """
set -e

# Make a folder for the database files
mkdir HUMANn2_DB

# Download the databases
humann2_databases --download chocophlan full HUMANn2_DB
humann2_databases --download uniref uniref90_diamond HUMANn2_DB

# Tar up the database
tar cvf HUMANn2_DB.tar HUMANn2_DB

    """
  }

  process HUMAnN2 {
    container "quay.io/fhcrc-microbiome/humann2:v0.11.2--1"
    cpus 16
    memory "120 GB"

    input:
    set sample_name, file(fastq), file(metaphlan_output) from humann_ch.join(metaphlan_for_humann)
    val threads from 16
    file humann_db

    output:
    set file("${sample_name}_genefamilies.tsv"), file("${sample_name}_pathabundance.tsv"), file("${sample_name}_pathcoverage.tsv") into humann_summary

    """
set -e

# Untar the database
tar xzvf ${humann_db}

# Folder for output
mkdir output

humann2 \
  --input ${fastq} \
  --output output \
  --nucleotide-database HUMANn2_DB/chocophlan \
  --protein-database HUMANn2_DB/uniref \
  --threads ${threads} \
  --taxonomic-profile ${metaphlan_output}

mv output/*_genefamilies.tsv ${sample_name}_genefamilies.tsv
mv output/*_pathabundance.tsv ${sample_name}_pathabundance.tsv
mv output/*_pathcoverage.tsv ${sample_name}_pathcoverage.tsv
    """
  }

  process HUMAnN2summary {
    container "quay.io/fhcrc-microbiome/python-pandas:latest"
    cpus 4
    memory "8 GB"
    publishDir "${params.output_folder}"

    input:
    file humann_tsv_list from humann_summary.toSortedList().flatten()
    val output_prefix from params.output_prefix

    output:
    file "${output_prefix}.HUMAnN2.genefamilies.csv" into humann_genefamilies_csv
    file "${output_prefix}.HUMAnN2.pathabundance.csv" into humann_pathabundance_csv
    file "${output_prefix}.HUMAnN2.pathcoverage.csv" into humann_pathcoverage_csv

    """
#!/usr/bin/env python3
import logging
import os
import pandas as pd

# Set up logging
logFormatter = logging.Formatter(
    '%(asctime)s %(levelname)-8s [HUMAnN2summary] %(message)s'
)
rootLogger = logging.getLogger()
rootLogger.setLevel(logging.INFO)

# Write logs to STDOUT
consoleHandler = logging.StreamHandler()
consoleHandler.setFormatter(logFormatter)
rootLogger.addHandler(consoleHandler)

def combine_outputs(suffix, header):
    all_dat = []
    for fp in os.listdir("."):
        if fp.endswith(suffix):
            logging.info("Reading in %s" % (fp))
            d = pd.read_csv(
                fp, 
                sep="\\t", 
                comment="#",
                names=header
            )
            d["sample"] = fp.replace(suffix, "")
            all_dat.append(d)
    logging.info("Concatenating all data")
    return pd.concat(all_dat)

combine_outputs(
    "_genefamilies.tsv",
    ["gene_family", "RPK"]
).to_csv("${output_prefix}.HUMAnN2.genefamilies.csv")
logging.info("Wrote out %s" % ("${output_prefix}.HUMAnN2.genefamilies.csv"))

combine_outputs(
    "_pathabundance.tsv",
    ["pathway", "abund"]
).to_csv("${output_prefix}.HUMAnN2.pathabundance.csv")
logging.info("Wrote out %s" % ("${output_prefix}.HUMAnN2.pathabundance.csv"))

combine_outputs(
    "_pathcoverage.tsv",
    ["pathway", "cov"]
).to_csv("${output_prefix}.HUMAnN2.pathcoverage.csv")
logging.info("Wrote out %s" % ("${output_prefix}.HUMAnN2.pathcoverage.csv"))

    """
  }

}

process diamond {
    container "quay.io/fhcrc-microbiome/famli@sha256:25c34c73964f06653234dd7804c3cf5d9cf520bc063723e856dae8b16ba74b0c"
    cpus 32
    memory "240 GB"
    errorStrategy "retry"
    
    input:
    set val(sample_name), file(input_fastq) from diamond_ch
    file refdb from file(params.ref_dmnd)
    val min_id from 90
    val query_cover from 50
    val cpu from 32
    val top from 1
    val min_score from 20
    val blocks from 15
    val query_gencode from 11

    output:
    set sample_name, file("${sample_name}.aln.gz") into aln_ch

    afterScript "rm *"

    """
    set -e
    diamond \
      blastx \
      --query ${input_fastq} \
      --out ${sample_name}.aln.gz \
      --threads ${cpu} \
      --db ${refdb} \
      --outfmt 6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore qlen slen \
      --min-score ${min_score} \
      --query-cover ${query_cover} \
      --id ${min_id} \
      --top ${top} \
      --block-size ${blocks} \
      --query-gencode ${query_gencode} \
      --compress 1 \
      --unal 0
    """

}


process famli {
    container "quay.io/fhcrc-microbiome/famli@sha256:241a7db60cb735abd59f4829e8ddda0451622b6eb2321f176fd9d76297d8c9e7"
    cpus 16
    memory "120 GB"
    errorStrategy "retry"
    
    input:
    set sample_name, file(input_aln) from aln_ch
    val cpu from 16
    val batchsize from 50000000

    output:
    file "${sample_name}.json.gz" into famli_json_for_summary

    afterScript "rm *"

    """
    set -e
    famli \
      filter \
      --input ${input_aln} \
      --output ${sample_name}.json \
      --threads ${cpu} \
      --batchsize ${batchsize}
    gzip ${sample_name}.json
    """

}

process summarizeExperiment {
    container "quay.io/fhcrc-microbiome/python-pandas:latest"
    cpus 16
    memory "32 GB"
    publishDir "${params.output_folder}"

    input:
    file metaphlan_tsv_list from metaphlan_for_summary.collect()
    file famli_json_list from famli_json_for_summary.collect()
    file ref_hdf5 from file(params.ref_hdf5)
    file batchfile from file(params.batchfile)
    file readcounts_csv
    val output_prefix from params.output_prefix

    output:
    file "${output_prefix}.hdf5" into output_hdf
    file "${output_prefix}.*.csv"

    afterScript "rm *"

"""
#!/usr/bin/env python3
import gzip
import json
import logging
import os
import pandas as pd

# Set up logging
logFormatter = logging.Formatter(
    '%(asctime)s %(levelname)-8s [assembleAbundances] %(message)s'
)
rootLogger = logging.getLogger()
rootLogger.setLevel(logging.INFO)

# Write logs to STDOUT
consoleHandler = logging.StreamHandler()
consoleHandler.setFormatter(logFormatter)
rootLogger.addHandler(consoleHandler)

# Rename the reference HDF5 to use as the output HDF5
assert os.path.exists("${ref_hdf5}")
if "${ref_hdf5}" != "${output_prefix}.hdf5":
    logging.info("Renaming ${ref_hdf5} to ${output_prefix}.hdf5")
    os.rename("${ref_hdf5}", "${output_prefix}.hdf5")
assert os.path.exists("${output_prefix}.hdf5")
# Open a connection to the output HDF5
store = pd.HDFStore("${output_prefix}.hdf5", mode="a")

# Write the batchfile to "metadata"
logging.info("Reading in %s" % ("${batchfile}"))
metadata = pd.read_csv("${batchfile}", sep=",")
logging.info("Writing metadata to HDF")
metadata.to_hdf(store, "metadata")

# Get all of the files with a given ending
def get_file_list(suffix, folder="."):
    for fp in os.listdir(folder):
        if fp.endswith(suffix):
            yield fp.replace(suffix, ""), fp

# Read in the KEGG KO labels
kegg_ko = pd.read_hdf(store, "/groups/KEGG_KO")

# Read in the NCBI taxid labels
taxid = pd.read_hdf(store, "/groups/NCBI_TAXID").set_index("allele")["taxid"]

# Read in all of the FAMLI results
def read_famli_json(sample_name, fp):
    logging.info("Reading in %s" % (fp))
    df = pd.DataFrame(
        json.load(gzip.open(fp, "rt"))
    )
    # Add the sample name
    df["sample"] = sample_name

    # Calculate the proportional abundance
    df["prop"] = df["depth"] / df["depth"].sum()

    # Add the taxonomic annotation
    df["taxid"] = df["id"].apply(taxid.get)

    return df

allele_abund = pd.concat([
    read_famli_json(sample_name, fp)
    for sample_name, fp in get_file_list(".json.gz")
])

# Write out the FAMLI results
allele_abund.to_csv("${output_prefix}.alleles.csv", sep=",", index=None)
allele_abund.to_hdf(store, "abund/alleles", format="table", data_columns=["sample", "id"], complevel=5)

# Read in all of the MetaPhlAn2 results
def read_metaphlan(sample_name, fp):
    logging.info("Reading in %s" % (fp))
    d = pd.read_csv(
        fp, 
        sep="\\t"
    ).rename(columns=dict([
        ("Metaphlan2_Analysis", "abund")
    ]))
    # Transform into a proportion
    d["abund"] = d["abund"].apply(float) / 100

    # Add the taxonomic rank
    tax_code = dict([
        ("k", "kingdom"),
        ("p", "phylum"),
        ("c", "class"),
        ("o", "order"),
        ("f", "family"),
        ("g", "genus"),
        ("s", "species"),
        ("t", "strain")
    ])

    d["rank"] = d["#SampleID"].apply(
        lambda s: tax_code[s.split("|")[-1][0]]
    )

    # Parse out the name of the organism
    d["org_name"] = d["#SampleID"].apply(
        lambda s: s.split("|")[-1][3:].replace("_", " ")
    )
    del d["#SampleID"]

    # Add the sample name
    d["sample"] = sample_name
    return d

metaphlan_abund = pd.concat([
    read_metaphlan(sample_name, fp)
    for sample_name, fp in get_file_list(".metaphlan.tsv")
])

# Write out the MetaPhlAn2 results
metaphlan_abund.to_csv("${output_prefix}.metaphlan.csv", sep=",", index=None)
metaphlan_abund.to_hdf(store, "abund/metaphlan", format="table", data_columns=["sample", "rank", "org_name"], complevel=5)

# Summarize abundance by KEGG KO
def summarize_ko_depth(sample_name, sample_allele_abund):
    logging.info("Summarizing KO abundance for %s" % (sample_name))
    sample_allele_prop = sample_allele_abund.set_index("id")["prop"]
    sample_allele_nreads = sample_allele_abund.set_index("id")["nreads"]
    sample_ko = kegg_ko.loc[
        kegg_ko["allele"].isin(set(sample_allele_abund["id"].tolist()))
    ].copy()
    sample_ko["sample"] = sample_name
    sample_ko["prop"] = sample_ko["allele"].apply(sample_allele_prop.get)
    sample_ko["nreads"] = sample_ko["allele"].apply(sample_allele_nreads.get)
    return sample_ko.groupby(["sample", "KO"])[["prop", "nreads"]].sum().reset_index()


ko_abund = pd.concat([
    summarize_ko_depth(sample_name, sample_allele_abund)
    for sample_name, sample_allele_abund in allele_abund.groupby("sample")
])

# Write out the proportional abundance by KEGG KO
ko_abund.to_csv("${output_prefix}.KEGG_KO.csv", sep=",", index=None)
ko_abund.to_hdf(store, "abund/KEGG_KO", format="table", data_columns=["sample", "ko"], complevel=5)

# Function to summarize abundances by arbitrary groups (e.g. CAGs)
def summarize_alleles_by_group(group_key, prefix="/groups/"):
    assert group_key.startswith(prefix)
    group_name = group_key.replace(prefix, "")
    logging.info("Summarizing abundance by %s" % (group_name))

    # Read in the groupings
    group_df = pd.read_hdf(store, group_key)
    # The columns are 'allele', 'gene', and 'group'
    for k in ["allele", "gene", "group"]:
        assert k in group_df.columns.values
    group_df.set_index("allele", inplace=True)

    # Assign the group keys to the allele abundance data
    group_abund = allele_abund.copy()
    for k in ["gene", "group"]:
        group_abund[k] = group_abund["id"].apply(group_df[k].get)

    # Add up the alleles to make genes
    group_abund = group_abund.groupby(["sample", "gene", "group"])["prop"].sum().reset_index()
    # Average the genes to make groups
    group_abund = group_abund.groupby(["sample", "group"])["prop"].mean().reset_index()

    # Write out the abundance table
    group_abund.to_csv("${output_prefix}.%s.csv" % (group_name), sep=",", index=None)
    group_abund.to_hdf(store, "abund/%s" % (group_name), format="table", data_columns=["sample", "group"], complevel=5)


# Get the summary of read counts
readcounts = pd.read_csv("${readcounts_csv}")
assert "name" in readcounts.columns.values
readcounts["name"] = readcounts["name"].apply(str)
assert "n_reads" in readcounts.columns.values

# Calculate the number of aligned reads
aligned_reads = allele_abund.groupby("sample")["nreads"].sum()

# Add the column
readcounts["aligned_reads"] = readcounts["name"].apply(aligned_reads.get)
assert readcounts["aligned_reads"].isnull().sum() == 0, (readcounts.head(), aligned_reads.head())

# Write to HDF and CSV
readcounts.to_hdf(store, "readcounts", format="table")
readcounts.to_csv("${output_prefix}.readcounts.csv", sep=",", index=None)

    
for key in store.keys():
    if key.startswith("/groups/") and key != "/groups/KEGG_KO" and key != "/groups/NCBI_TAXID":
        summarize_alleles_by_group(key)


"""

}

if (params.humann) {
  process addHUMAnN2toHDF {
      container "quay.io/fhcrc-microbiome/python-pandas:latest"
      cpus 16
      memory "32 GB"
      publishDir "${params.output_folder}"

      input:
      file humann_genefamilies_csv
      file humann_pathabundance_csv
      file humann_pathcoverage_csv
      file output_hdf

      output:
      file "${output_hdf}"

      afterScript "rm *"

"""
#!/usr/bin/env python3
import gzip
import json
import logging
import os
import pandas as pd

# Set up logging
logFormatter = logging.Formatter(
    '%(asctime)s %(levelname)-8s [addHUMAnN2toHDF] %(message)s'
)
rootLogger = logging.getLogger()
rootLogger.setLevel(logging.INFO)

# Write logs to STDOUT
consoleHandler = logging.StreamHandler()
consoleHandler.setFormatter(logFormatter)
rootLogger.addHandler(consoleHandler)

# Open a connection to the output HDF5
store = pd.HDFStore("${output_hdf}", mode="a")

for fp, key in [
    ("${humann_genefamilies_csv}", "/abund/humann_genefamilies"),
    ("${humann_pathabundance_csv}", "/abund/humann_pathabundance"),
    ("${humann_pathcoverage_csv}", "/abund/humann_pathcoverage")
]:
    df = pd.read_csv(fp, sep=",")
    df.to_hdf(store, key, complevel=5)

store.close()
"""
  }
}