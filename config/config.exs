import Config

# Ramal is a library: it holds no configuration of its own. Everything below is for its own test suite.
if config_env() == :test do
  import_config "test.exs"
end
