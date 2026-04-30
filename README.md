# openapi-diff-generator

## Overview
This repository contains a shell script, `generate.sh`, that reads an `endpoints.json` file and for each API:
- downloads or copies the OpenAPI/Swagger spec
- converts YAML to JSON when needed
- converts Swagger 2.x to OpenAPI 3.x when needed
- generates TypeScript types
- extracts endpoint and operation lists
- produces diffs against the previous run

## Usage
Create an `endpoints.json` file in the same directory as `generate.sh`:

```
[
	{
		"name": "API Name",
		"url": "https://example.com/swagger.json",
		"id": "api-id"
	}
]
```

Run the script:

```
./generate.sh
```

To skip the auto-update check:

```
./generate.sh --no-update
```

## Requirements
- Bash
- `curl`
- `jq`
- `node` + `npx`
- `js-yaml` (used via `npx -y`)
- `swagger2openapi` (used via `npx -y`)
- `openapi-typescript` (used via `npx -y`)
- `jd` (JSON diff tool)

### Install requirements

Ubuntu/Debian:

```
sudo apt update && sudo apt install -y curl jq nodejs npm
go install github.com/josephburnett/jd/v2/cmd/jd@latest
export PATH="$(go env GOPATH)/bin:$PATH"
```

macOS (Homebrew):

```
brew install curl jq node
go install github.com/josephburnett/jd/v2/cmd/jd@latest
export PATH="$(go env GOPATH)/bin:$PATH"
```

Optional global install for `openapi-typescript`:

```
npm install -g openapi-typescript
```

## Output
For each API `id`, the script creates a folder and maintains current artifacts:
- `id/id-swagger.json` (latest normalized spec)
- `id/id.d.ts` (latest TypeScript types)
- `id/endpoints.txt` (latest paths)
- `id/operations.txt` (latest operations)

When changes are detected, it also writes timestamped diffs:
- `endpoints-diff-<timestamp>.txt`
- `operations-diff-<timestamp>.txt`
- `id-swagger-<timestamp>.json.jdiff`
- `id-<timestamp>.d.ts.diff`
