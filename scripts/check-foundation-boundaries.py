#!/usr/bin/env python3
"""Audit the explicit M1 foundation scope without loading Swift or AppKit."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


FOUNDATION_FILES = (
    "Sources/MacVisio/DocumentChanges.swift",
    "Sources/MacVisio/PageRuntime.swift",
    "Sources/MacVisio/CalculationDependencies.swift",
    "Sources/MacVisio/ShapeSheetExpressionCache.swift",
    "Sources/MacVisioInfrastructure/LifecycleJobs.swift",
    "Sources/MacVisioInfrastructure/ResourceBudget.swift",
    "Sources/MacVisioInfrastructure/AtomicJobOutput.swift",
    "Sources/MacVisio/UndoPayloadBudget.swift",
    "Sources/MacVisio/ViewportCoordinates.swift",
)
# UI/document state paths are formatted, but are deliberately excluded from the
# Foundation import audit because they own AppKit coordination.
STATE_FORMAT_FILES = (
    "Sources/MacVisio/Document.swift",
    "Sources/MacVisio/DocumentSourceVersion.swift",
    "Sources/MacVisio/CanvasView.swift",
    "Sources/MacVisio/RetainedScene.swift",
    "Sources/MacVisio/CalculationJobs.swift",
    "Sources/MacVisio/DiagramCalculation.swift",
    "Sources/MacVisio/DiagramOperations.swift",
    "Sources/MacVisio/ControlEditing.swift",
    "Sources/MacVisio/DeveloperCommands.swift",
    "Sources/MacVisio/ExportJobs.swift",
    "Sources/MacVisio/LegacyConverterProcess.swift",
    "Sources/MacVisio/LifecycleJobOwner.swift",
    "Sources/MacVisio/LifecycleProgress.swift",
    "Sources/MacVisio/ShapeTextMeasurementService.swift",
    "Sources/MacVisio/EditorAppearance.swift",
    "Sources/MacVisio/BenchmarkProfile.swift",
)
COMMON_IMPORTS = frozenset({"Foundation", "CoreGraphics"})
EXTRA_IMPORTS = {
    "AtomicJobOutput.swift": frozenset({"Darwin"}),
    "UndoPayloadBudget.swift": frozenset({"MacVisioInfrastructure"}),
}
IMPORT = re.compile(
    r"\bimport\s+(?:(?:class|struct|enum|protocol|var|let|func|typealias)\s+)?"
    r"([A-Za-z_][A-Za-z_0-9]*)"
)


def mask_comments_and_strings(source: str) -> str:
    """Keep line positions while hiding nested comments and Swift string bodies.

    This is an import-token guard, not a Swift parser or transitive type checker.
    Both branches of conditional compilation remain visible to the audit.
    """
    result = list(source)
    index, size = 0, len(source)

    def mask(start: int, end: int) -> None:
        for offset in range(start, end):
            if source[offset] != "\n":
                result[offset] = " "

    while index < size:
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = size if end < 0 else end
            mask(index, end)
            index = end
        elif source.startswith("/*", index):
            start, depth = index, 1
            index += 2
            while index < size and depth:
                if source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            mask(start, index)
        else:
            start, quote = index, index
            while quote < size and source[quote] == "#":
                quote += 1
            if quote < size and source[quote] == '"':
                hashes = source[start:quote]
                quotes = '"""' if source.startswith('"""', quote) else '"'
                closing = quotes + hashes
                index = quote + len(quotes)
                while index < size:
                    if source.startswith("\\" + hashes, index):
                        index = min(size, index + len(hashes) + 2)
                    elif source.startswith(closing, index):
                        index += len(closing)
                        break
                    else:
                        index += 1
                mask(start, index)
            else:
                index += 1
    return "".join(result)


def imports(source: str) -> list[tuple[str, int]]:
    masked = mask_comments_and_strings(source)
    return [(match.group(1), masked.count("\n", 0, match.start()) + 1) for match in IMPORT.finditer(masked)]


def foundation_paths(root: Path) -> list[Path]:
    return [root / relative for relative in FOUNDATION_FILES]


def audit(root: Path) -> list[str]:
    errors = []
    for path in foundation_paths(root):
        relative = path.relative_to(root)
        if not path.is_file():
            errors.append(f"{relative}: missing foundation source")
            continue
        allowed = COMMON_IMPORTS | EXTRA_IMPORTS.get(path.name, frozenset())
        for module, line in imports(path.read_text(encoding="utf-8")):
            if module not in allowed:
                errors.append(
                    f"{relative}:{line}: prohibited import {module}; allowed: {', '.join(sorted(allowed))}"
                )
    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--list", action="store_true", help="Print the exact Foundation import-audit scope.")
    parser.add_argument("--format-list", action="store_true", help="Print foundation plus critical state formatter scope.")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if args.format_list:
        print("\n".join(str(root / path) for path in FOUNDATION_FILES + STATE_FORMAT_FILES))
        return 0
    if args.list:
        print("\n".join(str(path) for path in foundation_paths(root)))
        return 0
    errors = audit(root)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Foundation import boundary passed for {len(FOUNDATION_FILES)} files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
