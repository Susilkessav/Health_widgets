"""python -m app.features calculate --dataset DIR --checkpoint ID [--config PATH] [--output PATH]"""
import argparse
import sys
from pathlib import Path

from pydantic import ValidationError

from app.config import DEFAULT_PATH, load_settings
from app.features.synthetic import calculate_checkpoint, load_dataset
from app.synthetic.writer import json_bytes


def main() -> None:
    parser = argparse.ArgumentParser(description="Calculate DailyFeatures for one synthetic dataset checkpoint.")
    commands = parser.add_subparsers(dest="command", required=True)
    calculate = commands.add_parser("calculate")
    calculate.add_argument("--dataset", type=Path, required=True)
    calculate.add_argument("--checkpoint", required=True)
    calculate.add_argument("--config", type=Path, default=DEFAULT_PATH)
    calculate.add_argument("--output", type=Path, help="Write here instead of stdout.")
    args = parser.parse_args()
    try:
        report = calculate_checkpoint(load_dataset(args.dataset), args.checkpoint, load_settings(args.config))
    except (ValidationError, ValueError, OSError) as error:
        parser.error(str(error))
    data = json_bytes(report)
    if args.output:
        args.output.write_bytes(data)
    else:
        sys.stdout.buffer.write(data)


if __name__ == "__main__":
    main()
