from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="", extra="ignore")

    defectdojo_url: str = "http://defectdojo-django.voc-core.svc.cluster.local"
    defectdojo_api_key: str = "changeme"
    defectdojo_verify_tls: bool = True

    # --- threat intelligence sources ---
    epss_api_url: str = "https://api.first.org/data/v1/epss"
    kev_enabled: bool = True
    kev_feed_url: str = (
        "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
    )
    kev_refresh_seconds: int = 86_400
    # Findings whose CVE is on the KEV list never score below this, whatever
    # the asset context says — someone is exploiting it right now.
    kev_priority_floor: int = 70

    # --- base score: how bad is the bug, is anyone using it ---
    cvss_weight: float = 0.5
    epss_weight: float = 0.5
    epss_high_threshold: float = 0.7

    # --- context: does it matter on THIS asset ---
    # Weights are relative and get normalised, so 0.4/0.4/0.2 just means
    # "exposure and business criticality matter equally, data classification
    # about half as much".
    asset_inventory_path: str = "/config/asset-inventory.yaml"
    exposure_weight: float = 0.4
    criticality_weight: float = 0.4
    data_weight: float = 0.2
    # The multiplier applied to the base score. The spread is what lets a
    # MEDIUM on an internet-facing crown jewel outrank a HIGH on a throwaway
    # internal box; narrow it toward 1.0 to make context advisory instead.
    context_min_multiplier: float = 0.65
    context_max_multiplier: float = 1.6

    # Write the score breakdown into the finding's description in DefectDojo.
    # Off by default: it is verbose, and the tags + risk score usually suffice.
    write_explanation: bool = False

    run_scheduler: bool = True
    scoring_interval_seconds: int = 3600

    log_level: str = "INFO"


settings = Settings()
