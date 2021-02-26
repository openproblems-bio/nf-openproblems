#!/usr/bin/env nextflow
/*
========================================================================================
                         nf-core/openproblems
========================================================================================
 nf-core/openproblems Analysis Pipeline.
 #### Homepage / Documentation
 https://github.com/nf-core/openproblems
----------------------------------------------------------------------------------------
*/

def helpMessage() {
    // TODO nf-core: Add to this help message with new command line parameters
    log.info nfcoreHeader()
    log.info"""

    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run nf-core/openproblems --input '*_R{1,2}.fastq.gz' -profile docker

    Mandatory arguments:
      --input [file]                  Path to input data (must be surrounded with quotes)
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: conda, docker, singularity, test, awsbatch, <institute> and more

    Options:
      --genome [str]                  Name of iGenomes reference
      --single_end [bool]             Specifies that the input is single-end reads

    References                        If not specified in the configuration file or you wish to overwrite any of the references
      --fasta [file]                  Path to fasta reference

    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --publish_dir_mode [str]        Mode for publishing results in the output directory. Available: symlink, rellink, link, copy, copyNoFollow, move (Default: copy)
      --email [email]                 Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --email_on_fail [email]         Same as --email, except only send mail if the workflow is not successful
      --max_multiqc_email_size [str]  Threshold size for MultiQC report to be attached in notification email. If file generated by pipeline exceeds the threshold, it will not be attached (Default: 25MB)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic

    AWSBatch options:
      --awsqueue [str]                The AWSBatch JobQueue that needs to be set when running on AWSBatch
      --awsregion [str]               The AWS Region for your AWS Batch job to run on
      --awscli [str]                  Path to the AWS CLI tool
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

/*
 * SET UP CONFIGURATION VARIABLES
 */

// // Check if genome exists in the config file
// if (params.genomes && params.genome && !params.genomes.containsKey(params.genome)) {
//     exit 1, "The provided genome '${params.genome}' is not available in the iGenomes file. Currently the available genomes are ${params.genomes.keySet().join(", ")}"
// }

// // TODO nf-core: Add any reference files that are needed
// // Configurable reference genomes
// //
// // NOTE - THIS IS NOT USED IN THIS PIPELINE, EXAMPLE ONLY
// // If you want to use the channel below in a process, define the following:
// //   input:
// //   file fasta from ch_fasta
// //
// params.fasta = params.genome ? params.genomes[ params.genome ].fasta ?: false : false
// if (params.fasta) { ch_fasta = file(params.fasta, checkIfExists: true) }

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Check AWS batch settings
if (workflow.profile.contains('awsbatch')) {
    // AWSBatch sanity checking
    if (!params.awsqueue || !params.awsregion) exit 1, "Specify correct --awsqueue and --awsregion parameters on AWSBatch!"
    // Check outdir paths to be S3 buckets if running on AWSBatch
    // related: https://github.com/nextflow-io/nextflow/issues/813
    if (!params.outdir.startsWith('s3:')) exit 1, "Outdir not on S3 - specify S3 Bucket to run on AWSBatch!"
    // Prevent trace files to be stored on S3 since S3 does not support rolling files.
    if (params.tracedir.startsWith('s3:')) exit 1, "Specify a local tracedir or run without trace! S3 cannot be used for tracefiles."
}

// Specifies whether to use mini test data
use_mini_test_data = params.use_mini_test_data

// Stage config files
ch_multiqc_config = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config, checkIfExists: true) : Channel.empty()
ch_output_docs = file("$projectDir/docs/output.md", checkIfExists: true)
ch_output_docs_images = file("$projectDir/docs/images/", checkIfExists: true)

// /*
//  * Create a channel for input read files
//  */
// if (params.input_paths) {
//     if (params.single_end) {
//         Channel
//             .from(params.input_paths)
//             .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true) ] ] }
//             .ifEmpty { exit 1, "params.input_paths was empty - no input files supplied" }
//             .into { ch_read_files_fastqc; ch_read_files_trimming }
//     } else {
//         Channel
//             .from(params.input_paths)
//             .map { row -> [ row[0], [ file(row[1][0], checkIfExists: true), file(row[1][1], checkIfExists: true) ] ] }
//             .ifEmpty { exit 1, "params.input_paths was empty - no input files supplied" }
//             .into { ch_read_files_fastqc; ch_read_files_trimming }
//     }
// } else {
//     Channel
//         .fromFilePairs(params.input, size: params.single_end ? 1 : 2)
//         .ifEmpty { exit 1, "Cannot find any reads matching: ${params.input}\nNB: Path needs to be enclosed in quotes!\nIf this is single-end data, please specify --single_end on the command line." }
//         .into { ch_read_files_fastqc; ch_read_files_trimming }
// }

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Input']            = params.input
summary['Fasta Ref']        = params.fasta
summary['Data Type']        = params.single_end ? 'Single-End' : 'Paired-End'
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('awsbatch')) {
    summary['AWS Region']   = params.awsregion
    summary['AWS Queue']    = params.awsqueue
    summary['AWS CLI']      = params.awscli
}
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')
if (params.email || params.email_on_fail) {
    summary['E-mail Address']    = params.email
    summary['E-mail on failure'] = params.email_on_fail
    summary['MultiQC maxsize']   = params.max_multiqc_email_size
}
log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

Channel.from(summary.collect{ [it.key, it.value] })
    .map { k,v -> "<dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }
    .reduce { a, b -> return [a, b].join("\n            ") }
    .map { x -> """
    id: 'nf-core-openproblems-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'nf-core/openproblems Workflow Summary'
    section_href: 'https://github.com/nf-core/openproblems'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
            $x
        </dl>
    """.stripIndent() }
    .set { ch_workflow_summary }

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode,
        saveAs: { filename ->
                      if (filename.indexOf(".csv") > 0) filename
                      else null
                }

    output:
    file 'software_versions_mqc.yaml' into ch_software_versions_yaml
    file "software_versions.csv"

    script:
    // TODO nf-core: Get all tools to print their version number here
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    python --version > v_python.txt 2>&1
    scrape_software_versions.py &> software_versions_mqc.yaml
    """
}

