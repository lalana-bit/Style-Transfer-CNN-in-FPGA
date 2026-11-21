"""Run this style using the repository's shared IN15 reference."""
from pathlib import Path
import sys

PACKAGE = Path(__file__).resolve().parent
sys.path.insert(0, str(PACKAGE.parents[1] / 'common'))

from model_codec16_std_two_upfirst.verify_package import main


if __name__ == '__main__':
    main(PACKAGE)
