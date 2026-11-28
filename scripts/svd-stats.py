#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

from lxml import etree


XPATHS = {
    "writeConstraint": "//*[local-name()='writeConstraint']",
    "isDefault": "//*[local-name()='enumeratedValue']/*[local-name()='isDefault']",
    "enumeratedValue_dont_care": (
        "//*[local-name()='enumeratedValue']"
        "/*[local-name()='value']"
        "[contains(translate(., 'X', 'x'), 'x')]"
    ),
}


def analyze_svd(path: Path) -> dict:
    parser = etree.XMLParser(
        resolve_entities=False,
        no_network=True,
        recover=True,
        huge_tree=True,
    )

    try:
        tree = etree.parse(str(path), parser)

        counts = {
            name: len(tree.xpath(expr))
            for name, expr in XPATHS.items()
        }

        return {
            "file": str(path),
            "status": "ok",
            **counts,
        }

    except (etree.XMLSyntaxError, OSError) as exc:
        return {
            "file": str(path),
            "status": "error",
            "error": str(exc),
            **{name: None for name in XPATHS},
        }


def main():
    arg_parser = argparse.ArgumentParser(
        description="Count selected CMSIS-SVD elements recursively."
    )
    arg_parser.add_argument("directory", type=Path)
    arg_parser.add_argument(
        "-o", "--output",
        type=Path,
        default=None,
        help="Output JSONL file (default: stdout).",
    )

    args = arg_parser.parse_args()

    output = args.output.open("w", encoding="utf-8") if args.output else None

    try:
        import sys
        stream = output or sys.stdout

        for path in sorted(args.directory.rglob("*")):
            if path.is_file() and path.suffix.lower() == ".svd":
                result = analyze_svd(path)
                print(json.dumps(result), file=stream)

    finally:
        if output:
            output.close()


if __name__ == "__main__":
    main()

