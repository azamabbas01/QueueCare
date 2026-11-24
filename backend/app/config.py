from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    supabase_url: str = ""
    supabase_publishable_key: str = ""
    supabase_service_role_key: str = ""
    auth_confirmation_url: str = "http://127.0.0.1:8000/auth/confirm"
    cors_origins: str = "http://localhost:3000,http://localhost:8080"
    api_prefix: str = "/api/v1"
    clinic_timezone: str = "Asia/Karachi"
    # "production" disables the interactive docs and the localhost CORS allowance.
    environment: str = "development"
    default_country_code: str = "92"
    # Pepper for hashing national ID numbers (set a long random value in production).
    national_id_pepper: str = "change-me-in-production"
    # Optional SMS gateway (Twilio-compatible). Leave empty to keep messages queued.
    twilio_account_sid: str = ""
    twilio_auth_token: str = ""
    twilio_from_number: str = ""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    @property
    def allowed_origins(self) -> list[str]:
        return [origin.strip() for origin in self.cors_origins.split(",") if origin.strip()]

    @property
    def is_production(self) -> bool:
        return self.environment.strip().lower() == "production"


@lru_cache
def get_settings() -> Settings:
    return Settings()
