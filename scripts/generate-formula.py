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
    names = " ".join(
        lib["name"] for lib in libraries if lib["name"] != "idris2-ilex"
    )
    return (
        f"    %w[{names}].each do |lib_name|\n"
        '      resource(lib_name).stage do\n'
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
