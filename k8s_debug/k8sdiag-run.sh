#!/usr/bin/env bash
# k8sdiag-run.sh — source-based wrapper for the Claude k8s-diagnostics skill

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
GO_MAIN="./cmd/k8sdiag"

CLUSTER=""
NAMESPACE=""
OUTPUT="text"
TIMEOUT="90s"
NO_COLOR=""
SKIP=""
KUBECONFIG_PATH=""
KUBE_CONTEXT=""
SECTION="all"
REPORT_FILE=""
APPEND_REPORT="false"
REPORT_TITLE=""

ALL_CATEGORIES=(
  "Pods"
  "Nodes"
  "Storage"
  "Network"
  "Services"
  "Calico"
  "DNS"
  "Affinity/Scheduling"
  "Events"
  "Resources/Quotas"
  "RBAC"
  "Config/Secrets"
  "Namespace"
  "Ingress"
)

usage() {
  cat <<'EOF'
Usage:
  ./k8sdiag-run.sh --cluster <name> [options]

Options:
  --namespace, -n     Scope diagnostics to one namespace
  --output, -o        text | json | markdown (default: text)
  --timeout           Global timeout (default: 90s)
  --no-color          Disable ANSI color output
  --skip              Extra categories to skip
  --context           Override kube context
  --kubeconfig        Override kubeconfig path
  --section           all | pods | nodes | storage | network | affinity | events | resources
  --report-file       Append each section run to a markdown report file
  --append-report     Append to report file instead of replacing it
  --report-title      Title used when the report file is initialized
EOF
}

join_by_comma() {
  local out=""
  local item
  for item in "$@"; do
    if [[ -z "$out" ]]; then
      out="$item"
    else
      out="$out,$item"
    fi
  done
  printf '%s' "$out"
}

section_keep_categories() {
  case "$1" in
    all) printf '%s\n' "${ALL_CATEGORIES[@]}" ;;
    pods) printf '%s\n' "Pods" ;;
    nodes) printf '%s\n' "Nodes" ;;
    storage) printf '%s\n' "Storage" ;;
    network) printf '%s\n' "Network" "Services" "Calico" "DNS" ;;
    affinity) printf '%s\n' "Affinity/Scheduling" ;;
    events) printf '%s\n' "Events" ;;
    resources) printf '%s\n' "Resources/Quotas" "RBAC" "Config/Secrets" "Namespace" "Ingress" ;;
    *)
      echo "ERROR: unknown --section value: $1" >&2
      exit 1
      ;;
  esac
}

build_section_skip() {
  local section="$1"
  if [[ "$section" == "all" ]]; then
    printf '%s' "$SKIP"
    return
  fi

  mapfile -t keep < <(section_keep_categories "$section")
  local skips=()
  local category
  local allowed
  for category in "${ALL_CATEGORIES[@]}"; do
    allowed="false"
    for allowed_category in "${keep[@]}"; do
      if [[ "$category" == "$allowed_category" ]]; then
        allowed="true"
        break
      fi
    done
    if [[ "$allowed" == "false" ]]; then
      skips+=("$category")
    fi
  done

  if [[ -n "$SKIP" ]]; then
    skips+=("$SKIP")
  fi

  join_by_comma "${skips[@]}"
}

section_label() {
  case "$1" in
    all) printf 'Full Cluster Diagnostic' ;;
    pods) printf 'Pods' ;;
    nodes) printf 'Nodes' ;;
    storage) printf 'Storage' ;;
    network) printf 'Network' ;;
    affinity) printf 'Affinity and Scheduling' ;;
    events) printf 'Events' ;;
    resources) printf 'Resources, RBAC, Config, Ingress, Namespace' ;;
  esac
}

strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*[[:alpha:]]//g'
}

append_report() {
  local section="$1"
  local exit_code="$2"
  local output="$3"
  local label
  label="$(section_label "$section")"

  if [[ "$APPEND_REPORT" != "true" || ! -f "$REPORT_FILE" ]]; then
    cat >"$REPORT_FILE" <<EOF
# ${REPORT_TITLE:-k8sdiag Report}

- Cluster: \`$CLUSTER\`
- Namespace: \`${NAMESPACE:-all namespaces}\`
- Generated: \`$(date -u +"%Y-%m-%dT%H:%M:%SZ")\`

EOF
  fi

  {
    printf '## %s\n\n' "$label"
    printf -- '- Section key: `%s`\n' "$section"
    printf -- '- Exit code: `%s`\n' "$exit_code"
    printf -- '- Output format: `%s`\n\n' "$OUTPUT"

    if [[ "$OUTPUT" == "markdown" ]]; then
      printf '%s\n' "$output"
    else
      printf '```text\n%s\n```\n' "$(printf '%s' "$output" | strip_ansi)"
    fi
    printf '\n'
  } >>"$REPORT_FILE"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster|-c)     CLUSTER="$2"; shift 2 ;;
    --namespace|-n)   NAMESPACE="$2"; shift 2 ;;
    --output|-o)      OUTPUT="$2"; shift 2 ;;
    --timeout)        TIMEOUT="$2"; shift 2 ;;
    --no-color)       NO_COLOR="--no-color"; shift ;;
    --skip)           SKIP="$2"; shift 2 ;;
    --kubeconfig)     KUBECONFIG_PATH="$2"; shift 2 ;;
    --context)        KUBE_CONTEXT="$2"; shift 2 ;;
    --section)        SECTION="$2"; shift 2 ;;
    --report-file)    REPORT_FILE="$2"; shift 2 ;;
    --append-report)  APPEND_REPORT="true"; shift ;;
    --report-title)   REPORT_TITLE="$2"; shift 2 ;;
    --help|-h)        usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$CLUSTER" ]]; then
  echo "ERROR: --cluster is required" >&2
  exit 1
fi

if [[ ! -f "$PROJECT_DIR/go.mod" ]]; then
  echo "ERROR: go.mod not found in $PROJECT_DIR" >&2
  exit 1
fi

SECTION_SKIP="$(build_section_skip "$SECTION")"
CMD=(go run "$GO_MAIN" "--cluster" "$CLUSTER" "--output" "$OUTPUT" "--timeout" "$TIMEOUT")

[[ -n "$NAMESPACE" ]]       && CMD+=("--namespace" "$NAMESPACE")
[[ -n "$NO_COLOR" ]]        && CMD+=("--no-color")
[[ -n "$SECTION_SKIP" ]]    && CMD+=("--skip" "$SECTION_SKIP")
[[ -n "$KUBECONFIG_PATH" ]] && CMD+=("--kubeconfig" "$KUBECONFIG_PATH")
[[ -n "$KUBE_CONTEXT" ]]    && CMD+=("--context" "$KUBE_CONTEXT")

if [[ -t 1 && -z "$NO_COLOR" ]]; then
  printf '\033[1;36m==> %s\033[0m\n' "$(section_label "$SECTION")"
fi

if [[ -n "$REPORT_FILE" ]]; then
  set +e
  OUTPUT_TEXT="$(cd "$PROJECT_DIR" && GOCACHE="${GOCACHE:-/tmp/k8sdiag-go-cache}" "${CMD[@]}" 2>&1)"
  EXIT_CODE=$?
  set -e
  printf '%s\n' "$OUTPUT_TEXT"
  append_report "$SECTION" "$EXIT_CODE" "$OUTPUT_TEXT"
  exit "$EXIT_CODE"
fi

cd "$PROJECT_DIR" && GOCACHE="${GOCACHE:-/tmp/k8sdiag-go-cache}" "${CMD[@]}"
