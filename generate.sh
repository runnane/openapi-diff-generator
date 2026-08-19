#!/usr/bin/env bash

# Generate endpoint and operation specs from multiple API endpoints
# Reads API configuration from endpoints.json file

SCRIPT_VERSION="1.2.0"
SCRIPT_URL="https://raw.githubusercontent.com/runnane/openapi-diff-generator/refs/heads/main/generate.sh"

show_requirements_help() {
    echo ""
    echo "Requirements:"
    echo "- curl"
    echo "- jq"
    echo "- node + npx"
    echo "- jd (JSON diff tool)"
    echo ""
    echo "Install examples:"
    echo "- Ubuntu/Debian:"
    echo "  sudo apt update && sudo apt install -y curl jq nodejs npm"
    echo "- macOS (Homebrew):"
    echo "  brew install curl jq node"
    echo ""
    echo "Install jd:"
    echo "  go install github.com/josephburnett/jd/v2/cmd/jd@latest"
    echo '  export PATH="$(go env GOPATH)/bin:$PATH"'
    echo ""
    echo "Optional global install for openapi-typescript (not required when npx works):"
    echo "  npm install -g openapi-typescript"
    echo ""
}

check_requirements() {
    local missing=()
    local required_cmds=(curl jq node npx jd)

    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: Missing required applications: ${missing[*]}"
        show_requirements_help
        exit 1
    fi
}

# Auto-update function
check_for_updates() {
    echo "Checking for script updates..."

    # Download the latest version to a temp file
    TEMP_SCRIPT=$(mktemp)
    if ! curl -s -f "$SCRIPT_URL" -o "$TEMP_SCRIPT"; then
        echo "Warning: Could not check for updates (network error)"
        rm -f "$TEMP_SCRIPT"
        return
    fi

    # Extract version from downloaded script
    REMOTE_VERSION=$(grep '^SCRIPT_VERSION=' "$TEMP_SCRIPT" | cut -d'"' -f2)

    if [ -z "$REMOTE_VERSION" ]; then
        echo "Warning: Could not determine remote version"
        rm -f "$TEMP_SCRIPT"
        return
    fi

    echo "Current version: $SCRIPT_VERSION"
    echo "Remote version: $REMOTE_VERSION"

    # Compare versions (simple string comparison)
    if [ "$SCRIPT_VERSION" != "$REMOTE_VERSION" ]; then
        echo "New version available: $REMOTE_VERSION"
        echo -n "Update script? [y/N] "
        read -r response

        if [[ "$response" =~ ^[Yy]$ ]]; then
            # Backup current script
            cp "$0" "$0.backup-$(date +%Y%m%d-%H%M%S)"

            # Replace current script with new version
            cp "$TEMP_SCRIPT" "$0"
            chmod +x "$0"

            echo "Script updated to version $REMOTE_VERSION"
            echo "Backup saved. Restarting script..."
            rm -f "$TEMP_SCRIPT"

            # Re-execute the script with same arguments
            exec "$0" "$@"
        else
            echo "Update skipped"
        fi
    else
        echo "Script is up to date"
    fi

    rm -f "$TEMP_SCRIPT"
}

# ---------------------------------------------------------------------------
# Environment file support
#
# Some OpenAPI documents are served from behind authentication, so fetching one
# needs a credential. endpoints.json is meant to be committed, so the credential
# cannot live there. Instead, `url` and an optional `headers` object may
# reference `${VAR}`, resolved from a dotenv file at run time:
#
#   [
#     {
#       "name": "Example API",
#       "url": "${EXAMPLE_API_URL}/openapi.json",
#       "id": "example-api",
#       "headers": {
#         "Authorization": "Bearer ${EXAMPLE_API_TOKEN}"
#       }
#     }
#   ]
#
# Lookup order, first hit wins:
#   $OPENAPI_ENV_FILE   explicit override
#   ./.env              next to endpoints.json
#   ../.env             the parent directory, for a package-local .env
#
# The file is PARSED, not sourced: a dotenv file is data, and sourcing it would
# execute whatever a stray `$(...)` in a secret happened to look like.
# ---------------------------------------------------------------------------

