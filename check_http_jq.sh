#!/bin/sh

OIDC_TOKEN_REQUEST_SH="./oidc_token_request.sh"

_DEBUG="off"
function DEBUG() {
    [ "$_DEBUG" == "on" ] && $@
}

function print_params() {
    cat <<- _EOF_
Parameters:
    request=$arg_request
    auth=$arg_auth
    username=$arg_username
    password=$arg_password
    token-url=$arg_token_url
    client-id=$arg_client_id
    client-secret=$arg_client_secret
    filter=$arg_filter
    curl-opts=$arg_curl_opts
    verbose=$arg_verbose
URL:    
    $arg_url
_EOF_
}

function create_temp_file() {
    local name="${1:-temp}"
    tempFile=$(mktemp -t ${name}XXXXX)
    trap 'rm -f "$tempFile"' EXIT
    if [ $? -ne 0 ]; then
        echo "failed to create temp file: $tempFile"
        exit 3
    fi
    DEBUG echo "created temp file: $tempFile"
}

function apply_filter() {
    local filter=$1
    local input=$2

    outcome=$(jq "$filter" --raw-output "$input")
    echo $outcome

    case ${outcome:0:8} in
        OK* )   exit 0
                ;;
        WARN*)  exit 1
                ;;
        CRIT*)  exit 2
                ;;
        *)      exit 3
                ;;
    esac
}

function _main_() {
    DEBUG print_params

    local curlCommand=("curl")
    curlCommand+=(${arg_curl_opts[@]})

    # add auth
    if [[ $arg_auth == "BASIC" ]]; then
        curlCommand+=("--basic" "-u" "$arg_username:$arg_password")
    elif [[ $arg_auth == "OIDC" ]]; then
        # build token command
        local authCommand=($OIDC_TOKEN_REQUEST_SH)
        authCommand+=("--auth-server" "$arg_auth_server")
        authCommand+=("--realm" "$arg_realm")
        authCommand+=("--grant" "$oidc_grant_type")
        authCommand+=("--client-id" "$arg_client_id")
        if ! [[ -z ${arg_client_secret+x} ]]; then
            authCommand+=("--client-secret" "$arg_client_secret")
        fi
        if [[ "$oidc_grant_type" == "PASSWORD" ]]; then
            authCommand+=("--username" "$arg_username")
            authCommand+=("--password" "$arg_password")
        fi
        if ! [[ -z ${arg_oidc_cache_file+x} ]]; then
            authCommand+=("--cache-file" "$arg_oidc_cache_file")
        fi
        if [[ "$arg_verbose" -ge "2" ]]; then
            authCommand+="-v"
        fi
        # obtain access token
        DEBUG echo "auth command: ${authCommand[@]}"
        local token=$("${authCommand[@]}") 

        if [[ $? != 0 ]]; then
            echo "\nError: Failed to obtain access_token.\n" 1>&2
            exit 3
        fi

        # add to curl request
        curlCommand+=("-H" "Authorization: Bearer $token")
    elif [[ $arg_auth == "BEARER" ]]; then
        curlCommand+=("-H" "Authorization: Bearer $arg_bearer")
    fi

    create_temp_file "check_http_jq_response-"

    # finish curl command
    curlCommand+=(-s -o "$tempFile" -w "%{http_code}" "$arg_url")
    DEBUG echo "curl command: ${curlCommand[@]}"
    statusCode=$("${curlCommand[@]}")

    DEBUG echo "StatusCode: $statusCode (expect: ${arg_expect_status})"
    if [[ "$statusCode" != "$arg_expect_status" ]]; then
        echo "Error: expected status code $arg_expect_status. actual: ${statusCode}"
        exit 3
    fi

    apply_filter "$arg_filter" "$tempFile"
}

function usage() {
    cat <<- _EOF_
Perform an http call using cURL and apply an jq filter to the response.

Usage: $0 <url>

Parameters:

 -X, --request          Specify the request command (same as cURL -X option)

     --expect-status    Specify the expected http status code that idicates a successful call (default 200)

 -a, --auth             Specify the auth method; Possible values: BASIC, OIDC, BEARER

     --username         Username    (valid with --auth BASIC and OIDC option)
     --password         Password    (valid with --auth BASIC and OIDC option)

     --auth-server      OpenID Connect auth server address      (only valid with --auth OIDC option)
     --realm            OpenID Connect auth server realm        (only valid with --auth OIDC option)
     --client-id        OpenID Connect client_id                (only valid with --auth OIDC option)
     --client-secret    OpenID Connect client_secret            (only valid with --auth OIDC option)

     --token-cache      File to store token for later reuse

     --bearer           Bearer token to use     (only valid with --auth BEAERER)

 -f, --filter           JQ filter to apply

     --curl-opts        Additional cURL options as string. e.g. "--noproxy my.domain.tld"

 -h, --help             Print this help message

Filter:

    Filter must be a valid jq filter that produces a nagios/icinga perf data compliant output.

    Nagios 3 and newer will concatenate the parts following a "|" in a) the first line output by the plugin, 
    and b) in the second to last line, into a string it passes to whatever performance data processing it has 
    configured. (Note that it currently does not insert additional whitespace between both, so the plugin needs 
    to provide some to prevent the last pair of a) and the first of b) getting run together.) Please refer to 
    the Nagios documentation for information on how to configure such processing. However, it is the responsibility 
    of the plugin writer to ensure the performance data is in a "Nagios Plugins" format.

    This is the expected format:

    'label'=value[UOM];[warn];[crit];[min];[max]

    Notes:

        1. space separated list of label/value pairs
        2. label can contain any characters except the equals sign or single quote (')
        3. the single quotes for the label are optional. Required if spaces are in the label
        4. label length is arbitrary, but ideally the first 19 characters are unique (due to a limitation in RRD).
            Be aware of a limitation in the amount of data that NRPE returns to Nagios
        5. to specify a quote character, use two single quotes
        6. warn, crit, min or max may be null (for example, if the threshold is not defined or min and max do not apply).
            Trailing unfilled semicolons can be dropped
        7. min and max are not required if UOM=%
        8. value, min and max in class [-0-9.]. Must all be the same UOM. value may be a literal "U" instead, this would 
            indicate that the actual value couldn't be determined
        9. warn and crit are in the range format (see the Section called Threshold and Ranges). Must be the same UOM
        10. UOM (unit of measurement) is a string of zero or more characters, NOT including numbers, semicolons, or quotes. 
            Some examples:
            1. no unit specified - assume a number (int or float) of things (eg, users, processes, load averages)
            2. s - seconds (also us, ms)
            3. % - percentage
            4. B - bytes (also KB, MB, TB)
            5. c - a continous counter (such as bytes transmitted on an interface)
    
    It is up to third party programs to convert the Nagios Plugins performance data into graphs.

Examples:

 $0 -X GET --auth BASIC --username \$username --password \$ecr3t --filter '.slideshow.slides | length' https://httpbin.org/json

_EOF_
}

