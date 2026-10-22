import Config

config :ramal_live, RamalLive.Test.Endpoint,
  secret_key_base: String.duplicate("ramal-live-test-", 5),
  live_view: [signing_salt: "ramal-live-test"],
  server: false

# The test domain (test/support) runs on the ETS data layer, so no database is needed.
config :ramal_live, ash_domains: [RamalLive.Test.Farm]

config :ash, :missed_notifications, :ignore
# Required since Ash 3.37; codepoints is the value Ash recommends and matches how Postgres counts.
config :ash, default_string_length_count: :codepoints

config :logger, level: :warning