load_env_file() {
    local file="$1"
    [ -f "$file" ] || return 1

    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        line="${line#export }"

        key="${line%%=*}"
        [ "$key" = "$line" ] && continue          # no '=' on the line
        value="${line#*=}"
        key="${key%"${key##*[![:space:]]}"}"      # rtrim key
        case "$key" in [A-Za-z_][A-Za-z0-9_]*) ;; *) continue ;; esac

        # Strip one layer of matching quotes; otherwise leave the value intact
        # apart from trailing whitespace. Inline `# comments` are NOT stripped:
        # '#' is a legal character in a secret and guessing wrong silently
        # truncates a credential. Quote such values.
        if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
            value="${value:1:${#value}-2}"
        else
            value="${value%"${value##*[![:space:]]}"}"
        fi

        export "$key=$value"
    done < "$file"
}

# Shared jq filter. `env[.n] // ""` leaves an unset variable empty, but
# check_required_vars refuses the endpoint first, so that is a fallback rather
# than the normal path.
JQ_EXPAND='def expand: if type == "string" then gsub("\\$\\{(?<n>[A-Za-z_][A-Za-z0-9_]*)\\}"; env[.n] // "") else . end;'

# Every ${VAR} an endpoint references must be set. Fail up front with the names,
# rather than sending an empty header and letting the API answer 401.
check_required_vars() {
    local endpoint="$1" var missing=() referenced
    referenced=$(printf '%s' "$endpoint" \
        | jq -r '[ (.url // ""), ((.headers // {}) | to_entries[] | .value | tostring) ] | join("\n")' \
        | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | tr -d '${}' | sort -u)

    for var in $referenced; do
        if [ -z "${!var:-}" ]; then
            missing+=("$var")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Error: endpoint references unset variables: ${missing[*]}"
        echo "       Set them in ${ENV_FILE_LOADED:-a .env file} or export them."
        return 1
    fi
}

expand_endpoint_url() {
    printf '%s' "$1" | jq -r "$JQ_EXPAND"' .url | expand'
}

