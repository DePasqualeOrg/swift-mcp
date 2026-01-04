"""
Shared output formatting for MCP verification tools.
"""

# ANSI color codes
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
CYAN = '\033[0;36m'
DIM = '\033[2m'
NC = '\033[0m'  # No color


def print_header(title: str):
    """Print a section header."""
    print(f"\n{CYAN}## {title}{NC}")
    print("-" * (len(title) + 3))
    print()


def print_ok(msg: str):
    """Print a success message with checkmark."""
    print(f"{GREEN}✓{NC} {msg}")


def print_error(msg: str):
    """Print an error/missing message."""
    print(f"{RED}MISSING:{NC} {msg}")


def print_warning(msg: str):
    """Print a warning message."""
    print(f"{YELLOW}⚠{NC} {msg}")


def print_dim(msg: str):
    """Print dimmed/secondary text."""
    print(f"{DIM}{msg}{NC}")


def print_add(msg: str):
    """Print an addition message (for sync operations)."""
    print(f"  + {msg}")
