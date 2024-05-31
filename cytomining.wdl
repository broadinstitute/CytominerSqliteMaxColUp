version 1.0

import "utils/cellprofiler_distributed_utils.wdl" as util

task profiling {
  # A file that pipelines typically implicitly assume they have access to.

  input {
    String cellprofiler_analysis_directory_gsurl
    String plate_id
    String aggregation_operation = "mean"
    File plate_map_file
    String? annotate_join_on = "['Metadata_well_position', 'Metadata_Well']"
    String? normalize_method = "mad_robustize"
    Float? mad_robustize_epsilon = 0.0
    String output_directory_gsurl
    Int? hardware_memory_GB = 30
    Int? hardware_preemptible_tries = 2
  }
  String cellprofiler_analysis_directory = sub(cellprofiler_analysis_directory_gsurl, "/+$", "")
  String output_directory = sub(output_directory_gsurl, "/+$", "")
  String agg_filename = plate_id + "_aggregated_" + aggregation_operation + ".csv"
  String aug_filename = plate_id + "_annotated_" + aggregation_operation + ".csv"
  String norm_filename = plate_id + "_normalized_" + aggregation_operation + ".csv"

  command <<<

    set -e

    monitor_script.sh > monitoring.log &
    echo "Localizing data from ~{cellprofiler_analysis_directory}"
    start=`date +%s`
    echo $start
    mkdir -p /cromwell_root/data
    gsutil -mq rsync -r -x ".*\.png$" ~{cellprofiler_analysis_directory} /cromwell_root/data
    wget -O ingest_config.ini https://raw.githubusercontent.com/broadinstitute/cytominer_scripts/master/ingest_config.ini
    wget -O indices.sql https://raw.githubusercontent.com/broadinstitute/cytominer_scripts/master/indices.sql
    end=`date +%s`
    echo $end
    runtime=$((end-start))
    echo "Total runtime for file localization:"
    echo $runtime
    echo " "
    echo "ls -lh /cromwell_root/data"
    ls -lh /cromwell_root/data
    echo " "
    echo "ls -lh ."
    ls -lh .
    echo " "

    echo "===================================="
    echo "= Processing CSV files ="
    echo "===================================="

    find /cromwell_root/data -name "*.csv" | while read filename; do
      echo "Processing $filename"
      num_columns=$(head -1 "$filename" | sed 's/[^,]//g' | wc -c)
      if (( num_columns > 2000 )); then
        awk -v OFS=',' '{
          if (NR == 1) {
            for (i=1; i<=2000; i++) {
              printf("%s%s", $i, (i<2000 ? OFS : ""))
            }
            printf("%s\n", "AdditionalColumns")
          } else {
            for (i=1; i<=2000; i++) {
              printf("%s%s", $i, (i<2000 ? OFS : ""))
            }
            additional_columns = ""
            for (i=2001; i<=NF; i++) {
              additional_columns = (additional_columns == "" ? $i : additional_columns "|" $i)
            }
            printf("%s\n", additional_columns)
          }
        }' "$filename" > "${filename}.tmp" && mv "${filename}.tmp" "$filename"
      fi
    done



    echo "===================================="
    echo "= Running cytominer-databse ingest ="
    echo "===================================="
    start=`date +%s`
    echo $start


    echo "cytominer-database ingest /cromwell_root/data sqlite:///~{plate_id}.sqlite -c ingest_config.ini"
    cytominer-database ingest /cromwell_root/data sqlite:///~{plate_id}.sqlite -c ingest_config.ini
    sqlite3 ~{plate_id}.sqlite < indices.sql
    echo "Copying sqlite file to ~{output_directory}"
    gsutil cp ~{plate_id}.sqlite ~{output_directory}/
    end=`date +%s`
    echo $end
    runtime=$((end-start))
    echo "Total runtime for cytominer-database ingest:"
    echo $runtime
    echo "===================================="

    echo " "
    echo "Running pycytominer aggregation step"
    python <<CODE

    import time
    import pandas as pd
    from pycytominer.cyto_utils.cells import SingleCells
    from pycytominer.cyto_utils import infer_cp_features
    from pycytominer import normalize, annotate
    print("Creating Single Cell class... ")
    start = time.time()
    sc = SingleCells('sqlite:///~{plate_id}.sqlite',aggregation_operation='~{aggregation_operation}')
    print("Time: " + str(time.time() - start))
    print("Aggregating profiles... ")
    start = time.time()
    aggregated_df = sc.aggregate_profiles()
    aggregated_df.to_csv('~{agg_filename}', index=False)
    print("Time: " + str(time.time() - start))
    print("Annotating with metadata... ")
    start = time.time()
    plate_map_df = pd.read_csv('~{plate_map_file}', sep="\t")
    annotated_df = annotate(aggregated_df, plate_map_df, join_on = ~{annotate_join_on})
    annotated_df.to_csv('~{aug_filename}',index=False)
    print("Time: " + str(time.time() - start))
    print("Normalizing to plate.. ")
    start = time.time()
    normalize(annotated_df, method='~{normalize_method}', mad_robustize_epsilon = ~{mad_robustize_epsilon}).to_csv('~{norm_filename}',index=False)
    print("Time: " + str(time.time() - start))

    CODE

    echo " "
    echo "Completed pycytominer aggregation annotation & normalization"
    echo "ls -lh ."
    ls -lh .
    echo "Copying csv outputs to ~{output_directory}"
    gsutil cp ~{agg_filename} ~{output_directory}/
    gsutil cp ~{aug_filename} ~{output_directory}/
    gsutil cp ~{norm_filename} ~{output_directory}/
    gsutil cp monitoring.log ~{output_directory}/
    echo "Done."

  >>>

  output {
    File monitoring_log = "monitoring.log"
    File log = stdout()
  }
  runtime {
    docker: "us.gcr.io/broad-dsde-methods/cytomining:0.0.4"
    disks: "local-disk 500 HDD"
    memory: "${hardware_memory_GB}G"
    bootDiskSizeGb: 10
    cpu: 4
    maxRetries: 2
    preemptible: hardware_preemptible_tries
  }

}
workflow cytomining {
  input {
    String cellprofiler_analysis_directory_gsurl
    String plate_id
    File plate_map_file
    String output_directory_gsurl
  }
  call util.gcloud_is_bucket_writable as permission_check {
    input:
      gsurls=[output_directory_gsurl],
  }
  Boolean is_bucket_writable = permission_check.is_bucket_writable
  if (is_bucket_writable) {
    call profiling {
      input:
        cellprofiler_analysis_directory_gsurl = cellprofiler_analysis_directory_gsurl,
        plate_id = plate_id,
        plate_map_file = plate_map_file,
        output_directory_gsurl = output_directory_gsurl,
    }
  }
  output {
    File monitoring_log = select_first([profiling.monitoring_log, permission_check.log])
    File log = select_first([profiling.log, permission_check.log])
  }
}
