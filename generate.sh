#!/usr/bin/env bash

# Generate endpoint and operation specs from multiple API endpoints
# Reads API configuration from endpoints.json file

SCRIPT_VERSION="1.1.1"
SCRIPT_URL="https://raw.githubusercontent.com/runnane/openapi-diff-generator/refs/heads/main/generate.sh"

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

# Run update check unless --no-update flag is passed
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

DATE=$(date +%Y-%m-%d)
DATETIME=$(date +%Y%m%d-%H%M%S)

# Read endpoints from JSON file and loop through each
jq -c '.[]' endpoints.json | while read -r endpoint; do
    name=$(echo "$endpoint" | jq -r '.name')
    url=$(echo "$endpoint" | jq -r '.url')
    id=$(echo "$endpoint" | jq -r '.id')
    
    echo "=================================================="
    echo "Processing API: $name"
    echo "URL: $url"
    echo "ID: $id"
    echo "=================================================="
    
    # 1. Download or copy the OpenAPI spec
    install -d "./${id}/"
    if [[ "$url" =~ ^https?:// ]]; then
        echo "Downloading from URL..."
        curl -s "$url" -o "./${id}/${id}-swagger-${DATE}.tmp"
    elif [ -f "$url" ]; then
        echo "Using local file: $url"
        cp "$url" "./${id}/${id}-swagger-${DATE}.tmp"
    else
        echo "Error: URL is not a valid HTTP(S) URL and local file not found: $url"
        continue
    fi
    
    # Check if the downloaded file is YAML and convert to JSON if needed
    if head -n 1 "./${id}/${id}-swagger-${DATE}.tmp" | grep -q "^openapi:\|^swagger:\|^---"; then
        echo "Detected YAML format - converting to JSON"
        npx js-yaml "$(pwd)/${id}/${id}-swagger-${DATE}.tmp" > "./${id}/${id}-swagger-${DATE}.json"
        rm "./${id}/${id}-swagger-${DATE}.tmp"
    else
        mv "./${id}/${id}-swagger-${DATE}.tmp" "./${id}/${id}-swagger-${DATE}.json"
    fi

    # Convert Swagger 2.x to OpenAPI 3.x if needed
    if jq -e '.swagger' "./${id}/${id}-swagger-${DATE}.json" > /dev/null 2>&1; then
        echo "Detected Swagger 2.x - converting to OpenAPI 3.x"
        npx -y swagger2openapi "$(pwd)/${id}/${id}-swagger-${DATE}.json" -o "$(pwd)/${id}/${id}-swagger-${DATE}.oas3.json"
        mv "$(pwd)/${id}/${id}-swagger-${DATE}.oas3.json" "./${id}/${id}-swagger-${DATE}.json"
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
    npx openapi-typescript "$(pwd)/${id}/${id}-swagger-${DATE}.json" --output "$(pwd)/${id}/${id}-${DATE}.d.ts"

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

