#'
#' FLAMES variant calling
#'
#' Candidate SNVs identified with filtering by coverage threshold,
#' and allele frequency range.
#'
#' Takes the \code{SingleCellExperiment} object from \code{sc_long_pipeline} and the cell barcodes as \code{barcode}.
#' Alternatively, input can also be provided as \code{out_dir}, \code{genome_fa}, \code{annot}, \code{barcode}.
#'
#' @param sce The \code{SingleCellExperiment} object from \code{sc_long_pipeline}
#'
#' @param genome_fa (Optional) Reference genome FASTA file. Use this parameter is if you do not wish \code{sc_mutation} to use the
#' reference genome FASTA file from the \code{sce}'s metadata.
#'
#' @param bam_short (Optional) short read alignment BAM file. If provided, it is used to filter the variations. Variations in long-read data with enough short read coverage but no alternative allele will not be reported.
#'
#' @param out_dir (Optional) Output folder of sc_long_pipeline. Output files from this function will also be saved here.
#' Use this parameter if you do not have the \code{SingleCellExperiment} object.
#'
#' @param barcode_tsv TSV file for cell barcodes
#'
#' @param annot (Optional) The file path to gene annotation file in gff3 format. If provided as \code{FALSE} then the \code{isoform_annotated.gff3} from \code{sc_longread_pipeline} will be used, if not provided then the path in the \code{SingleCellExperiment} object will be used.
#'
#' @param known_positions (Optional) A list of known positions, with by chromosome name followed by the position, e.g. ('chr1', 123, 'chr1', 124, 'chrX', 567). These locations will not be filtered and its allele frequencies will be reported.
#'
#' @param min_cov The coverage threshold for filtering candidate SNVs. Positions with reads less then this number will not be considered.
#'
#' @param report_pct The allele frequency range for filtering candidate SNVs. Positions with less or higher allele frequency will not be reported. The default is 0.10-0.90
#'
#' @return
#' a \code{data.frame} containing the following columns:
#' \itemize{
#'  \item{chr}{ - the chromosome where the mutation is located}
#'  \item{position}
#'  \item{REF}{ - the reference allele}
#'  \item{ALT}{ - the alternative allele}
#'  \item{REF_frequency}{ - reference allele frequency}
#'  \item{REF_frequency_in_short_reads}{ - reference allele frequency in short reads (-1 when short reads not provided)}
#'  \item{hypergeom_test_p_value}
#'  \item{sequence_entropy}
#'  \item{INDEL_frequency}
#'  \item{adj_p}{ - the adjusted p-value (by Benjamini–Hochberg correction)}
#' }
#' The table is sorted by decreasing adjusted P value.
#'
#' files saved to out_dir/mutation:
#' \itemize{
#'      \item{ref_cnt.csv.gz}
#'      \item{alt_cnt.csv.gz}
#'      \item{allele_stat.csv.gz}
#'      \item{freq_summary.csv}
#' }
#'
#' @importFrom utils write.csv
#' @importFrom S4Vectors head
#' @importFrom basilisk basiliskRun
#'
#' @examples
#' outdir <- tempfile()
#' dir.create(outdir)
#' bc_allow <- file.path(outdir, "bc_allow.tsv")
#' genome_fa <- file.path(outdir, "rps24.fa")
#' R.utils::gunzip(filename = system.file("extdata/bc_allow.tsv.gz", package = "FLAMES"), destname = bc_allow, remove = FALSE)
#' R.utils::gunzip(filename = system.file("extdata/rps24.fa.gz", package = "FLAMES"), destname = genome_fa, remove = FALSE)
#'
#' \dontrun{
#' if (is.character(locate_minimap2_dir())) {
#'     sce <- FLAMES::sc_long_pipeline(
#'         genome_fa = genome_fa,
#'         fastq = system.file("extdata/fastq", package = "FLAMES"),
#'         annotation = system.file("extdata/rps24.gtf.gz", package = "FLAMES"),
#'         outdir = outdir,
#'         reference_csv = bc_allow
#'     )
#'     sc_mutations(sce, barcode_tsv = file.path(outdir, "bc_allow.tsv"), min_cov = 2, report_pct = c(0, 1))
#' }
#' }
#' @export
sc_mutations <- function(sce, barcode_tsv, bam_short, out_dir, genome_fa, annot, known_positions = NULL, min_cov = 100, report_pct = c(0.10, 0.90)) {
    cat("\n\n\n\n\n\n")
    if (!missing(sce)) {
        if (missing(annot)) {
            annot <- sce@metadata$OutputFiles$AnnotationFile
        }
        if (missing(genome_fa)) {
            genome_fa <- sce@metadata$OutputFiles$genome_fa
        }
        if (missing(out_dir)) {
            out_dir <- sce@metadata$OutputFiles$outdir
        }
    }

    python_path <- system.file("python", package = "FLAMES")
    basiliskRun(env = flames_env, fun = function(fa, bam, dir, barcode, gff, positions, mincov, reportpct) {
        convert <- reticulate::import_from_path("sc_mutations", python_path)
        convert$sc_mutations(fa, bam, dir, barcode, gff, positions, mincov, reportpct)
    }, fa = genome_fa, bam = ifelse(missing("bam_short"), FALSE, bam_short), dir = out_dir, barcode = barcode_tsv, gff = annot, positions = known_positions, mincov = min_cov, reportpct = report_pct)

    allele_stat_csv <- file.path(out_dir, "mutation", "allele_stat.csv.gz")
    table <- read.csv(allele_stat_csv)
    table$adj_p <- stats::p.adjust(table$hypergeom_test_p_value)
    table <- table[order(table$adj_p), ]
    rownames(table) <- NULL
    write.csv(table, file = gzfile(allele_stat_csv), row.names = FALSE)
    print.data.frame(head(table, n = 20L))
    table
}

