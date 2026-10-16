#!/bin/bash
# Format only the explicit M1 foundation and critical state scope, never a recursive source tree.
set -euo pipefail

task_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
task_mode="${1:---check}"
case "$task_mode" in
    --check|--fix|--list) ;;
    *) echo "Usage: $0 [--check|--fix|--list]" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--check|--fix|--list]" >&2
    exit 2
fi

task_audit="$task_root/scripts/check-foundation-boundaries.py"
if [[ "$task_mode" == --list ]]; then
    exec python3 "$task_audit" --format-list
fi
python3 "$task_audit"

task_files=()
while IFS= read -r task_file; do
    task_files+=("$task_file")
done < <(python3 "$task_audit" --format-list)

if [[ -n "${SWIFT_FORMAT_BIN:-}" ]]; then
    task_formatter=("$SWIFT_FORMAT_BIN")
elif command -v xcrun >/dev/null 2>&1; then
    task_formatter=(xcrun swift-format)
elif command -v swift-format >/dev/null 2>&1; then
    task_formatter=(swift-format)
else
    echo "swift-format is required; install the Swift toolchain or set SWIFT_FORMAT_BIN." >&2
    exit 2
fi
if [[ "$task_mode" == --fix ]]; then
    "${task_formatter[@]}" format --configuration "$task_root/.swift-format" --in-place "${task_files[@]}"
else
    "${task_formatter[@]}" lint --strict --configuration "$task_root/.swift-format" "${task_files[@]}"
fi
