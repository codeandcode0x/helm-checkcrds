#!/usr/bin/env sh

trap "exit 1" TERM
TOP_PID=$$

KUBECTL_ARGS=""
WAIT_TIME="${WAIT_TIME:-2}" # seconds
DEBUG="${DEBUG:-0}"
TREAT_ERRORS_AS_READY=0

usage() {
cat <<EOF
Checkcrd in Helm to check k8s crd whether it's working.
Usage:
  helm checkcrd [OPTIONS]
Options:
  -c, --crd      k8s crd type ( support: pod,configmap,crd,pv,pvc,secret )
  -n, --name     k8s crd name
EOF
exit
}

# Job or set of pods is considered ready if all of the are ready
# example output with 3 pods, where 2 are not ready would be: "false false"
get_pod_state() {
    get_pod_state_name="$1"
    get_pod_state_flags="$2"
    get_pod_state_output1=$(kubectl get pods "$get_pod_state_name" $get_pod_state_flags $KUBECTL_ARGS -o go-template='
{{- define "checkStatus" -}}
  {{- $rootStatus := .status }}
  {{- $hasReadyStatus := false }}
  {{- range .status.conditions -}}
    {{- if eq .type "Ready" -}}
      {{- $hasReadyStatus = true }}
      {{- if eq .status "False" -}}
        {{- if .reason -}}
          {{- if ne .reason "PodCompleted" -}}
            {{ .status }}
            {{- range $rootStatus.containerStatuses -}}
              {{- if .state.terminated.reason -}}
              :{{ .state.terminated.reason }}
              {{- end -}}
            {{- end -}}
          {{- end -}}
        {{- else -}}
          {{ .status }}
        {{- end -}}
      {{- end -}}
    {{- end -}}
  {{- else -}}
    {{- printf "No resources found.\n" -}}
  {{- end -}}
  {{- if ne $hasReadyStatus true -}}
    {{- printf "False" -}}
  {{- end -}}
{{- end -}}

{{- if .items -}}
    {{- range .items -}}
      {{ template "checkStatus" . }}
    {{- end -}}
{{- else -}}
    {{ template "checkStatus" . }}
{{- end -}}' 2>&1)
    if [ $? -ne 0 ]; then
        if expr match "$get_pod_state_output1" '\(.*not found$\)' 1>/dev/null ; then
            echo "No pods found, waiting for them to be created..." >&2
            echo "$get_pod_state_output1" >&2
        else
            echo "$get_pod_state_output1" >&2
            kill -s TERM $TOP_PID
        fi
    elif [ $DEBUG -ge 2 ]; then
        echo "$get_pod_state_output1" >&2
    fi
    if [ $TREAT_ERRORS_AS_READY -eq 1 ]; then
        get_pod_state_output1=$(printf "%s" "$get_pod_state_output1" | sed 's/False:Error//g' )
        if [ $DEBUG -ge 1 ]; then
            echo "$get_pod_state_output1" >&2
        fi
    fi
    get_pod_state_output2=$(printf "%s" "$get_pod_state_output1" | xargs )
    if [ $DEBUG -ge 1 ]; then
        echo "$get_pod_state_output2" >&2
    fi
    echo "$get_pod_state_output2"
}

# Service or set of service is considered ready if all of the pods matched my service selector are considered ready
# example output with 2 services each matching a single pod would be: "falsefalse"
get_service_state() {
    get_service_state_name="$1"
    get_service_state_selectors=$(kubectl get service "$get_service_state_name" $KUBECTL_ARGS -ojson | jq -cr 'if . | has("items") then .items[] else . end | [ .spec.selector | to_entries[] | "\(.key)=\(.value)" ] | join(",") ' 2>&1)
    if [ $? -ne 0 ]; then
        echo "$get_service_state_selectors" >&2
        kill -s TERM $TOP_PID
    elif [ $DEBUG -ge 2 ]; then
        echo "$get_service_state_selectors" >&2
    fi
    get_service_state_states=""
    if [ "$get_service_state_selectors" = "" ] ; then
        echo "No services found, waiting for them to be created..." >&2
        get_service_state_states="false" # have to return that something is not ready, as empty implies everything is ready
    else
        for get_service_state_selector in $get_service_state_selectors ; do
            get_service_state_selector=$(echo "$get_service_state_selector" | tr ',' ' ')
            get_service_state_state=$(get_pod_state -l"$get_service_state_selectors")
            get_service_state_states="${get_service_state_states}${get_service_state_state}" ;
        done
    fi
    echo "$get_service_state_states"
}

# Job or set of jobs is considered ready if all of them succeeded at least once
# example output with 2 still running jobs would be "0 0"
# this function considers the line:
# Pods Statuses:	0 Running / 1 Succeeded / 0 Failed
# in a 'kubectl describe' job output.
get_job_state() {
    get_job_state_name="$1"
    get_job_state_output=$(kubectl describe jobs "$get_job_state_name" $KUBECTL_ARGS 2>&1)
    if [ $? -ne 0 ]; then
        echo "$get_job_state_output" >&2
        kill -s TERM $TOP_PID
    elif [ $DEBUG -ge 2 ]; then
        echo "$get_job_state_output" >&2
    fi
    if [[ "$get_job_state_output" == "" || "$get_job_state_output" == *"No resources found"* ]]; then
        echo "!: No jobs found!" >&2
        kill -s TERM $TOP_PID
    fi
    get_job_state_output1=$(printf "%s" "$get_job_state_output" | sed -nr 's#.*:[[:blank:]]+([[:digit:]]+) [[:alpha:]]+ / ([[:digit:]]+) [[:alpha:]]+ / ([[:digit:]]+) [[:alpha:]]+.*#\1:\2:\3#p' 2>&1)
    if [ $? -ne 0 ]; then
        echo "$get_job_state_output" >&2
        echo "$get_job_state_output1" >&2
        kill -s TERM $TOP_PID
    elif [ $DEBUG -ge 2 ]; then
        echo "$get_job_state_output1" >&2
    fi

    # Extract number of <running>:<succeeded>:<failed>
    get_job_state_output1=$(printf "%s" "$get_job_state_output" | sed -nr 's#.*:[[:blank:]]+([[:digit:]]+) [[:alpha:]]+ / ([[:digit:]]+) [[:alpha:]]+ / ([[:digit:]]+) [[:alpha:]]+.*#\1:\2:\3#p' 2>&1)
    if [ $DEBUG -ge 1 ]; then
        echo "$get_job_state_output1" >&2
    fi
    
    # Map triplets of <running>:<succeeded>:<failed> to not ready (emit 1) state
    if [ $TREAT_ERRORS_AS_READY -eq 0 ]; then
        # Two conditions: 
        #   - pods are distributed between all 3 states with at least 1 pod running - then emit 1
        #   - or more then 1 pod have failed and some are completed - also emit 1
        sed_reg='-e s/^[1-9][[:digit:]]*:[[:digit:]]+:[[:digit:]]+$/1/p -e s/^0:[[:digit:]]+:[1-9][[:digit:]]*$/1/p'
    else
        # When allowing for failed jobs
        #   - pods are distributed between all 3 states with at least 1 pod running- then emit 1
        #   - all other options include all pods Completed or Failed - which are fine
        sed_reg='-e s/^[1-9][[:digit:]]*:[[:digit:]]+:[[:digit:]]+$/1/p'
    fi
    
    get_job_state_output2=$(printf "%s" "$get_job_state_output1" | sed -nr $sed_reg 2>&1)
    if [ $DEBUG -ge 1 ]; then
        echo "$get_job_state_output2" >&2
    fi

    get_job_state_output3=$(printf "%s" "$get_job_state_output2" | xargs )
    if [ $DEBUG -ge 1 ]; then
        echo "$get_job_state_output3" >&2
    fi
    echo "$get_job_state_output3"
}

# configmap check
get_configmap_state() {
    get_configmap_state_name="$1"
    get_configmap_state_output=$(kubectl get configmap "$get_configmap_state_name" $KUBECTL_ARGS 2>&1)
    # if [ $? -ne 0 ]; then
    #     echo "$get_configmap_state_output" >&2
    #     kill -s TERM $TOP_PID
    # elif [ $DEBUG -ge 2 ]; then
    #     echo "$get_configmap_state_output" >&2
    # fi

    if [[ "$get_configmap_state_output" == "" || "$get_configmap_state_output" == *"No resources found"* ]]; then
        echo "!: No configmap $get_configmap_state_name found!"
        # kill -s TERM $TOP_PID
    fi

    if [[ "$get_configmap_state_output" == *"not found"*  ]]; then
        echo "crd $get_configmap_state_name no found"
        # kill -s TERM $TOP_PID
    fi
}

# secret check
get_secret_state() {
    get_secret_state_name="$1"
    get_secret_state_output=$(kubectl get secret "$get_secret_state_name" $KUBECTL_ARGS 2>&1)
    # if [ $? -ne 0 ]; then
    #     echo "$get_secret_state_output" >&2
    #     kill -s TERM $TOP_PID
    # elif [ $DEBUG -ge 2 ]; then
    #     echo "$get_secret_state_output" >&2
    # fi

    if [[ "$get_secret_state_output" == "" || "$get_secret_state_output" == *"No resources found"* ]]; then
        echo "!: No secret $get_secret_state_name found!"
        # kill -s TERM $TOP_PID
    fi

    if [[ "$get_secret_state_output" == *"not found"*  ]]; then
        echo "crd $get_secret_state_name no found"
        # kill -s TERM $TOP_PID
    fi
}

# crd check
get_crd_state() {
    get_crd_state_name="$1"
    get_crd_state_output=$(kubectl get crd "$get_crd_state_name" $KUBECTL_ARGS 2>&1)

    if [[ "$get_crd_state_output" == "" || "$get_crd_state_output" == *"No resources found"* ]]; then
        echo "!: No CRD $get_crd_state_name found!"
    fi

    if [[ "$get_crd_state_output" == *"not found"*  ]]; then
       echo "crd $get_crd_state_name no found"
    fi
}

# pv check
get_pv_state() {
    get_pv_state_name="$1"
    get_pv_state_output=$(kubectl get pv "$get_pv_state_name" $KUBECTL_ARGS 2>&1)

    if [[ "$get_pv_state_output" == "" || "$get_pv_state_output" == *"No resources found"* ]]; then
        echo "!: No pv $get_pv_state_name found!"
    fi

    if [[ "$get_pv_state_output" == *"not found"*  ]]; then
       echo "pv $get_pv_state_name no found"
    fi
}

# pvc check
get_pvc_state() {
    get_pvc_state_name="$1"
    get_pvc_state_output=$(kubectl get pvc "$get_pvc_state_name" $KUBECTL_ARGS 2>&1)

    if [[ "$get_pvc_state_output" == "" || "$get_pvc_state_output" == *"No resources found"* ]]; then
        echo "!: No pvc $get_pvc_state_name found!"
    fi

    if [[ "$get_pvc_state_output" == *"not found"*  ]]; then
       echo "pvc $get_pvc_state_name no found"
    fi

    if [[ "$get_pvc_state_output" == *"Bound"*  ]]; then
       echo "pvc $get_pvc_state_name Bound" >&2
    fi    
}

# wait for resource
wait_for_resource() {
    wait_for_resource_type=$1
    wait_for_resource_descriptor="$2"
    while [ -n "$(get_${wait_for_resource_type}_state "$wait_for_resource_descriptor")" ] ; do
        ok="$(get_${wait_for_resource_type}_state "$wait_for_resource_descriptor")"
        echo $ok
        print_KUBECTL_ARGS="$KUBECTL_ARGS"
        [ "$print_KUBECTL_ARGS" != "" ] && print_KUBECTL_ARGS=" $print_KUBECTL_ARGS"
        echo "Waiting for $wait_for_resource_type $wait_for_resource_descriptor${print_KUBECTL_ARGS}..."
        sleep "$WAIT_TIME"
    done
    ready "$wait_for_resource_type" "$wait_for_resource_descriptor"
}

ready() {
    print_KUBECTL_ARGS="$KUBECTL_ARGS"
    [ "$print_KUBECTL_ARGS" != "" ] && print_KUBECTL_ARGS=" $print_KUBECTL_ARGS"
    printf "[%s] %s %s%s is ready.\\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$1" "$2" "$print_KUBECTL_ARGS"
}

main() {
    if [ $# -lt 2 ]; then
        usage
    fi

    case "$1" in
        pod|service|job|crd|secret|configmap|pv|pvc)
            main_resource=$1
            shift
            ;;
        pod-we|job-we)
            main_resource=${1%-we}
            TREAT_ERRORS_AS_READY=1
            shift
            ;;
        *)
            printf 'ERROR: Unknown resource type: %s\n' "$1" >&2
            exit 1
            ;;
    esac

    main_name="$1"
    shift

    KUBECTL_ARGS="${*}"

    wait_for_resource "$main_resource" "$main_name"

    exit 0
}

CRD=
CRD_NAME=
LABEL="-l"

while [[ $# -ne 0 ]]; do
  case "$1" in
    -c|--crd) 
        CRD=$2
        ;;
    -n|--name) CRD_NAME=$2  ;;
    -*)          usage "Unrecognized command line argument $1" ;;
    *)           break;
  esac

  case "$3" in
    -c|--crd) 
        CRD=$4
        ;;
    -n|--name) 
        CRD_NAME=$4
        echo "ok0"
        if [[ $2 = "pod" ]]; then
            CRD_NAME=$LABEL$4
            echo $CRD_NAME
        fi 
        ;;
    -*)          usage "Unrecognized command line argument $3" ;;
    *)           break;
  esac

  shift
done

# main "$@"
main $CRD $CRD_NAME