# curl config lines for `-K -`. Headers are fed on STDIN rather than as `-H` on
# argv so a token never appears in `ps` output on a shared machine. `tojson`
# produces exactly the \" and \\ escaping curl's config parser expects.
endpoint_curl_config() {
    printf '%s' "$1" | jq -r "$JQ_EXPAND"'
        (.headers // {})
        | to_entries[]
        | "header = " + ((.key + ": " + (.value | tostring | expand)) | tojson)'
}

fetch_spec() {
    local endpoint="$1" url="$2" out="$3"
    endpoint_curl_config "$endpoint" | curl -sSf -L --connect-timeout 10 -K - "$url" -o "$out"
}

# Run update check unless --no-update flag is passed
check_requirements

if [[ ! "$*" =~ --no-update ]]; then
    check_for_updates "$@"
fi

# Check if endpoints.json exists
if [ ! -f "endpoints.json" ]; then
    echo "Error: endpoints.json not found!"
    echo "Please create an endpoints.json file with the following structure:"
    echo '['
    echo '  {'
    echo '    "name": "API Name",'
    echo '    "url": "https://example.com/swagger.json",'
    echo '    "id": "api-id"'
    echo '  }'
    echo ']'
    exit 1
fi

ENV_FILE_LOADED=""
for env_candidate in "${OPENAPI_ENV_FILE:-}" "./.env" "../.env"; do
    [ -n "$env_candidate" ] || continue
    if load_env_file "$env_candidate"; then
        ENV_FILE_LOADED="$env_candidate"
        echo "Loaded environment from $env_candidate"
        break
    fi
done
if [ -z "$ENV_FILE_LOADED" ]; then
    echo "No .env file found (looked at \$OPENAPI_ENV_FILE, ./.env, ../.env) - using the ambient environment only."
fi

DATE=$(date +%Y-%m-%d)
DATETIME=$(date +%Y%m%d-%H%M%S)

# Read endpoints from JSON file and loop through each
jq -c '.[]' endpoints.json | while read -r endpoint; do
    name=$(echo "$endpoint" | jq -r '.name')
    url_template=$(echo "$endpoint" | jq -r '.url')
    id=$(echo "$endpoint" | jq -r '.id')

    echo "=================================================="
    echo "Processing API: $name"
    # The TEMPLATE, not the expanded value: a url may itself carry a token, and
    # this output often ends up in a CI log.
    echo "URL: $url_template"
    echo "ID: $id"
    echo "=================================================="

    if ! check_required_vars "$endpoint"; then
        echo ""
        continue
    fi

    url=$(expand_endpoint_url "$endpoint")
    header_names=$(echo "$endpoint" | jq -r '(.headers // {}) | keys[]?' | paste -sd', ' -)
    if [ -n "$header_names" ]; then
        # Names only. Never the values.
        echo "Request headers: $header_names"
    fi

    # 1. Download or copy the OpenAPI spec
    install -d "./${id}/"
    if [[ "$url" =~ ^https?:// ]]; then
        echo "Downloading from URL..."
        if ! fetch_spec "$endpoint" "$url" "./${id}/${id}-swagger-${DATE}.tmp"; then
            echo "Error: Failed to download $url_template - skipping ${id}"
            rm -f "./${id}/${id}-swagger-${DATE}.tmp"
            echo ""
            continue
        fi
    elif [ -f "$url" ]; then
        echo "Using local file: $url"
        if ! cp "$url" "./${id}/${id}-swagger-${DATE}.tmp"; then
            echo "Error: Failed to copy local file $url - skipping ${id}"
            rm -f "./${id}/${id}-swagger-${DATE}.tmp"
            echo ""
            continue
        fi
    else
        echo "Error: URL is not a valid HTTP(S) URL and local file not found: $url_template - skipping ${id}"
        echo ""
        continue
    fi

    # Verify the downloaded/copied file exists and is non-empty
    if [ ! -s "./${id}/${id}-swagger-${DATE}.tmp" ]; then
        echo "Error: Downloaded/copied spec is missing or empty - skipping ${id}"
        rm -f "./${id}/${id}-swagger-${DATE}.tmp"
        echo ""
        continue
    fi

    # Check if the downloaded file is YAML and convert to JSON if needed
    if head -n 1 "./${id}/${id}-swagger-${DATE}.tmp" | grep -q "^openapi:\|^swagger:\|^---"; then
        echo "Detected YAML format - converting to JSON"
        npx -y js-yaml "$(pwd)/${id}/${id}-swagger-${DATE}.tmp" > "./${id}/${id}-swagger-${DATE}.json"
        rm "./${id}/${id}-swagger-${DATE}.tmp"
    else
        mv "./${id}/${id}-swagger-${DATE}.tmp" "./${id}/${id}-swagger-${DATE}.json"
    fi

    # Validate that we have a parseable JSON spec before continuing
    if [ ! -s "./${id}/${id}-swagger-${DATE}.json" ] || ! jq empty "./${id}/${id}-swagger-${DATE}.json" >/dev/null 2>&1; then
        echo "Error: Spec for ${id} is missing, empty, or not valid JSON - skipping"
        rm -f "./${id}/${id}-swagger-${DATE}.json" "./${id}/${id}-swagger-${DATE}.tmp"
        echo ""
        continue
    fi

    # Convert Swagger 2.x to OpenAPI 3.x if needed
    if jq -e '.swagger' "./${id}/${id}-swagger-${DATE}.json" > /dev/null 2>&1; then
        echo "Detected Swagger 2.x - converting to OpenAPI 3.x"
        npx -y swagger2openapi "$(pwd)/${id}/${id}-swagger-${DATE}.json" -o "$(pwd)/${id}/${id}-swagger-${DATE}.oas3.json"
        mv "$(pwd)/${id}/${id}-swagger-${DATE}.oas3.json" "./${id}/${id}-swagger-${DATE}.json"
    fi

    # Apply per-API patches if a patch script exists
    if [ -f "./${id}/patch.sh" ]; then
        echo "Applying patches from ${id}/patch.sh..."
        bash "./${id}/patch.sh" "./${id}/${id}-swagger-${DATE}.json"
    fi

    # Check if the newly downloaded file is identical to the existing non-date-tagged file
    if [ -f "./${id}/${id}-swagger.json" ]; then
        if cmp -s "./${id}/${id}-swagger.json" "./${id}/${id}-swagger-${DATE}.json"; then
            echo "No changes detected in OpenAPI spec - skipping processing for ${id}"
            rm "./${id}/${id}-swagger-${DATE}.json"
            echo ""
            continue
        else
            echo "Changes detected in OpenAPI spec - processing ${id}"
        fi
    else
        echo "No existing spec found - processing ${id}"
    fi

    # 2. Generate TypeScript types
    #
    # Guarded: an unguarded failure here still moved the freshly downloaded
    # spec into place next to the STALE .d.ts below, and then reported
    # "All APIs processed!" over the top of it.
    if ! npx -y openapi-typescript "$(pwd)/${id}/${id}-swagger-${DATE}.json" --output "$(pwd)/${id}/${id}-${DATE}.d.ts"; then
        echo "Error: openapi-typescript failed for ${id} - leaving the existing files untouched"
        rm -f "./${id}/${id}-swagger-${DATE}.json"
        echo ""
        continue
    fi

    # 3. Extract paths/operations using inline jq filters
    jq -r '.paths | keys[]' "./${id}/${id}-swagger-${DATE}.json" > ./${id}/endpoints-${DATE}.txt

    jq -r '.paths
        | to_entries
        | map(select(.key | test("^x-") | not))
        | map(
            .key as $path
            | .value
            | to_entries
            | map(
                select(.key | IN("get", "put", "post", "delete", "options", "head", "patch", "trace"))
                | {
                    method: .key,
                    path: $path,
                    summary: .value.summary?,
                    deprecated: .value.deprecated?
                }
            )[]
        )
        | map(
            .method + "\t" + .path + "\t" + .summary + (if .deprecated then " (deprecated)" else "" end)
        )[]' "./${id}/${id}-swagger-${DATE}.json" > ./${id}/operations-${DATE}.txt


    if [ -f "./${id}/endpoints.txt" ]; then
        diff -u "./${id}/endpoints.txt" ./${id}/endpoints-${DATE}.txt > "./${id}/endpoints-diff-${DATETIME}.txt" || true
        if [ ! -s "./${id}/endpoints-diff-${DATETIME}.txt" ]; then
            rm "./${id}/endpoints-diff-${DATETIME}.txt"
        fi
    fi

    if [ -f "./${id}/operations.txt" ]; then
        diff -u "./${id}/operations.txt" ./${id}/operations-${DATE}.txt > "./${id}/operations-diff-${DATETIME}.txt" || true
        if [ ! -s "./${id}/operations-diff-${DATETIME}.txt" ]; then
            rm "./${id}/operations-diff-${DATETIME}.txt"
        fi
    fi

    if [ -f "./${id}/${id}-swagger.json" ]; then
        jd "./${id}/${id}-swagger.json" "./${id}/${id}-swagger-${DATE}.json" > "./${id}/${id}-swagger-${DATETIME}.json.jdiff"
        if [ ! -s "./${id}/${id}-swagger-${DATETIME}.json.jdiff" ]; then
            rm "./${id}/${id}-swagger-${DATETIME}.json.jdiff"
        fi
    fi

    if [ -f "./${id}/${id}.d.ts" ]; then
        diff -u "./${id}/${id}.d.ts" "./${id}/${id}-${DATE}.d.ts" > "./${id}/${id}-${DATETIME}.d.ts.diff"
        if [ ! -s "./${id}/${id}-${DATETIME}.d.ts.diff" ]; then
            rm "./${id}/${id}-${DATETIME}.d.ts.diff"
        fi
    fi

    mv "./${id}/endpoints-${DATE}.txt" "./${id}/endpoints.txt"
    mv "./${id}/operations-${DATE}.txt" "./${id}/operations.txt"
    mv "./${id}/${id}-swagger-${DATE}.json" "./${id}/${id}-swagger.json"
    mv "./${id}/${id}-${DATE}.d.ts" "./${id}/${id}.d.ts"




  echo ""
done

echo "All APIs processed!"

