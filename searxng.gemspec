require_relative "lib/searxng/version"

Gem::Specification.new do |spec|
  spec.name = "searxng"
  spec.version = Searxng::VERSION
  spec.authors = ["Andrei Makarov"]
  spec.email = ["andrei@kiskolabs.com"]

  spec.summary = "SearXNG Ruby client and MCP server"
  spec.description = "Ruby gem providing a SearXNG HTTP client, CLI (search), and MCP server for web search. Integrates with Cursor IDE via Model Context Protocol."
  spec.homepage = "https://github.com/amkisko/searxng.rb"
  spec.license = "MIT"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["lib/**/*", "sig/**/*", "bin/**/*", "README.md", "LICENSE*", "CHANGELOG.md"].select { |f| File.file?(f) }
  end
  spec.bindir = "bin"
  spec.executables = ["searxng"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "source_code_uri" => "https://github.com/amkisko/searxng.rb",
    "changelog_uri" => "https://github.com/amkisko/searxng.rb/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/amkisko/searxng.rb/issues",
    "documentation_uri" => "https://github.com/amkisko/searxng.rb#readme",
    "rubygems_mfa_required" => "true"
  }

  spec.add_runtime_dependency "fast-mcp", ">= 0.1", "< 2.0"
  spec.add_runtime_dependency "rack", "~> 3.0"
  spec.add_runtime_dependency "base64", "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "webmock", "~> 3.26"
  spec.add_development_dependency "vcr", "~> 6.0"
  spec.add_development_dependency "rake", "~> 13.3"
  spec.add_development_dependency "simplecov", "~> 0.22"
  spec.add_development_dependency "rspec_junit_formatter", "~> 0.6"
  spec.add_development_dependency "simplecov-cobertura", "~> 3.1"
  spec.add_development_dependency "standard", "~> 1.52"
  spec.add_development_dependency "standard-custom", "~> 1.0"
  spec.add_development_dependency "standard-performance", "~> 1.8"
  spec.add_development_dependency "standard-rspec", "~> 0.3"
  spec.add_development_dependency "rubocop-rspec", "~> 3.8"
  spec.add_development_dependency "rubocop-thread_safety", "~> 0.7"
  spec.add_development_dependency "appraisal", "~> 2.5"
  spec.add_development_dependency "memory_profiler", "~> 1.1"
  spec.add_development_dependency "rbs", "~> 3.9"
end