/*
 * STEP 1 - List tasks
 */
process list_tasks {
    label 'process_low'
    publishDir "${params.outdir}/list", mode: params.publish_dir_mode

    output:
    file(tasks) into ch_list_tasks

    script:
    tasks = "tasks.txt"
    """
    openproblems-cli tasks > ${tasks}
    """
}

// define list cartesian product
class CartesianCategory {
    static Iterable multiply(Iterable a, Iterable b) {
        assert [a,b].every { it != null }
        def (m,n) = [a.size(),b.size()]
        (0..<(m*n)).inject([]) { prod, i -> prod << [a[i.intdiv(n)], b[i%n]].flatten() }
    }
}
Iterable.metaClass.mixin CartesianCategory

ch_list_tasks
    .splitText() { line -> line.replaceAll("\\n", "") }
    .into { ch_collate_task_names_datasets;
            ch_collate_dataset_task_names_methods;
            ch_collate_dataset_task_names_metrics }

/*
 * STEP 2 - List datasets per task
 */
process list_datasets {
    tag "${task_name}"
    label 'process_low'
    publishDir "${params.outdir}/list/datasets", mode: params.publish_dir_mode

    input:
    val(task_name) from ch_collate_task_names_datasets

    output:
    set file(datasets), val(task_name) into ch_list_datasets

    script:
    datasets = "${task_name}.datasets.txt"
    """
    openproblems-cli list --datasets --task ${task_name} > ${datasets}
    """
}

ch_list_datasets
    .dump( tag: 'ch_list_datasets' )
    .map { it -> tuple(
        it[0].splitText()*.replaceAll("\n", ""),
        it[1]
     ) }
    .transpose()
    .dump( tag: 'ch_task_dataset_pairs' )
    .set { ch_task_dataset_pairs }

/*
 * STEP 2.5 - Fetch dataset images
 */
process dataset_images {
    tag "${task_name}_${dataset_name}"
    label 'process_low'

    input:
    set val(dataset_name), val(task_name) from ch_task_dataset_pairs

    output:
    set val(dataset_name), val(task_name), stdout into ch_task_dataset_image_triplets

    script:
    """
    openproblems-cli image --datasets --task ${task_name} ${dataset_name} | tr -d "\n"
    """
}

