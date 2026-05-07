#!/usr/bin/env python3
"""4lm_helpers — Python helper commands for the 4lm bash script."""

__version__ = "0.1.0"

import argparse
import sys


def cmd_hello(args: argparse.Namespace) -> int:
    print("hello from 4lm_helpers")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="4lm_helpers",
        description="Python helper commands for 4lm",
    )
    parser.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("hello", help="smoke-test command")

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if args.command == "hello":
        return cmd_hello(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
