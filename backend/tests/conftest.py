import os
import sys
from pathlib import Path

os.environ.setdefault("SUPABASE_URL", "http://supabase.test")
os.environ.setdefault("SUPABASE_PUBLISHABLE_KEY", "publishable")
os.environ.setdefault("SUPABASE_SERVICE_ROLE_KEY", "service")
sys.path.insert(0, str(Path(__file__).parents[1]))