/*
 * STEP 3 - Load datasets
 */
process load_dataset {
    tag "${dataset_name}_${task_name}"
    container "singlecellopenproblems/${image}"
    label 'process_batch'

    publishDir "${params.outdir}/results/datasets/", mode: params.publish_dir_mode

    input:
    set val(dataset_name), val(task_name), val(image) from ch_task_dataset_image_triplets

    output:
    set val(task_name), val(dataset_name), file(dataset_h5ad) into ch_loaded_datasets, ch_loaded_datasets_to_print

    script:
    dataset_h5ad = "${task_name}.${dataset_name}.dataset.h5ad"
    test_flag = '--test' if use_mini_test_data else ''
    """
    openproblems-cli load ${test_flag} --task ${task_name} --output ${dataset_h5ad} ${dataset_name}
    """
}

ch_loaded_datasets_to_print
    .dump( tag: 'ch_loaded_datasets' )


/*
 * STEP 4 - List methods per task
 */
process list_methods {
    tag "${task_name}"
    label 'process_low'
    publishDir "${params.outdir}/list/methods", mode: params.publish_dir_mode

    input:
    val(task_name) from ch_collate_dataset_task_names_methods

    output:
    set val(task_name), file(methods) into ch_list_methods_for_task_method

    script:
    methods = "${task_name}.methods.txt"
    """
    openproblems-cli list --methods --task ${task_name} > ${methods}
    """
}

ch_list_methods_for_task_method
    .dump( tag: 'ch_list_methods_for_task' )
    .map { it -> tuple(
        it[0],
        it[1].splitText()*.replaceAll("\n", "")
        )}
    .dump( tag: 'ch_tasks_methods' )
    .transpose()
    .dump( tag: 'ch_tasks_methods_transpose' )
    .combine( ch_loaded_datasets, by: 0)
    .dump( tag: 'ch_tasks_methods_map_collate_combine_datasets' )
    // .dump( tag: 'ch_task_method_quads' )
    .set { ch_task_method_quads }


/*
 * STEP 4.5 - Fetch method images
 */
process method_images {
    tag "${task_name}_${dataset_name}"
    label 'process_low'

    input:
    set val(task_name), val(method_name), val(dataset_name), file(dataset_h5ad) from ch_task_method_quads

    output:
    set val(task_name), val(method_name), val(dataset_name), file(dataset_h5ad), stdout into ch_task_method_quints

    script:
    """
    openproblems-cli image --methods --task ${task_name} ${method_name} | tr -d "\n"
    """
}

/*
* STEP 5 - Run methods
*/
process run_method {
    tag "${method_name}_${dataset_name}_${task_name}"
    container "singlecellopenproblems/${image}"
    label 'process_batch'
    publishDir "${params.outdir}/results/methods/", mode: params.publish_dir_mode

    input:
    set val(task_name), val(method_name), val(dataset_name), file(dataset_h5ad), val(image) from ch_task_method_quints

    output:
    set val(task_name), val(dataset_name), val(method_name), file(method_h5ad) into ch_ran_methods

    script:
    method_h5ad = "${task_name}.${dataset_name}.${method_name}.method.h5ad"
    """
    openproblems-cli run --task ${task_name} --input ${dataset_h5ad} --output ${method_h5ad} ${method_name}
    """
}


/*
 * STEP 6 - List metrics per task
 */
process list_metrics {
    tag "${task_name}"
    label 'process_low'
    publishDir "${params.outdir}/list/metrics", mode: params.publish_dir_mode

    input:
    val(task_name) from ch_collate_dataset_task_names_metrics

    output:
    set val(task_name), file(metrics) into ch_list_metrics

    script:
    metrics = "${task_name}.metrics.txt"
    """
    openproblems-cli list --metrics --task ${task_name} > ${metrics}
    """
}

