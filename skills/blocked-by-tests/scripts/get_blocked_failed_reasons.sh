#!/usr/bin/env bash
#
# get_blocked_failed_reasons.sh
#
# Query dashboard.qam.suse.de API for blocked submissions matching specified
# group names and states, fetch the corresponding failed openQA jobs, and display
# the exact failure reason (message inside the openQA step failure box).
#
# Example target:
#   https://openqa.suse.de/tests/25025671#step/SLFO_update_install/23
#   -> Shows the message box from step 23 of SLFO_update_install.
#
# Default groups: "core,func"
# Default states: "failed,stopped"
# Supports --show-reason, --full-reason, --reasons-only, --modules-only, and --retry.
#

set -eo pipefail

readonly DEFAULT_DASHBOARD_URL="https://dashboard.qam.suse.de"
readonly DEFAULT_OPENQA_URL="https://openqa.suse.de"
readonly DEFAULT_GROUP_NAMES="core,func"
readonly DEFAULT_STATES="failed,stopped"
readonly DEFAULT_MODULE_FORMAT="path"

dashboard_url="${DEFAULT_DASHBOARD_URL}"
openqa_url="${DEFAULT_OPENQA_URL}"
group_names="${DEFAULT_GROUP_NAMES}"
states="${DEFAULT_STATES}"
incident_filter=""
single_job=""
insecure_flag="-k"
output_format="pretty"
module_format="${DEFAULT_MODULE_FORMAT}"
show_reason=1
full_reason=0
use_color=1
curl_retries=3
curl_retry_delay=2
parallel_jobs=8
retry_jobs=0
dry_run=0
auto_yes=0

if [[ ! -t 1 ]]; then
    use_color=0
fi

# Color helpers
_c_bold()   { [[ $use_color -eq 1 ]] && printf "\033[1m%s\033[0m" "$1" || printf "%s" "$1"; }
_c_green()  { [[ $use_color -eq 1 ]] && printf "\033[32m%s\033[0m" "$1" || printf "%s" "$1"; }
_c_red()    { [[ $use_color -eq 1 ]] && printf "\033[31m%s\033[0m" "$1" || printf "%s" "$1"; }
_c_yellow() { [[ $use_color -eq 1 ]] && printf "\033[33m%s\033[0m" "$1" || printf "%s" "$1"; }
_c_cyan()   { [[ $use_color -eq 1 ]] && printf "\033[36m%s\033[0m" "$1" || printf "%s" "$1"; }
_c_dim()    { [[ $use_color -eq 1 ]] && printf "\033[2m%s\033[0m" "$1" || printf "%s" "$1"; }
_c_magenta(){ [[ $use_color -eq 1 ]] && printf "\033[35m%s\033[0m" "$1" || printf "%s" "$1"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [retry]

Queries QAM Dashboard (/app/api/blocked) and openQA API to find failed jobs and
extract the failing Perl test modules and failure reason message from the step box.

Reason & Module Options:
  -R, --show-reason         Display the failure reason message box for failing modules (enabled by default)
      --no-reason           Hide the failure reason message in pretty mode
      --full-reason         Display the entire failure box content (including stack trace)
      --reasons-only        Output ONLY the failure reason messages (one per line)
  -m, --modules-only        Output ONLY the failing Perl test module(s) (one per line)
      --module-format <FMT> Format for modules:
                              'path' : tests/<category>/<module>.pm [default]
                              'pm'   : <module>.pm
                              'name' : <module>
  -j, --job <ID/URL>        Directly inspect a single openQA job ID or job URL (skips dashboard)

Standard Output Options:
      --ids-only            Print only openQA job IDs (one per line)
      --links-only          Print only openQA job URLs (one per line)
      --json                Print raw aggregated JSON output with reason details
      --no-color            Disable terminal color output

Filtering & Configuration Options:
  -u, --url <URL>           Full dashboard URL with query params
                            (e.g. "https://dashboard.qam.suse.de/blocked?group_names=core%2Cfunc&states=failed%2Cstopped")
  -g, --group-names <LIST>  Comma-separated group names regex filter (default: "core,func")
  -s, --states <LIST>       Comma-separated states filter: failed,stopped,waiting,passed,accepted (default: "failed,stopped")
  -i, --incident <ID/NAME>  Filter by incident number or package name
  -d, --dashboard <URL>     Dashboard base URL (default: "https://dashboard.qam.suse.de")
  -o, --openqa <URL>        openQA base URL (default: "https://openqa.suse.de")
  -k, --insecure            Allow insecure SSL connections for curl (default: enabled)
      --secure              Enforce strict SSL certificate validation

Job Retry / Restart Options:
  -r, --retry, --restart    Restart / retry the matching failed/stopped openQA jobs
      --dry-run             Show which jobs would be retried without executing restart
  -y, --yes                 Skip confirmation prompt when retrying jobs

Help:
  -h, --help                Show this help message and exit

Examples:
  $(basename "$0") -i 25025671
  $(basename "$0") -i 9372 --full-reason
  $(basename "$0") --reasons-only
  $(basename "$0") -m
  $(basename "$0") --retry --dry-run
EOF
}

