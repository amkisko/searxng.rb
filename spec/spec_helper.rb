require "simplecov"
require "simplecov-cobertura"

SimpleCov.start do
  minimum_coverage 90
  track_files "lib/**/*.rb"
  add_filter "/lib/tasks/"
  add_filter "spec/"
  add_filter "usr/"
  formatter SimpleCov::Formatter::MultiFormatter.new([
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter
  ])
end

require "rspec"
require "vcr"
require "webmock/rspec"
require_relative "../lib/searxng"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |f| require_relative f }

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.hook_into :webmock
  config.configure_rspec_metadata!
  config.allow_http_connections_when_no_cassette = false
  config.ignore_localhost = true

  record_mode = case ENV.fetch("VCR_RECORD", "once")
  when "all" then :all
  when "new_episodes", "new" then :new_episodes
  when "none" then :none
  else :once
  end

  config.default_cassette_options = {
    record: record_mode,
    match_requests_on: [:method, :uri],
    preserve_exact_body_bytes: true,
    decode_compressed_response: true
  }

  config.filter_sensitive_data("<SEARXNG_URL>") { ENV["SEARXNG_URL"] } if ENV["SEARXNG_URL"]
  config.filter_sensitive_data("<SEARXNG_USER>") { ENV["SEARXNG_USER"] } if ENV["SEARXNG_USER"]
  config.filter_sensitive_data("<SEARXNG_PASSWORD>") { ENV["SEARXNG_PASSWORD"] } if ENV["SEARXNG_PASSWORD"]
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

# Run coverage analyzer after SimpleCov finishes (optional)
if ENV["SHOW_ZERO_COVERAGE"] == "1"
  SimpleCov.at_exit do
    SimpleCov.result.format!
    require_relative "support/coverage_analyzer"
    CoverageAnalyzer.run
  end
end
