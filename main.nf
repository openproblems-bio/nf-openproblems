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
      -profile [str]                  Configuration profile to use. Can use multiple (comma separated)
                                      Available: aws, test

    Options:


    Other options:
      --outdir [file]                 The output directory where the results will be saved
      --publish_dir_mode [str]        Mode for publishing results in the output directory. Available: symlink, rellink, link, copy, copyNoFollow, move (Default: copy)
      --branch [str]									Short name (<80 characters) of the git branch (used to define the S3 subdirectory)
      -name [str]                     Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic
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

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if (!(workflow.runName ==~ /[a-z]+_[a-z]+/)) {
    custom_runName = workflow.runName
}

// Specifies whether to use mini test data
if (params.use_test_data) {
    params.test_flag = '--test'
} else {
    params.test_flag = ''
}

// Header log info
log.info nfcoreHeader()
def summary = [:]
if (workflow.revision) summary['Pipeline Release'] = workflow.revision
summary['Run Name']         = custom_runName ?: workflow.runName
// TODO nf-core: Report custom parameters here
summary['Test']            = params.use_test_data
summary['Max Resources']    = "$params.max_memory memory, $params.max_cpus cpus, $params.max_time time per job"
if (workflow.containerEngine) summary['Container'] = "$workflow.containerEngine - $workflow.container"
summary['Output dir']       = params.outdir
summary['Launch dir']       = workflow.launchDir
summary['Working dir']      = workflow.workDir
summary['Script dir']       = workflow.projectDir
summary['User']             = workflow.userName
if (workflow.profile.contains('aws')) {
    if (params.branch == false) exit 1, "If running on AWS, please specify --branch"
}

summary['Container host']   = params.container_host
summary['Config Profile'] = workflow.profile
if (params.config_profile_description) summary['Config Profile Description'] = params.config_profile_description
if (params.config_profile_contact)     summary['Config Profile Contact']     = params.config_profile_contact
if (params.config_profile_url)         summary['Config Profile URL']         = params.config_profile_url
summary['Config Files'] = workflow.configFiles.join(', ')

log.info summary.collect { k,v -> "${k.padRight(18)}: $v" }.join("\n")
log.info "-\033[2m--------------------------------------------------\033[0m-"

// Check the hostnames against configured profiles
checkHostname()

/*
 * Parse software version numbers
 */
process get_software_versions {
    publishDir "${params.outdir}/pipeline_info", mode: params.publish_dir_mode
    label 'process_low'

    output:
    file "software_versions.csv"

    script:
    """
    echo $workflow.manifest.version > v_pipeline.txt
    echo $workflow.nextflow.version > v_nextflow.txt
    python3 --version > v_python.txt 2>&1
    openproblems-cli --version > v_openproblems.txt
    bash --version | head -n 1 > v_bash.txt
    javac -version || echo "" | head -n 1 > v_java.txt
    scrape_software_versions.py
    """
}

/*
 * STEP 1 - List tasks
 */
process list_tasks {
    label 'process_low'
    // publishDir "${params.outdir}/list", mode: params.publish_dir_mode

    output:
    file(tasks) into ch_list_tasks

    script:
    tasks = "tasks.txt"
    """
    openproblems-cli tasks > ${tasks}
    """
}

ch_list_tasks
    .splitText() { line -> line.replaceAll("\\n", "") }
    .set { ch_task_names_for_list_datasets }

/*
 * STEP 2 - List datasets per task
 */
process list_datasets {
    tag "${task_name}"
    label 'process_low'
    // publishDir "${params.outdir}/list/datasets", mode: params.publish_dir_mode

    input:
    val(task_name) from ch_task_names_for_list_datasets

    output:
    set val(task_name), file(datasets) into ch_task_list_datasets

    script:
    datasets = "${task_name}.datasets.txt"
    """
    openproblems-cli list --datasets --task ${task_name} > ${datasets}
    """
}

ch_task_list_datasets
    .tap { ch_list_datasets }
    .map { it -> it[0] }
    .set { ch_task_names_for_list_methods }

ch_list_datasets
    .map { it -> tuple(
        it[0],
        it[1].splitText()*.replaceAll("\n", "")
     ) }
    .transpose()
    .set { ch_task_dataset_pairs }

/*
 * STEP 2.5 - Fetch dataset images
 */
process dataset_images {
    tag "${task_name}:${dataset_name}"
    label 'process_low'

    input:
    set val(task_name), val(dataset_name) from ch_task_dataset_pairs

    output:
    set val(task_name), val(dataset_name), env(IMAGE), env(HASH) into ch_task_dataset_image_hash

    script:
    """
    IMAGE=`openproblems-cli image --datasets --task ${task_name} ${dataset_name} | tr -d "\n"`
    HASH=`openproblems-cli hash --datasets --task ${task_name} ${dataset_name}`
    """
}

/*
 * STEP 3 - Load datasets
 */
