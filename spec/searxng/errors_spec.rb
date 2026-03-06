require "spec_helper"
require "socket"

RSpec.describe Searxng::ErrorMessages do
  describe ".network_error" do
    let(:uri) { URI.parse("https://example.com/search") }

    it "formats socket errors as DNS errors" do
      msg = described_class.network_error(SocketError.new("not found"), uri: uri)
      expect(msg).to include("DNS Error")
    end

    it "formats refused connection and timeout errors" do
      expect(described_class.network_error(Errno::ECONNREFUSED.new, uri: uri)).to include("Connection Error")
      expect(described_class.network_error(Timeout::Error.new("timeout"), uri: uri)).to include("Timeout Error")
    end

    it "formats ssl and generic errors" do
      ssl_msg = described_class.network_error(OpenSSL::SSL::SSLError.new("cert"), uri: uri)
      generic_msg = described_class.network_error(StandardError.new("boom"), uri: uri)
      expect(ssl_msg).to include("SSL Error")
      expect(generic_msg).to include("Network Error")
    end
  end

  describe ".api_error" do
    it "formats known status codes and fallback message" do
      expect(described_class.api_error(403, "Forbidden")).to include("Authentication required")
      expect(described_class.api_error(429, "Too Many Requests")).to include("Rate limit exceeded")
      expect(described_class.api_error(500, "Server Error")).to include("Internal server error")
      expect(described_class.api_error(418, "I'm a teapot")).to include("418")
    end
  end

  it "formats no-results and configuration messages" do
    expect(described_class.no_results("ruby")).to include("No results found")
    expect(described_class.configuration_missing_url).to include("SEARXNG_URL")
    expect(described_class.configuration_invalid_url("bad")).to include("invalid format")
    expect(described_class.configuration_invalid_protocol("ftp")).to include("http or https")
    expect(described_class.configuration_auth_pair).to include("must be set together")
  end
end
