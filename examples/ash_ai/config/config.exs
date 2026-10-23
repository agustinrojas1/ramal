import Config

config :ramal_ash_ai_example, ash_domains: [RamalAshAiExample.Farm]

config :ash, :missed_notifications, :ignore
config :ash, default_string_length_count: :codepoints

config :logger, level: :warning