process load_dataset {
    tag "${task_name}:${dataset_name}:${image}"
    container "${params.container_host}${image}"
    label 'process_batch'

    // publishDir "${params.outdir}/results/datasets/", mode: params.publish_dir_mode

    input:
    set val(task_name), val(dataset_name), val(image), val(hash) from ch_task_dataset_image_hash

    output:
    set val(task_name), val(dataset_name), file(dataset_h5ad) into ch_loaded_datasets, ch_loaded_datasets_to_print

    script:
    dataset_h5ad = "${task_name}.${dataset_name}.dataset.h5ad"
    """
    openproblems-cli load ${params.test_flag} --task ${task_name} --output ${dataset_h5ad} ${dataset_name}
    """
}


/*
 * STEP 4 - List methods per task
 */
process list_methods {
    tag "${task_name}"
    label 'process_low'
    // publishDir "${params.outdir}/list/methods", mode: params.publish_dir_mode

    input:
    val(task_name) from ch_task_names_for_list_methods

    output:
    set val(task_name), file(methods) into ch_task_list_methods

    script:
    methods = "${task_name}.methods.txt"
    """
    openproblems-cli list --methods --task ${task_name} > ${methods}
    """
}

ch_task_list_methods
    .tap { ch_list_methods }
    .map { it -> it[0] }
    .set { ch_task_names_for_list_metrics }

ch_list_methods
    .map { it -> tuple(
        it[0],
        it[1].splitText()*.replaceAll("\n", "")
        )}
    .transpose()
    .set { ch_task_method_pairs }


/*
 * STEP 4.5 - Fetch method images
 */
process method_images {
    tag "${task_name}:${method_name}"
    label 'process_low'

    input:
    set val(task_name), val(method_name) from ch_task_method_pairs

    output:
    set val(task_name), val(method_name), env(IMAGE), env(HASH) into ch_task_method_image_hash

    script:
    """
    IMAGE=`openproblems-cli image --methods --task ${task_name} ${method_name} | tr -d "\n"`
    HASH=`openproblems-cli hash --methods --task ${task_name} ${method_name}`
    """
}

ch_task_method_image_hash
    .combine( ch_loaded_datasets, by: 0)
    .set { ch_dataset_methods }

/*
* STEP 5 - Run methods
*/
process run_method {
    tag "${task_name}:${method_name}-${dataset_name}:${image}"
    container "${params.container_host}${image}"
    label 'process_batch'
    // publishDir "${params.outdir}/results/methods/", mode: params.publish_dir_mode

    input:
    set val(task_name), val(method_name), val(image), val(hash), val(dataset_name), file(dataset_h5ad) from ch_dataset_methods

    output:
    set val(task_name), val(dataset_name), val(method_name), file(method_h5ad), file(method_version) into ch_ran_methods

    script:
    method_h5ad = "${task_name}.${dataset_name}.${method_name}.method.h5ad"
    method_version = "${task_name}.${dataset_name}.${method_name}.method.txt"
    """
    if [ `pip freeze | grep annoy` ]; then sudo pip install --force annoy; fi
    openproblems-cli run ${params.test_flag} --task ${task_name} --input ${dataset_h5ad} --output ${method_h5ad} ${method_name} > ${method_version}
    """
}

ch_ran_methods
    .tap { ch_ran_methods_to_code_versions }
    .set { ch_ran_methods_to_metrics }

/*
 * STEP 5.5 - Publish code versions
 */

process publish_code_versions {
    tag "${task_name}:${method_name}-${dataset_name}"
    label 'process_low'
    publishDir "${params.outdir}/method_versions", mode: params.publish_dir_mode

    input:
    set val(task_name), val(dataset_name), val(method_name), file(method_h5ad), file(method_version_in) from ch_ran_methods_to_code_versions

    output:
    set val(task_name), val(dataset_name), val(method_name), file(method_h5ad), file(method_version_out) into ch_published_code_versions

    script:
    method_version_out = "${task_name}.${dataset_name}.${method_name}.method.txt"
    """
    cat ${method_version_in} > ${method_version_out}
    """
}

/*
 * STEP 6 - List metrics per task
 */
process list_metrics {
    tag "${task_name}"
    label 'process_low'
    // publishDir "${params.outdir}/list/metrics", mode: params.publish_dir_mode

    input:
    val(task_name) from ch_task_names_for_list_metrics

    output:
    set val(task_name), file(metrics) into ch_list_metrics

    script:
    metrics = "${task_name}.metrics.txt"
    """
    openproblems-cli list --metrics --task ${task_name} > ${metrics}
    """
}

ch_list_metrics
    .map { it -> tuple(
        it[0],
        it[1].splitText()*.replaceAll("\n", "")
    ) }
    .transpose()
    .set { ch_task_metric_pairs }

/*
 * STEP 6.5 - Fetch metric images
 */
process metric_images {
    tag "${task_name}:${metric_name}"
    label 'process_low'

    input:
    set val(task_name), val(metric_name) from ch_task_metric_pairs

    output:
    set val(task_name), val(metric_name), env(IMAGE), env(HASH) into ch_task_metric_image_hash

    script:
    """
    IMAGE=`openproblems-cli image --metrics --task ${task_name} ${metric_name} | tr -d "\n"`
    HASH=`openproblems-cli hash --metrics --task ${task_name} ${metric_name}`
    """
}