# Parse URL query string
parse_url() {
    local full_url="$1"
    
    local base="${full_url%%\?*}"
    if [[ "$base" =~ ^https?://[^/]+ ]]; then
        dashboard_url="${BASH_REMATCH[0]}"
    fi

    local query="${full_url#*\?}"
    if [[ "$query" != "$full_url" ]]; then
        local IFS='&'
        for param in $query; do
            local key="${param%%=*}"
            local val="${param#*=}"
            val="${val//%2C/,}"
            val="${val//%2c/,}"
            val="${val//+/ }"
            case "$key" in
                group_names) group_names="$val" ;;
                states) states="$val" ;;
                incident|submission) incident_filter="$val" ;;
            esac
        done
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -R|--show-reason|--reason)
            show_reason=1
            shift
            ;;
        --no-reason)
            show_reason=0
            shift
            ;;
        --full-reason)
            show_reason=1
            full_reason=1
            shift
            ;;
        --reasons-only|--reason-only)
            output_format="reasons"
            show_reason=1
            shift
            ;;
        -m|--modules-only|--failed-modules-only)
            output_format="modules"
            shift
            ;;
        --module-format)
            case "$2" in
                path|pm|name) module_format="$2" ;;
                *) echo "Error: Invalid --module-format '$2'. Choose 'path', 'pm', or 'name'." >&2; exit 1 ;;
            esac
            shift 2
            ;;
        -j|--job)
            single_job="$2"
            shift 2
            ;;
        -u|--url)
            parse_url "$2"
            shift 2
            ;;
        -g|--group-names)
            group_names="$2"
            shift 2
            ;;
        -s|--states)
            states="$2"
            shift 2
            ;;
        -i|--incident|--submission)
            incident_filter="$2"
            shift 2
            ;;
        -d|--dashboard)
            dashboard_url="$2"
            shift 2
            ;;
        -o|--openqa)
            openqa_url="$2"
            shift 2
            ;;
        -r|--retry|--restart|retry|.retry)
            retry_jobs=1
            shift
            ;;
        --dry-run)
            dry_run=1
            shift
            ;;
        -y|--yes)
            auto_yes=1
            shift
            ;;
        -k|--insecure)
            insecure_flag="-k"
            shift
            ;;
        --secure)
            insecure_flag=""
            shift
            ;;
        --ids-only)
            output_format="ids"
            shift
            ;;
        --links-only)
            output_format="links"
            shift
            ;;
        --json)
            output_format="json"
            shift
            ;;
        --no-color)
            use_color=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            # If user directly passed an openQA job URL or number
            if [[ "$1" =~ /tests/([0-9]+) ]]; then
                single_job="${BASH_REMATCH[1]}"
                shift
            elif [[ "$1" =~ ^[0-9]+$ ]] && [[ -z "$incident_filter" ]]; then
                # Large number (> 1000000) is almost certainly an openQA job id rather than an incident number
                if [[ "$1" -gt 1000000 ]]; then
                    single_job="$1"
                else
                    incident_filter="$1"
                fi
                shift
            else
                echo "Unknown argument: $1" >&2
                usage
                exit 1
            fi
            ;;
    esac
done

# Ensure dependencies
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' is not installed." >&2
        exit 1
    fi
done

# Wrapper for curl with automatic retries
api_curl() {
    curl -s --retry "$curl_retries" --retry-delay "$curl_retry_delay" --retry-connrefused $insecure_flag "$@"
}

# Format Perl module string according to requested format
format_perl_module() {
    local mod_name="$1"
    local mod_category="$2"
    case "$module_format" in
        pm)
            echo "${mod_name}.pm"
            ;;
        name)
            echo "${mod_name}"
            ;;
        path|*)
            if [[ -n "$mod_category" ]]; then
                echo "tests/${mod_category}/${mod_name}.pm"
            else
                echo "tests/${mod_name}.pm"
            fi
            ;;
    esac
}

