from functools import lru_cache

from supabase import Client, create_client

from .config import get_settings


def _required(value: str, label: str) -> str:
    if not value:
        raise RuntimeError(f"Missing {label}. Copy .env.example to .env and configure it.")
    return value


@lru_cache
def get_service_client() -> Client:
    settings = get_settings()
    return create_client(
        _required(settings.supabase_url, "SUPABASE_URL"),
        _required(settings.supabase_service_role_key, "SUPABASE_SERVICE_ROLE_KEY"),
    )


def get_auth_client() -> Client:
    """Return a per-request public client so auth sessions are never shared."""
    settings = get_settings()
    return create_client(
        _required(settings.supabase_url, "SUPABASE_URL"),
        _required(settings.supabase_publishable_key, "SUPABASE_PUBLISHABLE_KEY"),
    )