extract_nt <- function(ref, seqname, pos) {
  mapply(function(seqname, pos) {
    as.character(ref[[seqname]][pos])
  }, seqname, pos)
}

homopolymer_pct <- function(ref, seqname, pos, include_alt, n = 5) {
  mapply(function(seqname, pos, include_alt) {
    if (pos == 1 | pos == length(ref[[seqname]])) {
      return(TRUE) # variant at the ends should not be considered
    }

    start <- max(1, pos - n)
    end <- min(length(ref[[seqname]]), pos + n)
    if (include_alt) {
      ref[[seqname]][start:end] |>
        as.character() |>
        strsplit("") |>
        unlist() |>
        table() |>
        as.data.frame() |>
        dplyr::mutate(pct = Freq / sum(Freq)) |>
        dplyr::pull(pct) |>
        max()
    } else {
      # exclude the position itself
      ref[[seqname]][c(start:(pos - 1), (pos + 1):end)] |>
        as.character() |>
        strsplit("") |>
        unlist() |>
        table() |>
        as.data.frame() |>
        dplyr::mutate(pct = Freq / sum(Freq)) |>
        dplyr::pull(pct) |>
        max()
    }
   }, seqname, pos, include_alt)
}

find_variants <- function(bam_path, reference, gene_grange) {
  # read bam file
  pile <- Rsamtools::pileup(bam_path,
    pileupParam = Rsamtools::PileupParam(
      max_depth = .Machine$integer.max - 1, min_base_quality = 0, min_mapq = 0,
      min_nucleotide_depth = 5, min_minor_allele_depth = 0,
      distinguish_strands = FALSE, distinguish_nucleotides = TRUE,
      ignore_query_Ns = TRUE, include_deletions = TRUE, include_insertions = TRUE,
      left_bins = NULL, query_bins = NULL, cycle_bins = NULL
    ),
    scanBamParam = Rsamtools::ScanBamParam(which = gene_grange)
  )

  pile$ref <- extract_nt(reference, pile$seqnames, pile$pos) # add reference allele

  mutations <- pile |>
    dplyr::filter(as.character(nucleotide) != ref)

  # add variant frequency
  mutations$sum <- mapply(function(i, j) { # seqname, pos
    pile |>
      dplyr::filter(seqnames == i, pos == j) |>
      dplyr::pull(count) |>
      sum()
  }, mutations$seqnames, mutations$pos)
  mutations <- mutations |>
    # + counted twice for insertions (one for the current position and one for insertion)
    # still get freq > 1 (probably) due to ignore_query_Ns and min depths
    dplyr::mutate(freq = ifelse(nucleotide == "+" & count * 2 < sum, count * 2 / sum, count / sum))

  if (nrow(mutations) == 0) {
    return(mutations)
  } else {
    mutations$gene <- gene_grange$gene_name
    return(mutations)
  }
}
