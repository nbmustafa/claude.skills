# k8sdiag

A Kubernetes diagnostic tool written in Go, packaged here as a Claude skill
workspace. The code now follows the intended `cmd/` plus `internal/` layout,
and the Claude integration calls the local wrapper script instead of requiring
an installed binary.

## Repository Structure

```text
k8sdiag/
├── cmd/
│   └── k8sdiag/
│       └── main.go
├── internal/
│   ├── checker/
│   │   ├── affinity.go
│   │   ├── events.go
│   │   ├── network.go
│   │   ├── nodes.go
│   │   ├── pods.go
│   │   ├── resources.go
│   │   └── storage.go
│   ├── config/
│   │   └── client.go
│   ├── reporter/
│   │   └── reporter.go
│   └── types/
│       └── types.go
├── Dockerfile
├── Makefile
├── README.md
├── SKILL.md
├── coverage.md
├── go.mod
└── k8sdiag-run.sh
```

## How Claude Should Run It

Use the wrapper script, not the installed binary:

```bash
./k8sdiag-run.sh --cluster prod-cluster --output text
```

The script runs the local source with:

```bash
go run ./cmd/k8sdiag
```

That keeps the skill self-contained and avoids depending on a separate
`k8sdiag` installation.

## Incremental Sectioned Reports

To keep responses smaller and let Claude append to a report after each step, the
wrapper supports `--section`:

- `pods`
- `nodes`
- `storage`
- `network`
- `affinity`
- `events`
- `resources`

Example first section:

```bash
./k8sdiag-run.sh \
  --cluster prod-cluster \
  --section pods \
  --output markdown \
  --report-file /tmp/k8sdiag-prod-cluster-report.md \
  --report-title "k8sdiag report for prod-cluster"
```

Append later sections:

```bash
./k8sdiag-run.sh \
  --cluster prod-cluster \
  --section network \
  --output markdown \
  --report-file /tmp/k8sdiag-prod-cluster-report.md \
  --append-report
```

The script maps each section to the relevant checker categories and appends a
markdown block for that section to the report file. In `text` mode it also
prints a colored section banner before streaming the tool output.

## Common Commands

Build:

```bash
make build
```

Run all checks:

```bash
./k8sdiag-run.sh --cluster prod-cluster --output text
```

Run one section:

```bash
./k8sdiag-run.sh --cluster prod-cluster --section storage --output text
```

## Notes

- Exit code `0` means no findings.
- Exit code `1` means warnings only.
- Exit code `2` means critical findings are present.
- The skill should treat `1` and `2` as valid diagnostic results.
