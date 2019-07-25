#!/usr/bin/env nextflow

/*
  Geneshot preprocessing submodule:
    Steps:
    1) (if index is available): barcodecop to verify demultiplexing
    2) cutadapt to remove adapters.
    3) remove human reads via
      3A) downloading the cached human genome index
      3B) aligning against the human genome and extracting unpaired reads
*/

// Default values for boolean flags
// If these are not set by the user, then they will be set to the values below
// This is useful for the if/then control syntax below
params.index = false
params.help = false
params.adapter_F = "CTGTCTCTTATACACATCT"
params.adapter_R = "CTGTCTCTTATACACATCT"
params.hg_index = 'ftp://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids/GCA_000001405.15_GRCh38_no_alt_plus_hs38d1_analysis_set.fna.bwa_index.tar.gz'
params.min_hg_align_score = 30

params.output_folder = '.'


// Function which prints help message text
def helpMessage() {
    log.info"""
    Usage:

    nextflow run geneshot-pp.nf <ARGUMENTS>
    
    Required Arguments:
      --manifest         CSV file listing samples to preprocess (see below)
      --output_folder    Folder to place outputs (default invocation dir)

    Options:
      --index            Index reads are provided (default: false)
      --hg_index         URL for human genome index, defaults to current HG

    Batchfile:
      The manifest is a CSV with a header indicating which samples correspond to which files.
      The file must contain a column `name`. 
      Reads are specified by two columns, `fastq1` and `fastq2`.
      If index reads are provided, the column titles should be 'index1' and 'index2'

    """.stripIndent()
}

// Show help message if the user specifies the --help flag at runtime
if (params.help){
    // Invoke the function above which prints the help message
    helpMessage()
    // Exit out and do not run anything else
    exit 0
}

if (params.index) {
    Channel.from(file(params.manifest))
        .splitCsv(header: true, sep: ",")
        .map { sample ->
        [sample.name, file(sample.fastq1), file(sample.fastq2), file(sample.index1), file(sample.index2)]}
        .set{ input_ch }
    // implement barcodecop here
}
else {
    Channel.from(file(params.manifest))
        .splitCsv(header: true, sep: ",")
        .map { sample ->
        [sample.name, file(sample.fastq1), file(sample.fastq2)]}
        .set{ demupltiplexed_ch }
}
// Step 1: barcodecop

// Step 2
process cutadapt {
  container "golob/cutadapt:1.18__bcw.0.3.0_al38"
  cpus 1
  memory "4 GB"
  errorStrategy "retry"

  //publishDir "${params.output_folder}/noadapt/"

  input:
  set sample_name, file(fastq1), file(fastq2) from demupltiplexed_ch
  
  output:
  set sample_name, file("${fastq1}.noadapt.R1.fastq.gz"), file("${fastq2}.noadapt.R2.fastq.gz"), file("${fastq1}.cutadapt.log") into noadapt_ch

  """
  cutadapt \
  -j ${task.cpus} \
   -a ${params.adapter_F} -A ${params.adapter_R} \
  -o ${fastq1}.noadapt.R1.fastq.gz -p ${fastq2}.noadapt.R2.fastq.gz \
  ${fastq1} ${fastq2} > ${fastq1}.cutadapt.log
  """
}

// Step 3A.
process download_hg_index {
  container "golob/bwa:0.7.17__bcw.0.3.0C"
  cpus 1
  memory "1 GB"
  errorStrategy "retry"

  output:
    file 'hg_index.tar.gz' into hg_index_tgz
  
  """
  wget ${params.hg_index} -O hg_index.tar.gz
  """
}

// Step 3B.
process remove_human {
  container "golob/bwa:0.7.17__bcw.0.3.0C"
  cpus 2
  memory "4 GB"
  errorStrategy "retry"
  publishDir "${params.output_folder}/nohuman/"
  
  input:
    file hg_index_tgz from hg_index_tgz
    set sample_name, file(fastq1), file(fastq2), file(cutadapt_log) from noadapt_ch
  
  output:
    set sample_name, file("${fastq1}.nohuman.R1.fastq.gz"), file("${fastq2}.nohuman.R2.fastq.gz"), file("${fastq1}.nohuman.log") into nohuman_ch

  afterScript "rm -rf hg_index/*"

  """
  bwa_index_prefix=\$(tar -ztvf ${hg_index_tgz} | head -1 | sed \'s/.* //\' | sed \'s/.amb//\') && \
  echo BWA index file prefix is \${bwa_index_prefix} | tee -a ${fastq1}.nohuman.log && \
  echo Extracting BWA index | tee -a ${fastq1}.nohuman.log && \
  mkdir -p hg_index/ && \
  tar xzvf ${hg_index_tgz} -C hg_index/ | tee -a ${fastq1}.nohuman.log && \
  echo Files in index directory: | tee -a ${fastq1}.nohuman.log && \
  ls -l -h hg_index | tee -a ${fastq1}.nohuman.log && \
  echo Running BWA | tee -a ${fastq1}.nohuman.log && \
  bwa mem -t ${task.cpus} \
  -T ${params.min_hg_align_score} \
  -o alignment.sam \
  hg_index/\$bwa_index_prefix \
  ${fastq1} ${fastq2} \
  | tee -a ${fastq1}.nohuman.log && \
  echo Extracting Unaligned Pairs | tee -a ${fastq1}.nohuman.log && \
  samtools fastq alignment.sam -f 12 \
  -1 ${fastq1}.nohuman.R1.fastq.gz -2 ${fastq2}.nohuman.R2.fastq.gz \
  | tee -a ${fastq1}.nohuman.log && \
  echo Done | tee -a ${fastq1}.nohuman.log
  """
}