ch_task_metric_image_hash
    .combine(ch_ran_methods_to_metrics, by:0)
    .set { ch_dataset_method_metrics }


/*
* STEP 7 - Run metric
*/
process run_metric {
    tag "${task_name}:${metric_name}-${method_name}-${dataset_name}:${image}"
    container "${params.container_host}${image}"
    label 'process_batch'
    publishDir "${params.outdir}/metrics", mode: params.publish_dir_mode

    input:
    set val(task_name), val(metric_name), val(image), val(hash), val(dataset_name), val(method_name), file(method_h5ad), file(method_version) from ch_dataset_method_metrics

    output:
    set val(task_name), val(dataset_name), val(method_name), val(metric_name), file(metric_txt) into ch_evaluated_metrics

    script:
    metric_txt = "${task_name}.${dataset_name}.${method_name}.${metric_name}.metric.txt"
    """
    openproblems-cli evaluate --task ${task_name} --input ${method_h5ad} ${metric_name} > ${metric_txt}
    """
}


/*
 * Completion e-mail notification
 */
workflow.onComplete {

    def report_fields = [:]
    report_fields['version'] = workflow.manifest.version
    report_fields['runName'] = custom_runName ?: workflow.runName
    report_fields['success'] = workflow.success
    report_fields['dateComplete'] = workflow.complete
    report_fields['duration'] = workflow.duration
    report_fields['exitStatus'] = workflow.exitStatus
    report_fields['errorMessage'] = (workflow.errorMessage ?: 'None')
    report_fields['errorReport'] = (workflow.errorReport ?: 'None')
    report_fields['commandLine'] = workflow.commandLine
    report_fields['projectDir'] = workflow.projectDir
    report_fields['summary'] = summary
    report_fields['summary']['Date Started'] = workflow.start
    report_fields['summary']['Date Completed'] = workflow.complete
    report_fields['summary']['Pipeline script file path'] = workflow.scriptFile
    report_fields['summary']['Pipeline script hash ID'] = workflow.scriptId
    if (workflow.repository) report_fields['summary']['Pipeline repository Git URL'] = workflow.repository
    if (workflow.commitId) report_fields['summary']['Pipeline repository Git Commit'] = workflow.commitId
    if (workflow.revision) report_fields['summary']['Pipeline Git branch/tag'] = workflow.revision
    report_fields['summary']['Nextflow Version'] = workflow.nextflow.version
    report_fields['summary']['Nextflow Build'] = workflow.nextflow.build
    report_fields['summary']['Nextflow Compile Timestamp'] = workflow.nextflow.timestamp

    // Render the TXT template
    def engine = new groovy.text.GStringTemplateEngine()
    def tf = new File("$projectDir/assets/email_template.txt")
    def txt_template = engine.createTemplate(tf).make(report_fields)
    def report_txt = txt_template.toString()

    // Render the HTML template
    def hf = new File("$projectDir/assets/email_template.html")
    def html_template = engine.createTemplate(hf).make(report_fields)
    def report_html = html_template.toString()

    // Write summary e-mail HTML to a file
    def output_d = new File("${params.outdir}/pipeline_info/")
    if (!output_d.exists()) {
        output_d.mkdirs()
    }
    def output_hf = new File(output_d, "pipeline_report.html")
    output_hf.withWriter { w -> w << report_html }
    def output_tf = new File(output_d, "pipeline_report.txt")
    output_tf.withWriter { w -> w << report_txt }

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
				if (params.branch == "main" && !params.use_test_data) {
						// sync output to s3
						def proc = "aws s3 cp --quiet --recursive ${params.outdir} s3://openproblems-nextflow/cwd_main/".execute()
						def s3_stdout = new StringBuilder()
						def s3_stderr = new StringBuilder()
						proc.waitForProcessOutput(s3_stdout, s3_stderr);

						// fetch github PAT
						def github_pat = nextflow.secret.SecretsLoader.instance.load().getSecret("github_pat").value

						// send webhook to github
						def post = new URL("https://api.github.com/repos/openproblems-bio/openproblems/dispatches").openConnection();
						def data = '{"event_type": "benchmark_complete"}';
						post.setRequestMethod("POST");
						post.setRequestProperty("Accept", "application/vnd.github.v3+json");
						post.setRequestProperty("Authorization", "Bearer ${github_pat}");
						post.setDoOutput(true);
						post.getOutputStream().write(data.getBytes("UTF-8"));
						def postRC = post.getResponseCode();
						if (postRC.equals(204)) {
								log.info "GitHub webhook posted successfully"
						} else {
								log.info "GitHub webhook failed (${postRC})"
						}

						// sync log to s3
						def proc_log = "aws s3 cp --quiet ${projectDir}/.nextflow.log s3://openproblems-nextflow/cwd_main/".execute()
						def s3_stdout_log = new StringBuilder()
						def s3_stderr_log = new StringBuilder()
						proc_log.waitForProcessOutput(s3_stdout_log, s3_stderr_log);
				} else {
					log.info "Not running full benchmark on main, didn't send GitHub webhook"
				}
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
