#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["ruamel.yaml"]
# ///
"""
Reset all verification statuses to pending and clear notes.

Usage: uv run reset-verification.py [--dry-run] [--skip-verify]

Options:
  --dry-run      Show what would be changed without modifying the file
  --skip-verify  Skip running verify-protocol-coverage.py after reset
"""

import subprocess
import sys
from pathlib import Path

# Add parent directory to path for lib imports
sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.yaml_utils import create_yaml


def reset_verification(data: dict, dry_run: bool = False) -> int:
    """Reset all verification blocks. Returns count of items reset."""
    count = 0

    def reset_block(v: dict, location: str) -> bool:
        """Reset a single verification block. Returns True if changed."""
        changed = False
        if v.get("status") != "pending":
            if dry_run:
                print(f"  {location}: {v.get('status')} -> pending")
            v["status"] = "pending"
            changed = True
        if v.get("notes", "") != "":
            if dry_run and not changed:
                print(f"  {location}: clearing notes")
            v["notes"] = ""
            changed = True
        return changed

    # Reset modules
    for module in data.get("modules", []):
        module_id = module.get("id", "unknown")

        # Module-level verification
        if v := module.get("verification"):
            if reset_block(v, f"module: {module_id}"):
                count += 1

        # Methods
        for method in module.get("methods", []):
            if v := method.get("verification"):
                name = method.get("swift", method.get("name"))
                if reset_block(v, f"{module_id} > {name}"):
                    count += 1

        # Notifications
        for notif in module.get("notifications", []):
            if v := notif.get("verification"):
                name = notif.get("swift", notif.get("name"))
                if reset_block(v, f"{module_id} > {name}"):
                    count += 1

    # Reset types
    for type_name, type_info in data.get("types", {}).items():
        if isinstance(type_info, dict) and (v := type_info.get("verification")):
            if reset_block(v, f"type: {type_name}"):
                count += 1

    return count


def run_verification(scripts_dir: Path) -> bool:
    """Run verify-protocol-coverage.py and return True if it passes."""
    verify_script = scripts_dir / "verify-protocol-coverage.py"
    print("\nRunning protocol coverage verification...")
    result = subprocess.run(
        ["uv", "run", str(verify_script), "--skip-clone"],
        cwd=scripts_dir.parent,  # Run from verification/ directory
    )
    return result.returncode == 0


def main():
    dry_run = "--dry-run" in sys.argv
    skip_verify = "--skip-verify" in sys.argv

    script_dir = Path(__file__).parent
    manifest_path = script_dir.parent.parent / "manifest.yaml"

    yaml = create_yaml()

    with open(manifest_path) as f:
        data = yaml.load(f)

    if dry_run:
        print("Dry run - showing changes:\n")

    count = reset_verification(data, dry_run)

    if dry_run:
        if count == 0:
            print("No changes needed.")
        else:
            print(f"\nWould reset {count} items.")
    else:
        with open(manifest_path, "w") as f:
            yaml.dump(data, f)
        print(f"Reset {count} items and formatted manifest.")

        if not skip_verify:
            if not run_verification(script_dir.parent):  # Pass scripts/ directory
                print("\n⚠ Verification failed - manifest may have issues from previous pass")
                sys.exit(1)
            print("\n✓ Verification passed")


if __name__ == "__main__":
    main()
