polyrun_cov_measure =
  ENV["POLYRUN_COVERAGE_DISABLE"] != "1" &&
  %w[1 true yes].include?(ENV["POLYRUN_COVERAGE"]&.to_s&.downcase)

if polyrun_cov_measure
  require "coverage"
  branch = %w[1 true yes].include?(ENV["POLYRUN_COVERAGE_BRANCHES"]&.to_s&.downcase)
  ::Coverage.start(lines: true, branches: branch)
end

if polyrun_cov_measure
  require "polyrun/coverage/rails"
  Polyrun::Coverage::Rails.start!(root: File.expand_path("..", __dir__))
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
require "polyrun/rspec"
Polyrun::RSpec.install_sharded_formatter_compat!
Polyrun::RSpec.install_failure_fragments!
Polyrun::RSpec.install_worker_ping!
Polyrun::RSpec.install_example_debug!
Polyrun::RSpec.install_example_rails_logging!
Polyrun::RSpec.install_example_timeout!
if %w[1 true yes].include?(ENV["POLYRUN_SPEC_QUALITY"]&.to_s&.downcase)
  Polyrun::RSpec.install_spec_quality!
end