# Direct single-job inspection mode (bypasses dashboard query)
if [[ -n "$single_job" ]]; then
    if [[ "$single_job" =~ /tests/([0-9]+) ]]; then
        single_job="${BASH_REMATCH[1]}"
    fi

    job_url="${openqa_url%/}/tests/${single_job}"
    details_json=$(api_curl "${openqa_url%/}/api/v1/jobs/${single_job}/details")
    if [[ -z "$details_json" ]] || ! echo "$details_json" | jq -e '.job' >/dev/null 2>&1; then
        echo "Error: Failed to retrieve details for openQA job $single_job from ${openqa_url%/}/api/v1/jobs/${single_job}/details" >&2
        exit 3
    fi

    jname=$(echo "$details_json" | jq -r '.job.name')
    jres=$(echo "$details_json" | jq -r '.job.result // "failed"')

    parsed_failures=$(echo "$details_json" | jq -c --arg base "$openqa_url" --argjson jid "$single_job" '
        [
            .job.testresults[]? |
            select(.result == "failed") |
            . as $mod |
            (
                ([ $mod.details[]? | select(.result == "fail" and ((.title // "") | test("Failed"; "i"))) ][0]) //
                ([ $mod.details[]? | select(.result == "fail") ][-1]) //
                ($mod.details[-1] // {})
            ) as $step |
            ($step.text_data // $step.title // "") as $raw_text |
            ($raw_text | split("\n") | map(select(length > 0)) | .[0] // "") as $first_line |
            {
                name: $mod.name,
                category: ($mod.category // ""),
                step_num: $step.num,
                step_url: (if $step.num != null then "\($base)/tests/\($jid)#step/\($mod.name)/\($step.num)" else "" end),
                first_line: $first_line,
                full_text: $raw_text
            }
        ] as $f_mods |
        if ($f_mods | length) > 0 then $f_mods
        else
            if (.job.reason // "") != "" then
                [
                    {
                        name: (.job.test // "job"),
                        category: "",
                        step_num: null,
                        step_url: "\($base)/tests/\($jid)",
                        first_line: .job.reason,
                        full_text: .job.reason
                    }
                ]
            else []
            end
        end
    ')

    if [[ "$output_format" == "ids" ]]; then
        echo "$single_job"
        exit 0
    elif [[ "$output_format" == "links" ]]; then
        echo "$job_url"
        exit 0
    elif [[ "$output_format" == "modules" ]]; then
        echo "$parsed_failures" | jq -r --arg fmt "$module_format" '
            .[] |
            if $fmt == "pm" then "\(.name).pm"
            elif $fmt == "name" then .name
            else (if .category != "" then "tests/\(.category)/\(.name).pm" else "tests/\(.name).pm" end)
            end
        ' | sort -u
        exit 0
    elif [[ "$output_format" == "reasons" ]]; then
        while read -r entry; do
            [[ -z "$entry" ]] && continue
            m_name=$(echo "$entry" | jq -r '.name')
            s_num=$(echo "$entry" | jq -r '.step_num // empty')
            f_line=$(echo "$entry" | jq -r '.first_line')
            full_t=$(echo "$entry" | jq -r '.full_text')

            if [[ "$full_reason" -eq 1 ]]; then
                echo "=== Job $single_job | Module: $m_name (step: ${s_num:-N/A}) ==="
                echo "$full_t"
                echo ""
            else
                if [[ -n "$s_num" ]]; then
                    printf "[%s] %s (#step/%s/%s): %s\n" "$single_job" "$m_name" "$m_name" "$s_num" "$f_line"
                else
                    printf "[%s] %s: %s\n" "$single_job" "$m_name" "$f_line"
                fi
            fi
        done < <(echo "$parsed_failures" | jq -c '.[]' 2>/dev/null || true)
        exit 0
    elif [[ "$output_format" == "json" ]]; then
        echo "$parsed_failures" | jq --argjson id "$single_job" --arg name "$jname" --arg res "$jres" --arg url "$job_url" '
            {
                id: $id,
                name: $name,
                result: $res,
                url: $url,
                failures: [
                    .[] | {
                        module: .name,
                        category: .category,
                        step_num: .step_num,
                        step_url: .step_url,
                        reason: .first_line,
                        full_reason: .full_text
                    }
                ]
            }
        '
        exit 0
    fi

    # Pretty output for single job
    printf "%s: [%s] %s (%s)\n" "$(_c_bold "Job")" "$single_job" "$jname" "$(_c_red "$jres")"
    printf "%s: %s\n" "$(_c_dim "URL")" "$(_c_dim "$job_url")"
    
    while read -r entry; do
        [[ -z "$entry" ]] && continue
        m_name=$(echo "$entry" | jq -r '.name')
        m_cat=$(echo "$entry" | jq -r '.category // empty')
        s_num=$(echo "$entry" | jq -r '.step_num // empty')
        s_url=$(echo "$entry" | jq -r '.step_url // empty')
        f_line=$(echo "$entry" | jq -r '.first_line')
        full_t=$(echo "$entry" | jq -r '.full_text')

        fmt_mod=$(format_perl_module "$m_name" "$m_cat")
        printf "\n  %s: %s\n" "$(_c_bold "Failed module")" "$(_c_red "$fmt_mod")"
        if [[ -n "$s_num" ]]; then
            printf "  %s: %s %s\n" "$(_c_bold "Failed step")" "$(_c_cyan "#step/${m_name}/${s_num}")" "$(_c_dim "(${s_url})")"
        fi

        if [[ "$full_reason" -eq 1 ]]; then
            printf "  %s:\n" "$(_c_bold "Message in box")"
            while IFS= read -r line; do
                printf "    %s\n" "$(_c_magenta "$line")"
            done <<< "$full_t"
        else
            printf "  %s: %s\n" "$(_c_bold "Reason")" "$(_c_magenta "$f_line")"
        fi
    done < <(echo "$parsed_failures" | jq -c '.[]' 2>/dev/null || true)
    exit 0
fi

# Prepare group regex for jq: "core,func" -> "(core|func)"
IFS=',' read -ra grp_arr <<< "$group_names"
grp_regex=""
for g in "${grp_arr[@]}"; do
    g_trimmed="$(echo "$g" | xargs)"
    [[ -z "$g_trimmed" ]] && continue
    if [[ -z "$grp_regex" ]]; then
        grp_regex="$g_trimmed"
    else
        grp_regex="${grp_regex}|${g_trimmed}"
    fi
done
[[ -z "$grp_regex" ]] && grp_regex=".*"

# Prepare states array for jq
IFS=',' read -ra state_arr <<< "$states"
state_json="$(printf '%s\n' "${state_arr[@]}" | xargs -n1 | jq -R . | jq -s .)"

# Fetch /app/api/blocked
api_endpoint="${dashboard_url%/}/app/api/blocked"
if [[ "$output_format" == "pretty" ]]; then
    printf "%s %s\n" "$(_c_bold "Fetching blocked submissions from:")" "$(_c_cyan "$api_endpoint")"
    printf "%s group_names='%s' (regex: '%s'), states='%s'" "$(_c_dim "Filter:")" "$group_names" "$grp_regex" "$states"
    [[ -n "$incident_filter" ]] && printf ", incident/package='%s'" "$incident_filter"
    printf "\n\n"
fi

blocked_json=$(api_curl "$api_endpoint")
if [[ -z "$blocked_json" ]] || ! echo "$blocked_json" | jq -e '.blocked' >/dev/null 2>&1; then
    echo "Error: Failed to retrieve or parse blocked submissions from $api_endpoint" >&2
    exit 2
fi

# Filter blocked targets using jq
targets_json=$(echo "$blocked_json" | jq \
    --arg grp_regex "$grp_regex" \
    --arg inc_filter "$incident_filter" \
    --argjson states "$state_json" '
    def calc_state(r):
      (r.stopped // 0) as $stopped |
      (r.passed // 0) as $passed |
      (r.waiting // 0) as $waiting |
      (r.failed // 0) as $failed |
      (r.accepted // 0) as $accepted |
      ($stopped + $passed + $waiting + $failed + $accepted) as $total |
      if $failed > 0 then "failed"
      elif $stopped > 0 then "stopped"
      elif $waiting > 0 then "waiting"
      elif $accepted > 0 then "accepted"
      elif $passed == $total and $total > 0 then "passed"
      else "other"
      end;

    [
      .blocked[] |
      .incident as $inc |
      select(
        if $inc_filter == "" then true
        else (
          ($inc.number | tostring | contains($inc_filter)) or
          ($inc.packages // [] | any(contains($inc_filter)))
        )
        end
      ) |
      (
        (.incident_results // {} | to_entries[] | .value + {source: "incident"}),
        (.update_results // {} | to_entries[] | .value + {source: "update"})
      ) |
      select(.name | test($grp_regex; "i")) |
      calc_state(.) as $st |
      select($states | index($st)) |
      {
        incident_number: $inc.number,
        incident_project: $inc.project,
        packages: ($inc.packages // []),
        source: .source,
        name: .name,
        state: $st,
        failed: (.failed // 0),
        stopped: (.stopped // 0),
        passed: (.passed // 0),
        waiting: (.waiting // 0),
        build: .linkinfo.build,
        distri: (.linkinfo.distri // "sle"),
        groupid: .linkinfo.groupid,
        flavor: .linkinfo.flavor,
        version: .linkinfo.version
      }
    ]
')

target_count=$(echo "$targets_json" | jq 'length')
if [[ "$target_count" -eq 0 ]]; then
    if [[ "$output_format" == "pretty" ]]; then
        _c_green "No blocked submissions found matching the criteria."
        printf "\n"
    elif [[ "$output_format" == "json" ]]; then
        echo "[]"
    fi
    exit 0
fi

has_state() {
    local target_state="$1"
    for s in "${state_arr[@]}"; do
        [[ "$(echo "$s" | xargs)" == "$target_state" ]] && return 0
    done
    return 1
}

# Temporary workspace for parallel job detail & failure reason fetching
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

total_jobs=0
declare -A seen_jobs=()
declare -a collected_job_ids=()

target_idx=0
while read -r target; do
    f_cnt=$(echo "$target" | jq -r '.failed')
    s_cnt=$(echo "$target" | jq -r '.stopped')
    build=$(echo "$target" | jq -r '.build')
    distri=$(echo "$target" | jq -r '.distri')
    groupid=$(echo "$target" | jq -r '.groupid')
    flavor=$(echo "$target" | jq -r '.flavor // empty')
    version=$(echo "$target" | jq -r '.version // empty')
    st=$(echo "$target" | jq -r '.state')

    base_query="${openqa_url%/}/api/v1/jobs/overview?build=${build}&groupid=${groupid}"
    [[ -n "$version" ]] && base_query="${base_query}&version=${version}"

    flavor_params=""
    if [[ -n "$flavor" ]]; then
        if echo "$target" | jq -e '.flavor | type == "array"' >/dev/null 2>&1; then
            while read -r fl; do
                [[ -n "$fl" ]] && flavor_params="${flavor_params}&flavor=${fl}"
            done < <(echo "$target" | jq -r '.flavor[]')
        else
            flavor_params="&flavor=${flavor}"
        fi
    fi
    base_query="${base_query}${flavor_params}"

    group_jobs_json="[]"

    if has_state "failed" && [[ "$f_cnt" -gt 0 ]]; then
        query_failed="${base_query}&result=failed"
        res_failed=$(api_curl "$query_failed")
        if echo "$res_failed" | jq -e 'type == "array"' >/dev/null 2>&1; then
            group_jobs_json=$(jq -s '.[0] + [.[1][] | . + {result: "failed"}]' <(echo "$group_jobs_json") <(echo "$res_failed"))
        fi
    fi

    if has_state "stopped" && [[ "$s_cnt" -gt 0 ]]; then
        query_stopped="${base_query}&result=incomplete&result=timeout_exceeded&result=parallel_failed&result=skipped&result=user_cancelled"
        res_stopped=$(api_curl "$query_stopped")
        if echo "$res_stopped" | jq -e 'type == "array"' >/dev/null 2>&1; then
            group_jobs_json=$(jq -s '.[0] + [.[1][] | . + {result: (.result // "stopped")}]' <(echo "$group_jobs_json") <(echo "$res_stopped"))
        fi
    fi

    if [[ "$group_jobs_json" == "[]" ]] && [[ "$st" != "failed" ]] && [[ "$st" != "stopped" ]]; then
        query_other="${base_query}&result=${st}"
        res_other=$(api_curl "$query_other")
        if echo "$res_other" | jq -e 'type == "array"' >/dev/null 2>&1; then
            group_jobs_json=$(jq -s '.[0] + [.[1][] | . + {result: $st}]' --arg st "$st" <(echo "$group_jobs_json") <(echo "$res_other"))
        fi
    fi

    echo "$group_jobs_json" > "$workdir/group_${target_idx}.json"
    job_count=$(echo "$group_jobs_json" | jq 'length')
    total_jobs=$((total_jobs + job_count))

    while read -r jid; do
        if [[ -n "$jid" && -z "${seen_jobs[$jid]}" ]]; then
            seen_jobs["$jid"]=1
            collected_job_ids+=("$jid")
        fi
    done < <(echo "$group_jobs_json" | jq -r '.[].id')

    target_idx=$((target_idx + 1))
done < <(echo "$targets_json" | jq -c '.[]')

# Handle fast exits
if [[ "$output_format" == "ids" ]]; then
    for jid in "${collected_job_ids[@]}"; do
        echo "$jid"
    done
    exit 0
elif [[ "$output_format" == "links" ]]; then
    for jid in "${collected_job_ids[@]}"; do
        echo "${openqa_url%/}/tests/${jid}"
    done
    exit 0
fi

# Fetch test details and failure reasons in parallel
if [[ "${#collected_job_ids[@]}" -gt 0 ]]; then
    mkdir -p "$workdir/details"
    
    active_pids=()
    for jid in "${collected_job_ids[@]}"; do
        (
            details_json=$(api_curl "${openqa_url%/}/api/v1/jobs/${jid}/details")
            echo "$details_json" | jq -c --arg base "$openqa_url" '
                [
                    .job.testresults[]? |
                    select(.result == "failed") |
                    . as $mod |
                    (
                        ([ $mod.details[]? | select(.result == "fail" and ((.title // "") | test("Failed"; "i"))) ][0]) //
                        ([ $mod.details[]? | select(.result == "fail") ][-1]) //
                        ($mod.details[-1] // {})
                    ) as $step |
                    ($step.text_data // $step.title // "") as $raw_text |
                    ($raw_text | split("\n") | map(select(length > 0)) | .[0] // "") as $first_line |
                    {
                        name: $mod.name,
                        category: ($mod.category // ""),
                        step_num: $step.num,
                        step_url: (if $step.num != null then "\($base)/tests/\(.job.id // $jid)#step/\($mod.name)/\($step.num)" else "" end),
                        first_line: $first_line,
                        full_text: $raw_text
                    }
                ] as $f_mods |
                if ($f_mods | length) > 0 then $f_mods
                else
                    if (.job.reason // "") != "" then
                        [
                            {
                                name: (.job.test // "job"),
                                category: "",
                                step_num: null,
                                step_url: "\($base)/tests/\($jid)",
                                first_line: .job.reason,
                                full_text: .job.reason
                            }
                        ]
                    else []
                    end
                end
            ' --argjson jid "$jid" > "$workdir/details/${jid}.reasons.json" 2>/dev/null || echo "[]" > "$workdir/details/${jid}.reasons.json"
        ) &
        active_pids+=($!)
        if [[ "${#active_pids[@]}" -ge "$parallel_jobs" ]]; then
            for pid in "${active_pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
            active_pids=()
        fi
    done
    for pid in "${active_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
fi

# Output mode: --modules-only
if [[ "$output_format" == "modules" ]]; then
    declare -A seen_modules=()
    for jid in "${collected_job_ids[@]}"; do
        rf="$workdir/details/${jid}.reasons.json"
        [[ ! -f "$rf" ]] && continue
        while read -r mod_entry; do
            [[ -z "$mod_entry" ]] && continue
            m_name=$(echo "$mod_entry" | jq -r '.name')
            m_cat=$(echo "$mod_entry" | jq -r '.category // empty')
            formatted_mod=$(format_perl_module "$m_name" "$m_cat")
            if [[ -n "$formatted_mod" && -z "${seen_modules[$formatted_mod]}" ]]; then
                seen_modules["$formatted_mod"]=1
                echo "$formatted_mod"
            fi
        done < <(jq -c '.[]' "$rf" 2>/dev/null || true)
    done
    exit 0
fi

# Output mode: --reasons-only
if [[ "$output_format" == "reasons" ]]; then
    for jid in "${collected_job_ids[@]}"; do
        rf="$workdir/details/${jid}.reasons.json"
        [[ ! -f "$rf" ]] && continue
        while read -r entry; do
            [[ -z "$entry" ]] && continue
            m_name=$(echo "$entry" | jq -r '.name')
            s_num=$(echo "$entry" | jq -r '.step_num // empty')
            f_line=$(echo "$entry" | jq -r '.first_line')
            full_t=$(echo "$entry" | jq -r '.full_text')

            if [[ "$full_reason" -eq 1 ]]; then
                echo "=== Job $jid | Module: $m_name (step: ${s_num:-N/A}) ==="
                echo "$full_t"
                echo ""
            else
                if [[ -n "$s_num" ]]; then
                    printf "[%s] %s (#step/%s/%s): %s\n" "$jid" "$m_name" "$m_name" "$s_num" "$f_line"
                else
                    printf "[%s] %s: %s\n" "$jid" "$m_name" "$f_line"
                fi
            fi
        done < <(jq -c '.[]' "$rf" 2>/dev/null || true)
    done
    exit 0
fi

# Output mode: --json
if [[ "$output_format" == "json" ]]; then
    json_out_file="$workdir/aggregated.json"
    target_idx=0
    while read -r target; do
        inc_num=$(echo "$target" | jq -r '.incident_number')
        inc_proj=$(echo "$target" | jq -r '.incident_project')
        grp_name=$(echo "$target" | jq -r '.name')
        
        group_file="$workdir/group_${target_idx}.json"
        target_idx=$((target_idx + 1))
        [[ ! -f "$group_file" ]] && continue

        while read -r job; do
            [[ -z "$job" ]] && continue
            jid=$(echo "$job" | jq -r '.id')
            jname=$(echo "$job" | jq -r '.name')
            jres=$(echo "$job" | jq -r '.result // "failed"')
            
            rf="$workdir/details/${jid}.reasons.json"
            f_details="[]"
            [[ -f "$rf" ]] && f_details=$(cat "$rf")

            jq -n \
                --argjson id "$jid" \
                --arg name "$jname" \
                --arg result "$jres" \
                --argjson inc "$inc_num" \
                --arg proj "$inc_proj" \
                --arg grp "$grp_name" \
                --arg url "${openqa_url%/}/tests/${jid}" \
                --argjson details "$f_details" \
                '{
                    id: $id,
                    name: $name,
                    result: $result,
                    incident_number: $inc,
                    incident_project: $proj,
                    group_name: $grp,
                    failures: [
                        $details[] | {
                            module: .name,
                            category: .category,
                            step_num: .step_num,
                            step_url: .step_url,
                            reason: .first_line,
                            full_reason: .full_text
                        }
                    ],
                    url: $url
                }' >> "$json_out_file"
        done < <(jq -c '.[]' "$group_file" 2>/dev/null || true)
    done < <(echo "$targets_json" | jq -c '.[]')

    if [[ -s "$json_out_file" ]]; then
        jq -s 'unique_by(.id)' "$json_out_file"
    else
        echo "[]"
    fi
    exit 0
fi

# Output mode: pretty
target_idx=0
declare -A all_failing_modules=()

while read -r target; do
    inc_num=$(echo "$target" | jq -r '.incident_number')
    inc_proj=$(echo "$target" | jq -r '.incident_project')
    grp_name=$(echo "$target" | jq -r '.name')
    f_cnt=$(echo "$target" | jq -r '.failed')
    s_cnt=$(echo "$target" | jq -r '.stopped')
    build=$(echo "$target" | jq -r '.build')
    distri=$(echo "$target" | jq -r '.distri')
    groupid=$(echo "$target" | jq -r '.groupid')
    version=$(echo "$target" | jq -r '.version // empty')
    pkgs=$(echo "$target" | jq -r '.packages | join(", ")')

    overview_url="${openqa_url%/}/tests/overview?build=${build}&groupid=${groupid}"
    [[ -n "$distri" ]] && overview_url="${overview_url}&distri=${distri}"
    [[ -n "$version" ]] && overview_url="${overview_url}&version=${version}"

    group_file="$workdir/group_${target_idx}.json"
    target_idx=$((target_idx + 1))
    
    group_jobs_count=0
    [[ -f "$group_file" ]] && group_jobs_count=$(jq 'length' "$group_file")

    printf "%s %s (%s) | Group: %s [ID: %s]\n" \
        "$(_c_bold "Incident $inc_num")" \
        "$(_c_yellow "$inc_proj")" \
        "$(_c_dim "$pkgs")" \
        "$(_c_cyan "$grp_name")" \
        "$groupid"
    printf "  %s: %s (failed: %s, stopped: %s)\n" "$(_c_dim "Overview")" "$overview_url" "$f_cnt" "$s_cnt"

    if [[ "$group_jobs_count" -eq 0 ]]; then
        printf "  %s\n\n" "$(_c_dim "No specific failed jobs found in openQA (may have been restarted/cleared).")"
    else
        while read -r job; do
            jid=$(echo "$job" | jq -r '.id')
            jname=$(echo "$job" | jq -r '.name')
            jres=$(echo "$job" | jq -r '.result // "failed"')
            jurl="${openqa_url%/}/tests/${jid}"

            res_str="$(_c_red "$jres")"
            if [[ "$jres" != "failed" ]]; then
                res_str="$(_c_yellow "$jres")"
            fi

            printf "  - [%s] %s (%s)\n" "$jid" "$jname" "$res_str"

            rf="$workdir/details/${jid}.reasons.json"
            if [[ -f "$rf" ]]; then
                while read -r entry; do
                    [[ -z "$entry" ]] && continue
                    m_name=$(echo "$entry" | jq -r '.name')
                    m_cat=$(echo "$entry" | jq -r '.category // empty')
                    s_num=$(echo "$entry" | jq -r '.step_num // empty')
                    s_url=$(echo "$entry" | jq -r '.step_url // empty')
                    f_line=$(echo "$entry" | jq -r '.first_line')
                    full_t=$(echo "$entry" | jq -r '.full_text')

                    fmt_mod=$(format_perl_module "$m_name" "$m_cat")
                    all_failing_modules["$fmt_mod"]=1

                    printf "    %s: %s\n" "$(_c_bold "Failed module")" "$(_c_red "$fmt_mod")"

                    if [[ "$show_reason" -eq 1 ]]; then
                        if [[ -n "$s_num" ]]; then
                            printf "    %s: %s\n" "$(_c_bold "Failed step")" "$(_c_cyan "#step/${m_name}/${s_num}") $(_c_dim "(${s_url})")"
                        fi

                        if [[ "$full_reason" -eq 1 ]]; then
                            printf "    %s:\n" "$(_c_bold "Message in box")"
                            while IFS= read -r line; do
                                printf "      %s\n" "$(_c_magenta "$line")"
                            done <<< "$full_t"
                        else
                            printf "    %s: %s\n" "$(_c_bold "Reason")" "$(_c_magenta "$f_line")"
                        fi
                    fi
                done < <(jq -c '.[]' "$rf" 2>/dev/null || true)
            fi

            printf "    %s: %s\n" "$(_c_dim "Job URL")" "$(_c_dim "$jurl")"
        done < <(jq -c '.[]' "$group_file" 2>/dev/null || true)
        echo ""
    fi
done < <(echo "$targets_json" | jq -c '.[]')

echo "============================================================"
printf "%s Total jobs: %s (%s unique) across %s test group(s)\n" \
    "$(_c_bold "Summary:")" \
    "$(_c_red "$total_jobs")" \
    "${#seen_jobs[@]}" \
    "$target_count"
if [[ "${#all_failing_modules[@]}" -gt 0 ]]; then
    printf "%s Unique failing Perl module(s) (%s):\n" "$(_c_bold "Failing modules:")" "${#all_failing_modules[@]}"
    for mod in "${!all_failing_modules[@]}"; do
        printf "  - %s\n" "$(_c_red "$mod")"
    done
fi
echo "============================================================"

# Retry / restart functionality
if [[ "$retry_jobs" -eq 1 ]]; then
    unique_ids=("${collected_job_ids[@]}")
    job_count="${#unique_ids[@]}"
    if [[ "$job_count" -eq 0 ]]; then
        echo "No failed jobs to retry."
        exit 0
    fi

    echo ""
    printf "%s Found %s unique failed/stopped openQA job(s) eligible for restart.\n" "$(_c_bold "Retry:")" "$job_count"

    if [[ "$dry_run" -eq 1 ]]; then
        printf "%s (Dry-run enabled, no modifications will be performed):\n" "$(_c_yellow "[DRY-RUN]")"
        for id in "${unique_ids[@]}"; do
            echo "  openqa-cli api --osd -X POST jobs/${id}/restart"
        done
        exit 0
    fi

    if [[ "$auto_yes" -eq 0 ]]; then
        printf "Are you sure you want to restart %s job(s) on openQA? [y/N]: " "$job_count"
        read -r answer
        if [[ ! "$answer" =~ ^[yY]([eE][sS])?$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    if [[ -n "$OPENQA_TOKEN_OSD" ]] && [[ -z "$OPENQA_KEY" || -z "$OPENQA_SECRET" ]]; then
        IFS=':' read -r _t_user OPENQA_KEY OPENQA_SECRET <<< "$OPENQA_TOKEN_OSD"
        export OPENQA_KEY OPENQA_SECRET
    fi

    success_count=0
    fail_count=0
    idx=1
    for id in "${unique_ids[@]}"; do
        printf "[%s/%s] Restarting job %s... " "$idx" "$job_count" "$id"
        idx=$((idx + 1))
        
        if command -v openqa-cli &>/dev/null; then
            res=$(openqa-cli api --osd -X POST "jobs/${id}/restart" 2>&1) || true
        else
            res=$(api_curl -X POST "${openqa_url%/}/api/v1/jobs/${id}/restart") || true
        fi

        if echo "$res" | grep -qiE "clone_id|job_id|result\":1|result\":true"; then
            new_id=$(echo "$res" | grep -oE '"(clone_id|job_id)":\s*[0-9]+' | grep -oE '[0-9]+' | head -n 1 || true)
            if [[ -n "$new_id" ]]; then
                printf "%s (cloned as job %s)\n" "$(_c_green "OK")" "$new_id"
            else
                printf "%s\n" "$(_c_green "OK")"
            fi
            success_count=$((success_count + 1))
        else
            err_msg=$(echo "$res" | tr '\n' ' ' | cut -c 1-80)
            printf "%s (%s)\n" "$(_c_red "FAILED")" "$err_msg"
            fail_count=$((fail_count + 1))
        fi
    done

    echo ""
    printf "%s Successfully restarted %s job(s), %s failed.\n" "$(_c_bold "Restart completed:")" "$success_count" "$fail_count"
fi
