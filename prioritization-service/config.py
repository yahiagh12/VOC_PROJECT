from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="", extra="ignore")

    defectdojo_url: str = "http://defectdojo-django.voc-core.svc.cluster.local"
    defectdojo_api_key: str = "changeme"
    defectdojo_verify_tls: bool = True

    epss_api_url: str = "https://api.first.org/data/v1/epss"

    cvss_weight: float = 0.5
    epss_weight: float = 0.5
    epss_high_threshold: float = 0.7

    run_scheduler: bool = False
    scoring_interval_seconds: int = 3600

    log_level: str = "INFO"


settings = Settings()