ch_list_metrics
    .dump( tag: 'ch_list_metrics' )
    .map { it -> tuple(
        it[0],
        it[1].splitText()*.replaceAll("\n", "")
    ) }
    .dump( tag: 'ch_tasks_metrics' )
    .transpose()
    .dump( tag: 'ch_tasks_metrics_transpose' )
    .combine(ch_ran_methods, by:0)
    .dump( tag: 'ch_tasks_metrics_map_collate_combine_datasets' )
    .set { ch_task_metric_quints }

/*
 * STEP 6.5 - Fetch metric images
 */
process metric_images {
    tag "${task_name}_${dataset_name}"
    label 'process_low'

    input:
    set val(task_name), val(metric_name), val(dataset_name), val(method_name), file(dataset_h5ad) from ch_task_metric_quints

    output:
    set val(task_name), val(metric_name), val(dataset_name), val(method_name), file(dataset_h5ad), stdout into ch_task_metric_sextuples

    script:
    """
    openproblems-cli image --metrics --task ${task_name} ${metric_name} | tr -d "\n"
    """
}

/*
* STEP 7 - Run metric
*/
process run_metric {
    tag "${metric_name}_${method_name}_${dataset_name}_${task_name}"
    container "singlecellopenproblems/${image}"
    label 'process_batch'
    publishDir "${params.outdir}/results/metrics", mode: params.publish_dir_mode

    input:
    set val(task_name), val(metric_name), val(dataset_name), val(method_name), file(method_h5ad), val(image) from ch_task_metric_sextuples

    output:
    set val(task_name), val(dataset_name), val(method_name), val(metric_name), file(metric_txt) into ch_evaluated_metrics

    script:
    metric_txt = "${task_name}_${dataset_name}_${method_name}_${metric_name}.metric.txt"
    """
    openproblems-cli evaluate --task ${task_name} --input ${method_h5ad} ${metric_name} > ${metric_txt}
    """
}



/*
 * Completion e-mail notification
 */
workflow.onComplete {

    // Set up the e-mail variables
    def subject = "[nf-core/openproblems] Successful: $workflow.runName"
    if (!workflow.success) {
        subject = "[nf-core/openproblems] FAILED: $workflow.runName"
    }
    def email_fields = [:]
    email_fields['version'] = workflow.manifest.version
    email_fields['runName'] = custom_runName ?: workflow.runName
    email_fields['success'] = workflow.success
    email_fields['dateComplete'] = workflow.complete
    email_fields['duration'] = workflow.duration
    email_fields['exitStatus'] = workflow.exitStatus
    email_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    email_fields['errorReport'] = (workflow.errorReport ?: 'None')
    email_fields['commandLine'] = workflow.commandLine
    email_fields['projectDir'] = workflow.projectDir
    email_fields['summary'] = summary
    email_fields['summary']['Date Started'] = workflow.start
    email_fields['summary']['Date Completed'] = workflow.complete
    email_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    email_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) email_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) email_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) email_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    email_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    email_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    email_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // TODO nf-core: If not using MultiQC, strip out this code (including params.max_multiqc_email_size)
    // On success try attach the multiqc report
    def mqc_report = null
    try {
        if (workflow.success) {
            mqc_report = ch_multiqc_report.getVal()
            if (mqc_report.getClass() == ArrayList) {
                log.warn "[nf-core/openproblems] Found multiple reports from process 'multiqc', will use only one"
                mqc_report = mqc_report[0]
            }
        }
    } catch (all) {
        log.warn "[nf-core/openproblems] Could not attach MultiQC report to summary email"
    }

    // Check if we are only sending emails on failure
    email_address = params.email
    if (!params.email && params.email_on_fail && !workflow.success) {
        email_address = params.email_on_fail
    }

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$projectDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(email_fields)
    def email_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$projectDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(email_fields)
    def email_html = html_template.toString()

    // Render the sendmail template
    def smail_fields = [ email: email_address, subject: subject, email_txt: email_txt, email_html: email_html, projectDir: "$projectDir", mqcFile: mqc_report, mqcMaxSize: params.max_multiqc_email_size.toBytes() ]
    def sf = new File("$projectDir/assets/sendmail_template.txt")
    def sendmail_template = engine.createTemplate(sf).make(smail_fields)
    def sendmail_html = sendmail_template.toString()

    // Send the HTML e-mail
    if (email_address) {
        try {
            if (params.plaintext_email) { throw GroovyException('Send plaintext e-mail, not HTML') }
            // Try to send HTML e-mail using sendmail
            [ 'sendmail', '-t' ].execute() << sendmail_html
            log.info "[nf-core/openproblems] Sent summary e-mail to $email_address (sendmail)"
        } catch (all) {
            // Catch failures and try with plaintext
            def mail_cmd = [ 'mail', '-s', subject, '--content-type=text/html', email_address ]
            if ( mqc_report.size() <= params.max_multiqc_email_size.toBytes() ) {
              mail_cmd += [ '-A', mqc_report ]
            }
            mail_cmd.execute() << email_html
            log.info "[nf-core/openproblems] Sent summary e-mail to $email_address (mail)"
        }
    }

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << email_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << email_txt }

    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_red = params.monochrome_logs ? '' : "\033[0;31m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";

    if (workflow.stats.ignoredCount > 0 && workflow.success) {
        log.info "-${c_purple}Warning, pipeline completed, but with errored process(es) ${c_reset}-"
        log.info "-${c_red}Number of ignored errored process(es) : ${workflow.stats.ignoredCount} ${c_reset}-"
        log.info "-${c_green}Number of successfully ran process(es) : ${workflow.stats.succeedCount} ${c_reset}-"
    }

    if (workflow.success) {
        log.info "-${c_purple}[nf-core/openproblems]${c_green} Pipeline completed successfully${c_reset}-"
    } else {
        checkHostname()
        log.info "-${c_purple}[nf-core/openproblems]${c_red} Pipeline completed with errors${c_reset}-"
    }

}


