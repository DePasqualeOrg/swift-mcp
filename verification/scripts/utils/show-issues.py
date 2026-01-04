#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["ruamel.yaml"]
# ///
"""
Display verification issues and fixes from the manifest.

Usage: uv run show-issues.py [--status STATUS] [--module MODULE]

Options:
  --status STATUS  Filter by status (fixed, info, warning, critical, or "all")
  --module MODULE  Filter by module ID

Statuses:
  critical  - Definite problem, must fix
  warning   - Potential issue, should review
  info      - Minor observation
  fixed     - Agent made corrections

Examples:
  uv run show-issues.py                    # Show warning and critical
  uv run show-issues.py --status all       # Show all (including info and fixed)
  uv run show-issues.py --status fixed     # Show items that were fixed
  uv run show-issues.py --module tools     # Show issues in tools module
"""

import sys
from pathlib import Path
from dataclasses import dataclass

from ruamel.yaml import YAML


@dataclass
class Issue:
    location: str  # e.g., "tools > CallTool" or "types > Tool"
    status: str
    notes: str
    module_id: str


def load_manifest(path: Path) -> dict:
    yaml = YAML()
    with open(path) as f:
        return yaml.load(f)


def extract_issues(manifest: dict) -> list[Issue]:
    """Extract all noteworthy verification items (issues and fixes)."""
    issues = []
    noteworthy_statuses = {"fixed", "info", "warning", "critical"}

    def check_verification(v: dict, location: str, module_id: str):
        """Check a verification block and add to issues if noteworthy."""
        status = v.get("status")
        notes = v.get("notes", "").strip()

        if status in noteworthy_statuses:
            issues.append(Issue(location, status, notes, module_id))

    # Check modules
    for module in manifest.get("modules", []):
        module_id = module.get("id", "unknown")

        # Module-level verification
        if v := module.get("verification"):
            check_verification(v, f"module: {module_id}", module_id)

        # Methods
        for method in module.get("methods", []):
            if v := method.get("verification"):
                name = method.get("swift", method.get("name"))
                check_verification(v, f"{module_id} > {name}", module_id)

        # Notifications
        for notif in module.get("notifications", []):
            if v := notif.get("verification"):
                name = notif.get("swift", notif.get("name"))
                check_verification(v, f"{module_id} > {name}", module_id)

    # Check types
    for type_name, type_info in manifest.get("types", {}).items():
        if isinstance(type_info, dict) and (v := type_info.get("verification")):
            check_verification(v, f"type: {type_name}", "types")

    return issues


def format_issue(issue: Issue) -> str:
    """Format a single issue for display."""
    status_icons = {
        "fixed": "\033[32m✓\033[0m",     # green
        "info": "\033[36mℹ\033[0m",      # cyan
        "warning": "\033[33m⚠\033[0m",   # yellow
        "critical": "\033[31m✖\033[0m",  # red
    }
    icon = status_icons.get(issue.status, "?")

    lines = [f"{icon} [{issue.status.upper()}] {issue.location}"]

    if issue.notes:
        # Indent notes
        for line in issue.notes.strip().split("\n"):
            lines.append(f"  {line}")

    return "\n".join(lines)


def main():
    # Parse args
    args = sys.argv[1:]
    status_filter = None
    module_filter = None

    i = 0
    while i < len(args):
        if args[i] == "--status" and i + 1 < len(args):
            status_filter = args[i + 1]
            i += 2
        elif args[i] == "--module" and i + 1 < len(args):
            module_filter = args[i + 1]
            i += 2
        else:
            i += 1

    # Default: show warning and critical only
    if status_filter is None:
        show_statuses = {"warning", "critical"}
    elif status_filter == "all":
        show_statuses = {"critical", "warning", "info", "fixed"}
    else:
        show_statuses = {status_filter}

    # Load manifest
    script_dir = Path(__file__).parent
    manifest_path = script_dir.parent / "manifest.yaml"
    manifest = load_manifest(manifest_path)

    # Extract and filter issues
    issues = extract_issues(manifest)

    if module_filter:
        issues = [i for i in issues if i.module_id == module_filter]

    issues = [i for i in issues if i.status in show_statuses]

    # Display
    if not issues:
        print("No issues found.")
        return

    # Group by status for display
    by_status = {"critical": [], "warning": [], "info": [], "fixed": []}
    for issue in issues:
        by_status.get(issue.status, []).append(issue)

    total = len(issues)
    counts = {s: len(by_status[s]) for s in by_status if by_status[s]}
    count_str = ", ".join(f"{c} {s}" for s, c in counts.items())
    print(f"Found {total} items ({count_str})\n")

    # Print in order: issues by severity, then fixes
    for status in ["critical", "warning", "info", "fixed"]:
        for issue in by_status[status]:
            print(format_issue(issue))
            print()


if __name__ == "__main__":
    main()