# die with no arguments 
if [ "$#" -eq 0 ]; then
    usage
    exit 3;
fi

# parse arguments
while [ "$1" != "" ]; do
    case $1 in
        -X | --request )        shift
                                arg_request=$1
                                ;;
             --expect-status )  shift
                                arg_expect_status=$1
                                ;;
        -a | --auth )           shift
                                arg_auth=$1
                                ;;
        --username )            shift
                                arg_username=$1
                                ;;
        --password )            shift
                                arg_password=$1
                                ;;
        --auth-server )         shift
                                arg_auth_server=$1
                                ;;
        --realm )               shift
                                arg_realm=$1
                                ;;
        --client-id )           shift
                                arg_client_id=$1
                                ;;
        --client-secret )       shift
                                arg_client_secret=$1
                                ;;
        --token-cache )         shift
                                arg_oidc_cache_file=$1
                                ;;
        --bearer )              shift
                                arg_bearer=$1
                                ;;
        -f | --filter )         shift
                                arg_filter=$1
                                ;;
        --curl-opts )           shift
                                arg_curl_opts=$1
                                ;;
        -v )                    arg_verbose=1
                                ;;
        --verbose )             shift
                                arg_verbose=$1
                                ;;
        -h | --help )           usage
                                exit
                                ;;
        * )                     arg_url=$1
                                ;;
    esac
    shift
done

# defaults
arg_filter="${arg_filter:-.}"
arg_request="${arg_request:-GET}"
arg_curl_opts="${arg_curl_opts:-}"
arg_verbose="${arg_verbose:-0}"
arg_expect_status="${arg_expect_status:-200}"

# debug output
if [[ "$arg_verbose" -ge "1" ]]; then
    echo "set debug on $arg_verbose"
    _DEBUG="on"
fi

# validate required args
if [[ -z ${arg_url+x} ]]; then 
    usage
    exit 3; 
fi

# sanitize curl opts
if ! [[ -z ${arg_curl_opts+x} ]]; then
    declare -a "arg_curl_opts=( $(echo $arg_curl_opts | tr '`$<>' '????') )"
fi

# validate auth method
if [[ $arg_auth == "BASIC" ]]; then
    if ([[ -z ${arg_username+x} ]] || [[ -z ${arg_password+x} ]]); then
        echo "\nError: Auth method $arg_auth must supply username and password\n"
        exit 3;
    else 
        DEBUG echo "Using basic auth"
    fi
elif [[ $arg_auth == "OIDC" ]]; then
    if ([[ -z ${arg_auth_server+x} ]] || [[ -z ${arg_realm+x} ]]); then
        echo "\nError: Auth method $arg_auth invalid: Missing required arguments auth-server and/or realm\n" 1>&2
        exit 3
    elif ! ([[ -z ${arg_client_id+x} ]] || [[ -z ${arg_username+x} ]] || [[ -z ${arg_password+x} ]]); then
        oidc_grant_type="PASSWORD"
        if [[ -z ${arg_client_secret} ]]; then
            DEBUG echo "OIDC grant: password (public client)"
        else
            DEBUG echo "OIDC grant: password (with secret)"
        fi
    elif ! ([[ -z ${arg_client_id+x} ]] || [[ -z ${arg_client_secret+x} ]]) && ([[ -z ${arg_username+x} ]] && [[ -z ${arg_password+x} ]]); then
        oidc_grant_type="CLIENT_CREDENTIALS"
        DEBUG echo "OIDC grant: client_credentials"
    else 
        echo "\nError: Auth method $arg_auth invalid: Invalid arguments given\n" 1>&2
        exit 3
    fi
elif [[ $arg_auth == "BEARER" ]]; then
    if ([[ -z ${arg_bearer+x} ]]); then
        echo "\nError: Auth method $arg_auth must supply bearer token\n"
        exit 3;
    else 
        DEBUG echo "Using bearer auth"
    fi
else
    echo "\nError: Invalid auth method $arg_auth. Possible values: BASIC, OIDC\n" 1>&2
    exit 3;
fi

# run
_main_