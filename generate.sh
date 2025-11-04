#!/usr/bin/env bash

# Generate endpoint and operation specs from multiple API endpoints
# Reads API configuration from endpoints.json file

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
    
    # 1. Download the OpenAPI spec
    install -d "./${id}/"
    curl -s "$url" -o "./${id}/${id}-swagger-${DATE}.tmp"
    
    # Check if the downloaded file is YAML and convert to JSON if needed
    if head -n 1 "./${id}/${id}-swagger-${DATE}.tmp" | grep -q "^openapi:\|^swagger:\|^---"; then
        echo "Detected YAML format - converting to JSON"
        npx js-yaml "./${id}/${id}-swagger-${DATE}.tmp" > "./${id}/${id}-swagger-${DATE}.json"
        rm "./${id}/${id}-swagger-${DATE}.tmp"
    else
        mv "./${id}/${id}-swagger-${DATE}.tmp" "./${id}/${id}-swagger-${DATE}.json"
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
    npx openapi-typescript "./${id}/${id}-swagger-${DATE}.json" --output "./${id}/${id}-${DATE}.d.ts"

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
        jd "./${id}/${id}-swagger.json" "./${id}/${id}-swagger-${DATE}.json" > "./${id}/${id}-swagger-${DATE}.json.jdiff"
        if [ ! -s "./${id}/${id}-swagger-${DATE}.json.jdiff" ]; then
            rm "./${id}/${id}-swagger-${DATE}.json.jdiff"
        fi
    fi

    if [ -f "./${id}/${id}.d.ts" ]; then
        diff -u "./${id}/${id}.d.ts" "./${id}/${id}-${DATE}.d.ts" > "./${id}/${id}-${DATE}.d.ts.diff"
        if [ ! -s "./${id}/${id}-${DATE}.d.ts.diff" ]; then
            rm "./${id}/${id}-${DATE}.d.ts.diff"
        fi
    fi

    mv "./${id}/endpoints-${DATE}.txt" "./${id}/endpoints.txt"
    mv "./${id}/operations-${DATE}.txt" "./${id}/operations.txt"
    mv "./${id}/${id}-swagger-${DATE}.json" "./${id}/${id}-swagger.json"
    mv "./${id}/${id}-${DATE}.d.ts" "./${id}/${id}.d.ts"
    

    # jq -r -f list-paths.jq bravoapi-v0.json > endpoints.txt
    # jq -r -f list-operations.jq bravoapi-v0.json > operations.txt


    # jq -r -f list-paths.jq bravoapi-v1.json >> endpoints.txt
    # jq -r -f list-operations.jq bravoapi-v1.json >> operations.txt


    # npx openapi-typescript ./bravoapi-v0.json -o ./bravoapi-v0.d.ts
    # npx openapi-typescript ./bravoapi-v1.json -o ./bravoapi-v1.d.ts


  echo ""
done

echo "All APIs processed!"

