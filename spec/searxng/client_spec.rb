require "spec_helper"

RSpec.describe Searxng::Client do
  let(:base_url) { "http://localhost:8080" }
  let(:client) { described_class.new(base_url: base_url) }

  describe "#initialize" do
    it "uses default base URL when not provided" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SEARXNG_URL").and_return(nil)
      c = described_class.new
      expect(c.instance_variable_get(:@base_url)).to eq("http://localhost:8080")
    end

    it "uses ENV SEARXNG_URL when base_url not provided" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SEARXNG_URL").and_return("https://search.example.com")
      allow(ENV).to receive(:[]).with("SEARXNG_USER").and_return(nil)
      allow(ENV).to receive(:[]).with("SEARXNG_PASSWORD").and_return(nil)
      c = described_class.new
      expect(c.instance_variable_get(:@base_url)).to eq("https://search.example.com")
    end

    it "accepts base_url option" do
      c = described_class.new(base_url: "https://custom.example.com")
      expect(c.instance_variable_get(:@base_url)).to eq("https://custom.example.com")
    end

    it "accepts ca_file, ca_path, verify_mode, user_agent, and configure_http options" do
      callback = proc { |_http, _uri| }
      c = described_class.new(
        base_url: base_url,
        ca_file: "/path/to/ca.pem",
        ca_path: "/etc/ssl/certs",
        verify_mode: OpenSSL::SSL::VERIFY_NONE,
        user_agent: "CustomAgent/1.0",
        configure_http: callback
      )
      expect(c.instance_variable_get(:@ca_file)).to eq("/path/to/ca.pem")
      expect(c.instance_variable_get(:@ca_path)).to eq("/etc/ssl/certs")
      expect(c.instance_variable_get(:@verify_mode)).to eq(OpenSSL::SSL::VERIFY_NONE)
      expect(c.instance_variable_get(:@user_agent)).to eq("CustomAgent/1.0")
      expect(c.instance_variable_get(:@configure_http)).to eq(callback)
    end

    it "uses ENV SEARXNG_CA_FILE and SEARXNG_CA_PATH when not provided" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SEARXNG_CA_FILE").and_return("/env/ca.pem")
      allow(ENV).to receive(:[]).with("SEARXNG_CA_PATH").and_return("/env/certs")
      c = described_class.new(base_url: base_url)
      expect(c.instance_variable_get(:@ca_file)).to eq("/env/ca.pem")
      expect(c.instance_variable_get(:@ca_path)).to eq("/env/certs")
    end

    it "uses ENV SEARXNG_USER_AGENT when user_agent not provided" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SEARXNG_USER_AGENT").and_return("EnvAgent/1.0")
      c = described_class.new(base_url: base_url)
      expect(c.instance_variable_get(:@user_agent)).to eq("EnvAgent/1.0")
    end
  end

  describe "#search" do
    let(:search_uri) { %r{#{Regexp.escape(base_url)}/search\?.*q=hello} }

    it "returns results and infoboxes from JSON response" do
      body = {
        query: "hello",
        number_of_results: 2,
        results: [
          {"title" => "Hello World", "url" => "https://example.com/1", "content" => "Snippet 1", "score" => 0.9},
          {"title" => "Hello Ruby", "url" => "https://example.com/2", "content" => "Snippet 2", "score" => 0.8}
        ],
        infoboxes: [
          {"infobox" => "Wikipedia", "id" => "wikipedia", "content" => "Hello is a greeting", "urls" => [{"title" => "Wiki", "url" => "https://wiki.example.com"}]}
        ],
        suggestions: [],
        answers: [],
        corrections: []
      }.to_json

      stub_request(:get, search_uri)
        .to_return(status: 200, body: body, headers: {"Content-Type" => "application/json"})

      data = client.search("hello")

      expect(data[:query]).to eq("hello")
      expect(data[:number_of_results]).to eq(2)
      expect(data[:results].size).to eq(2)
      expect(data[:results][0][:title]).to eq("Hello World")
      expect(data[:results][0][:url]).to eq("https://example.com/1")
      expect(data[:results][0][:content]).to eq("Snippet 1")
      expect(data[:results][0][:score]).to eq(0.9)
      expect(data[:infoboxes].size).to eq(1)
      expect(data[:infoboxes][0][:infobox]).to eq("Wikipedia")
      expect(data[:infoboxes][0][:content]).to eq("Hello is a greeting")
      expect(data[:suggestions]).to eq([])
    end

    it "passes pageno, time_range, language, safesearch as query params" do
      stub_request(:get, %r{/search\?.*pageno=2})
        .with(query: hash_including("q" => "ruby", "format" => "json", "pageno" => "2", "time_range" => "day", "language" => "en", "safesearch" => "1"))
        .to_return(status: 200, body: '{"query":"ruby","results":[],"infoboxes":[]}', headers: {"Content-Type" => "application/json"})

      client.search("ruby", pageno: 2, time_range: "day", language: "en", safesearch: 1)

      expect(WebMock).to have_requested(:get, "#{base_url}/search").with(
        query: hash_including("q" => "ruby", "pageno" => "2", "time_range" => "day", "language" => "en", "safesearch" => "1")
      )
    end

    it "raises ConfigurationError when base URL is empty" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("SEARXNG_URL").and_return(nil)
      c = described_class.new(base_url: "")
      expect { c.search("x") }.to raise_error(Searxng::ConfigurationError, /SEARXNG_URL not set/)
    end

    it "raises APIError on HTTP error response" do
      stub_request(:get, search_uri)
        .to_return(status: 503, body: "Service Unavailable", headers: {})

      expect { client.search("hello") }.to raise_error(Searxng::APIError) do |e|
        expect(e.status_code).to eq(503)
        expect(e.response_data).to eq("Service Unavailable")
      end
    end

    it "raises APIError on invalid JSON" do
      stub_request(:get, search_uri)
        .to_return(status: 200, body: "not json", headers: {"Content-Type" => "application/json"})

      expect { client.search("hello") }.to raise_error(Searxng::APIError, /Invalid JSON/)
    end

    it "raises NetworkError on connection failure" do
      stub_request(:get, search_uri).to_timeout

      expect { client.search("hello") }.to raise_error(Searxng::NetworkError, /Connection failed/)
    end

    it "raises NetworkError when server closes connection (EOFError)" do
      stub_request(:get, search_uri).to_raise(EOFError.new("end of file reached"))

      expect { client.search("hello") }.to raise_error(Searxng::NetworkError, /Connection failed.*end of file reached/)
    end

    it "sends Basic auth when user and password are set" do
      stub_request(:get, %r{#{Regexp.escape(base_url)}/search})
        .with(basic_auth: ["user", "pass"])
        .to_return(status: 200, body: '{"query":"hi","results":[],"infoboxes":[]}', headers: {"Content-Type" => "application/json"})

      authed = described_class.new(base_url: base_url, user: "user", password: "pass")
      authed.search("hi")
      expect(WebMock).to have_requested(:get, %r{#{Regexp.escape(base_url)}/search}).with(basic_auth: ["user", "pass"])
    end

    it "sends User-Agent header (default or custom)" do
      stub_request(:get, search_uri)
        .with(headers: {"User-Agent" => "searxng-ruby/0.1.0 (https://github.com/amkisko/searxng.rb)"})
        .to_return(status: 200, body: '{"query":"hi","results":[],"infoboxes":[]}', headers: {"Content-Type" => "application/json"})
      client.search("hello")
      expect(WebMock).to have_requested(:get, search_uri).with(headers: {"User-Agent" => "searxng-ruby/0.1.0 (https://github.com/amkisko/searxng.rb)"})

      stub_request(:get, search_uri)
        .with(headers: {"User-Agent" => "MyBot/1.0"})
        .to_return(status: 200, body: '{"query":"hi","results":[],"infoboxes":[]}', headers: {"Content-Type" => "application/json"})
      custom = described_class.new(base_url: base_url, user_agent: "MyBot/1.0")
      custom.search("hello")
      expect(WebMock).to have_requested(:get, search_uri).with(headers: {"User-Agent" => "MyBot/1.0"})
    end

    it "calls configure_http with the http instance and uri before requesting" do
      stub_request(:get, search_uri)
        .to_return(status: 200, body: '{"query":"hi","results":[],"infoboxes":[]}', headers: {"Content-Type" => "application/json"})

      received_http = nil
      received_uri = nil
      client_with_hook = described_class.new(
        base_url: base_url,
        configure_http: ->(http, uri) {
          received_http = http
          received_uri = uri
        }
      )
      client_with_hook.search("hello")

      expect(received_http).to be_a(Net::HTTP)
      expect(received_uri).to be_a(URI::HTTP)
      expect(received_uri.to_s).to include("/search")
    end
  end
end
