import Config

# Ramal is a library: it holds no configuration of its own. The one setting below is for the root project's own
# compile in every environment (Ash refuses to compile a resource in the root project without it, so `MIX_ENV=dev
# mix docs` needs it too). Hosts set their own value; a dependency compile skips the check (Ash's
# RequireStringLengthCountConfig). Everything else is for the test suite.
config :ash, default_string_length_count: :codepoints

if config_env() == :test do
  import_config "test.exs"
end
