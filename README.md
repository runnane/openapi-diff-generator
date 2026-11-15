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

The update check only ever offers a **newer** `SCRIPT_VERSION` than the running
copy (compared with `sort -V`). A copy that is ahead of `main` is told so and is
never offered a downgrade.

## Authenticated specs

Some OpenAPI documents are served from behind authentication. `endpoints.json` is
meant to be committed, so the credential cannot live in it. Instead, `url` and an
optional `headers` object may reference `${VAR}`, resolved at run time:

```
[
	{
		"name": "Example API",
		"url": "${EXAMPLE_API_URL}/openapi.json",
		"id": "example-api",
		"headers": {
			"Authorization": "Bearer ${EXAMPLE_API_TOKEN}"
		}
	}
]
```

Values come from a dotenv file. Lookup order, first hit wins:

| Source | Notes |
| --- | --- |
| `$OPENAPI_ENV_FILE` | Explicit override |
| `./.env` | Next to `endpoints.json` |
| `../.env` | Parent directory, for a package-local `.env` |

```
OPENAPI_ENV_FILE=../secrets/.env ./generate.sh --no-update
```

Notes:

- **Headers are passed to `curl` on stdin** (`-K -`), never on the command line,
  so a token does not appear in `ps` output on a shared machine.
- **Only header names are logged**, never their values, and the `url` is logged
  as the unexpanded template — a url may itself carry a token, and this output
  often ends up in a CI log.
- **A missing variable fails that endpoint up front**, naming what is unset,
  instead of sending an empty header and reporting whatever the API says about
  it. Other endpoints still run.
- **The dotenv file is parsed, not sourced.** A dotenv file is data; sourcing it
  would execute whatever a stray `$(...)` in a secret happened to look like.
  Inline `# comments` are not stripped, because `#` is legal in a secret —
  quote any value that contains one.
- Endpoints with no `${VAR}` and no `headers` behave exactly as before; no
  `.env` is required.

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

## openapi-typescript toolchain

`npx` resolves a project-local install before downloading one, so the generated
types depend on whatever version the caller happens to have linked — and on the
`typescript` that install resolved against, since openapi-typescript 7.x drives
the TypeScript compiler API and peers on `typescript@^5.x`.

In a workspace whose compiler is `typescript@7` native there is no `ts.factory`,
and the linked binary dies on import before it reads the spec:

```
TypeError: Cannot read properties of undefined (reading 'createKeywordTypeNode')
```

Pinning versions on the command line does not fix this on its own: `npx` walks
*up* from the working directory and still finds the local copy. Escaping it means
running from a directory outside the caller's tree.

| `OPENAPI_TS_ISOLATED` | Behaviour |
| --- | --- |
| `auto` *(default)* | Use whatever `npx` resolves. If that fails, retry **once** with pinned versions from an isolated directory, so a broken or incompatible local install self-heals. No change for a toolchain that already works. |
| `1` | Always run pinned and isolated. Reproducible output that does not depend on the caller's `node_modules`. |
| `0` | Never isolate. Fail as the local install fails. |

Versions used for the isolated run:

| Variable | Default |
| --- | --- |
| `OPENAPI_TS_VERSION` | `7.13.0` |
| `OPENAPI_TS_TYPESCRIPT` | `5.9.3` |

```
OPENAPI_TS_ISOLATED=1 OPENAPI_TS_VERSION=7.9.1 ./generate.sh --no-update
```

## YAML and Swagger 2 conversions

The same `npx` trap applies to the format conversions, and worse: inside a pnpm
workspace that carries `js-yaml` or `swagger2openapi` only as a transitive
dependency, `npx` decides the package is installed and runs a bin pnpm never
linked (`sh: 1: js-yaml: not found`). Both conversions are deterministic, so
there is no local install worth preferring — they **always** run pinned, from an
isolated directory:

| Variable | Default |
| --- | --- |
| `JS_YAML_VERSION` | `4.3.2` |
| `SWAGGER2OPENAPI_VERSION` | `7.0.8` |

## What counts as a change

Some APIs serve the same document in a different order on every request. Vainu
(drf-spectacular), measured across six downloads on 2026-11-15, moved the
members of an enum, that enum's description bullets, and the key order of
fourteen schemas' `properties`. A byte compare reported each run as drift.

So the "did it change" check and the spec diff (`.jdiff`) compare a canonical
copy of the new spec against a canonical copy of the baseline, in which:

- every object's keys are sorted (`jq -S`),
- every `enum` whose members are all scalars is sorted, and
- a description made only of `` * `CODE` - label `` bullets, one per enum member
  and naming exactly that enum's members, is put in the same order.

None of these carries meaning in JSON, OpenAPI or JSON Schema. An enum holding
an object or an array is left as served, and no other array moves, so adding
or removing an enum member, a property, or a label is still reported.

The canonical copies are temporary. What the script **writes** — the baseline
spec, the `.d.ts`, the endpoint and operation lists — still comes from the spec
as downloaded, so upgrading changes no committed file by itself. The `.jdiff`
header names the temporary `*.canonical.json` files it compared.

## Behaviour on failure

If any step fails for an endpoint — a missing variable, a failed download, an
empty or invalid spec, a failed YAML or Swagger 2 conversion, a failed
canonical copy, or a failed `openapi-typescript` run — that endpoint is skipped and its checked-in files are
left untouched. Previously the script could carry on, move the freshly
downloaded spec into place next to the **stale** `.d.ts`, and report
`All APIs processed!` — leaving the artifacts inconsistent while claiming
success.

A run that skipped any endpoint now ends with

```
Failed: <n> API(s) skipped on an error: <ids>
```

and **exits 1**, so a caller can tell a skip from "no changes".

## Output
For each API `id`, the script creates a folder and maintains current artifacts:
- `id/id-swagger.json` (latest normalized spec)
- `id/id.d.ts` (latest TypeScript types)
- `id/endpoints.txt` (latest paths)
- `id/operations.txt` (latest operations)

When changes are detected, it also writes timestamped diffs:
- `endpoints-diff-<timestamp>.txt`
- `operations-diff-<timestamp>.txt`
- `id-swagger-<timestamp>.json.jdiff` (between the canonical copies — see
  [What counts as a change](#what-counts-as-a-change))
- `id-<timestamp>.d.ts.diff`
