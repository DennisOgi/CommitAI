import os
import sys
from pathlib import Path

for k in ("DAILY_API_KEY", "DAILY_DIALIN_HMAC", "CORS_ORIGINS", "OPENAI_API_KEY", "GEMINI_API_KEY", "AI_PROVIDER", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "FCM_PROJECT_ID"):
    os.environ[k] = ""
os.environ["DEV_AUTH"] = "true"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
