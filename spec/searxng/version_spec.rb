require "spec_helper"

RSpec.describe Searxng do
  it "loads version file" do
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    load File.expand_path("../../lib/searxng/version.rb", __dir__)
    $VERBOSE = previous_verbose
    expect(defined?(Searxng::VERSION)).to eq("constant")
  ensure
    $VERBOSE = previous_verbose
  end

  it "has a version constant" do
    expect(Searxng::VERSION).to be_a(String)
    expect(Searxng::VERSION).not_to be_empty
  end
end