def nfcoreHeader() {
    // Log colors ANSI codes
    c_black = params.monochrome_logs ? '' : "\033[0;30m";
    c_blue = params.monochrome_logs ? '' : "\033[0;34m";
    c_cyan = params.monochrome_logs ? '' : "\033[0;36m";
    c_dim = params.monochrome_logs ? '' : "\033[2m";
    c_green = params.monochrome_logs ? '' : "\033[0;32m";
    c_purple = params.monochrome_logs ? '' : "\033[0;35m";
    c_reset = params.monochrome_logs ? '' : "\033[0m";
    c_white = params.monochrome_logs ? '' : "\033[0;37m";
    c_yellow = params.monochrome_logs ? '' : "\033[0;33m";

    return """    -${c_dim}--------------------------------------------------${c_reset}-
                                            ${c_green},--.${c_black}/${c_green},-.${c_reset}
    ${c_blue}        ___     __   __   __   ___     ${c_green}/,-._.--~\'${c_reset}
    ${c_blue}  |\\ | |__  __ /  ` /  \\ |__) |__         ${c_yellow}}  {${c_reset}
    ${c_blue}  | \\| |       \\__, \\__/ |  \\ |___     ${c_green}\\`-._,-`-,${c_reset}
                                            ${c_green}`._,._,\'${c_reset}
    ${c_purple}  nf-core/openproblems v${workflow.manifest.version}${c_reset}
    -${c_dim}--------------------------------------------------${c_reset}-
    """.stripIndent()
}

def checkHostname() {
    def c_reset = params.monochrome_logs ? '' : "\033[0m"
    def c_white = params.monochrome_logs ? '' : "\033[0;37m"
    def c_red = params.monochrome_logs ? '' : "\033[1;91m"
    def c_yellow_bold = params.monochrome_logs ? '' : "\033[1;93m"
    if (params.hostnames) {
        def hostname = "hostname".execute().text.trim()
        params.hostnames.each { prof, hnames ->
            hnames.each { hname ->
                if (hostname.contains(hname) && !workflow.profile.contains(prof)) {
                    log.error "====================================================\n" +
                            "  ${c_red}WARNING!${c_reset} You are running with `-profile $workflow.profile`\n" +
                            "  but your machine hostname is ${c_white}'$hostname'${c_reset}\n" +
                            "  ${c_yellow_bold}It's highly recommended that you use `-profile $prof${c_reset}`\n" +
                            "============================================================"
                }
            }
        }
    }
}
