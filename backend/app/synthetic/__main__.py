"""Run with python -m app.synthetic generate from backend/."""
import argparse
from pathlib import Path

from pydantic import ValidationError

from app.synthetic.models import GenerationConfig
from app.synthetic.writer import build_artifacts, write_artifacts


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate the Homeostat synthetic demo and fixed golden corpus.")
    commands = parser.add_subparsers(dest="command", required=True)
    generate = commands.add_parser("generate")
    generate.add_argument("--seed", type=int, default=20260923)
    generate.add_argument("--start-date", default="2026-08-14", help="First demo local day; golden dates stay fixed.")
    generate.add_argument("--days", type=int, default=40)
    generate.add_argument("--timezone", default="America/Chicago", help="Demo timezone; golden zones stay fixed.")
    generate.add_argument("--output", type=Path, default=Path("../data/synthetic"))
    args = parser.parse_args()
    try:
        config = GenerationConfig(seed=args.seed, start_date=args.start_date, days=args.days, timezone=args.timezone)
        artifacts = build_artifacts(config)
        write_artifacts(args.output, artifacts)
    except (ValidationError, ValueError, OSError) as error:
        parser.error(str(error))
    print(f"Generated {len(artifacts)} files in {args.output.resolve()}")


if __name__ == "__main__":
    main()
