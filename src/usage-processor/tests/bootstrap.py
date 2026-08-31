from pathlib import Path
import sys


PROCESSOR_ROOT = Path(__file__).resolve().parents[1]
if str(PROCESSOR_ROOT) not in sys.path:
    sys.path.insert(0, str(PROCESSOR_ROOT))
