#!/usr/bin/env python3
"""Generate a Homebrew formula from a template and resolved resource data.

Usage:
    python generate-formula.py \\
        --template Formula/idris2-pack.rb.template \\
        --resources resources.json \\
        --version 2026.04.03 \\
        --output Formula/idris2-pack.rb
"""

import argparse
import json
import sys


def build_resource_blocks(libraries: list[dict]) -> str:
    """Generate Ruby resource blocks for all libraries."""
    blocks = []
    for lib in libraries:
        block = (
            f'  resource "{lib["name"]}" do\n'
            f'    url "{lib["url"]}"\n'
            f'    sha256 "{lib["sha256"]}"\n'
            f"  end"
        )
        blocks.append(block)
    return "\n\n".join(blocks)


def build_library_install_loop(libraries: list[dict]) -> str:
    """Generate the Ruby loop that installs simple (non-ilex) libraries."""
    # ilex is handled separately in the template due to sub-package structure
    names = [lib["name"] for lib in libraries if lib["name"] != "idris2-ilex"]

    # Wrap the %w[] array to stay within Homebrew's 118-char line limit.
    # Continuation lines align after "%w[" (7 spaces of indent).
    prefix = "    %w["
    suffix = "].each do |lib_name|"
    continuation_indent = " " * len(prefix)
    max_line_len = 118

    lines = []
    current_line = prefix
    for i, name in enumerate(names):
        candidate = current_line + name
        # Check if adding suffix (for last name) or next name would exceed limit
        if i == len(names) - 1:
            # Last name: must fit with suffix
            if len(candidate + suffix) <= max_line_len:
                lines.append(candidate + suffix)
            else:
                lines.append(current_line.rstrip())
                lines.append(continuation_indent + name + suffix)
        else:
            # Not last: check if next name would still fit on this line
            if len(candidate + " ") <= max_line_len:
                current_line = candidate + " "
            else:
                lines.append(current_line.rstrip())
                current_line = continuation_indent + name + " "

    array_line = "\n".join(lines)
    return (
        f"{array_line}\n"
        "      resource(lib_name).stage do\n"
        '        Dir.glob("*.ipkg").each do |ipkg|\n'
        '          system idris2_bin, "--install", ipkg\n'
        "        end\n"
        "      end\n"
        "    end"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate Homebrew formula")
    parser.add_argument("--template", required=True, help="Path to formula template")
    parser.add_argument("--resources", required=True, help="Path to resources.json")
    parser.add_argument("--version", required=True, help="Formula version")
    parser.add_argument("--output", required=True, help="Output formula path")
    args = parser.parse_args()

    with open(args.resources) as f:
        resources = json.load(f)

    with open(args.template) as f:
        template = f.read()

    pack = resources["pack"]
    idris2 = resources["idris2"]
    libraries = resources["libraries"]

    formula = template
    formula = formula.replace("{{VERSION}}", args.version)
    formula = formula.replace("{{PACK_COMMIT}}", pack["commit"])
    formula = formula.replace("{{PACK_SHA256}}", pack["sha256"])
    formula = formula.replace("{{IDRIS2_COMMIT}}", idris2["commit"])
    formula = formula.replace("{{IDRIS2_SHA256}}", idris2["sha256"])
    formula = formula.replace("{{RESOURCE_BLOCKS}}", build_resource_blocks(libraries))
    formula = formula.replace(
        "{{LIBRARY_INSTALL_LOOP}}", build_library_install_loop(libraries)
    )

    with open(args.output, "w") as f:
        f.write(formula)

    print(f"Formula written to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
