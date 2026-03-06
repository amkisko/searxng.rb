require "spec_helper"
require "searxng/server"

RSpec.describe Searxng::Server do
  describe Searxng::Server::NullLogger do
    it "tracks transport and initialization state" do
      logger = described_class.new
      expect(logger.client_initialized?).to eq(false)
      logger.set_client_initialized
      expect(logger.client_initialized?).to eq(true)
      logger.transport = :stdio
      expect(logger.stdio_transport?).to eq(true)
      logger.transport = :rack
      expect(logger.rack_transport?).to eq(true)
    end
  end

  describe ".start" do
    it "responds to start" do
      expect(described_class).to respond_to(:start)
    end

    it "creates server with name, version, and NullLogger and registers tool" do
      server_double = instance_double(FastMcp::Server)
      allow(FastMcp::Server).to receive(:new).and_return(server_double)
      allow(server_double).to receive(:register_tool)
      allow(server_double).to receive(:register_resource)
      allow(server_double).to receive(:start)
      allow(described_class).to receive(:validate_environment!)

      described_class.start

      expect(described_class).to have_received(:validate_environment!)
      expect(FastMcp::Server).to have_received(:new).with(
        name: "searxng",
        version: Searxng::VERSION,
        logger: an_instance_of(Searxng::Server::NullLogger)
      )
      expect(server_double).to have_received(:register_tool).with(Searxng::Server::SearxngWebSearchTool)
      expect(server_double).to have_received(:register_tool).with(Searxng::Server::WebUrlReadTool)
      expect(server_double).to have_received(:register_resource).with(Searxng::Server::ServerConfigResource)
      expect(server_double).to have_received(:register_resource).with(Searxng::Server::UsageGuideResource)
      expect(server_double).to have_received(:start)
    end
  end

  describe ".validate_environment!" do
    around do |example|
      original = ENV.to_h
      begin
        example.run
      ensure
        ENV.replace(original)
      end
    end

    it "raises when SEARXNG_URL is missing" do
      ENV.delete("SEARXNG_URL")
      expect { described_class.validate_environment! }
        .to raise_error(Searxng::ConfigurationError, /SEARXNG_URL not set/)
    end

    it "raises when auth pair is incomplete" do
      ENV["SEARXNG_URL"] = "https://search.example.com"
      ENV["SEARXNG_USER"] = "u"
      ENV.delete("SEARXNG_PASSWORD")
      expect { described_class.validate_environment! }
        .to raise_error(Searxng::ConfigurationError, /must be set together/)
    end

    it "raises when protocol is not http/https" do
      ENV["SEARXNG_URL"] = "ftp://search.example.com"
      expect { described_class.validate_environment! }
        .to raise_error(Searxng::ConfigurationError, /must use http or https/)
    end

    it "raises when URL format is invalid" do
      ENV["SEARXNG_URL"] = "not a valid url"
      expect { described_class.validate_environment! }
        .to raise_error(Searxng::ConfigurationError, /invalid format/)
    end

    it "accepts AUTH_* aliases when both are set" do
      ENV["SEARXNG_URL"] = "https://search.example.com"
      ENV["AUTH_USERNAME"] = "u"
      ENV["AUTH_PASSWORD"] = "p"
      expect { described_class.validate_environment! }.not_to raise_error
    end

    it "passes with valid URL and no auth" do
      ENV["SEARXNG_URL"] = "https://search.example.com"
      ENV.delete("SEARXNG_USER")
      ENV.delete("SEARXNG_PASSWORD")
      expect { described_class.validate_environment! }.not_to raise_error
    end
  end

  describe Searxng::Server::SearxngWebSearchTool do
    let(:tool) { described_class.new }

    it "has tool_name searxng_web_search" do
      expect(described_class.tool_name).to eq("searxng_web_search")
    end

    it "formats search result as text" do
      client = instance_double(Searxng::Client)
      allow(client).to receive(:search).with(
        "ruby",
        pageno: 1,
        time_range: nil,
        language: "all",
        safesearch: nil
      ).and_return(
        query: "ruby",
        results: [
          {title: "Ruby Lang", url: "https://ruby-lang.org", content: "Ruby programming language", score: 0.95}
        ],
        infoboxes: []
      )

      allow(tool).to receive(:get_client).and_return(client)

      result = tool.call(query: "ruby")

      expect(result).to include("Title: Ruby Lang")
      expect(result).to include("https://ruby-lang.org")
      expect(result).to include("Ruby programming language")
    end

    it "includes infoboxes in formatted output" do
      client = instance_double(Searxng::Client)
      allow(client).to receive(:search).and_return(
        query: "ruby",
        results: [],
        infoboxes: [
          {infobox: "Wikipedia", id: "wiki", content: "Ruby is a language", urls: []}
        ]
      )
      allow(tool).to receive(:get_client).and_return(client)

      result = tool.call(query: "ruby")

      expect(result).to include("Infobox: Wikipedia")
      expect(result).to include("ID: wiki")
      expect(result).to include("Ruby is a language")
    end

    it "passes optional params to client" do
      client = instance_double(Searxng::Client)
      allow(client).to receive(:search).with(
        "rails",
        pageno: 2,
        time_range: "day",
        language: "en",
        safesearch: 1
      ).and_return(query: "rails", results: [], infoboxes: [])
      allow(tool).to receive(:get_client).and_return(client)

      tool.call(query: "rails", pageno: 2, max_results: 5, time_range: "day", language: "en", safesearch: 1)

      expect(client).to have_received(:search).with(
        "rails",
        pageno: 2,
        time_range: "day",
        language: "en",
        safesearch: 1
      )
    end

    it "returns friendly no-results message" do
      client = instance_double(Searxng::Client)
      allow(client).to receive(:search).and_return(query: "ruby", results: [], infoboxes: [])
      allow(tool).to receive(:get_client).and_return(client)

      result = tool.call(query: "ruby")

      expect(result).to include('No results found for "ruby"')
      expect(result).to include("Try different search terms")
    end

    it "limits formatted results to max_results and adds more hint" do
      client = instance_double(Searxng::Client)
      allow(client).to receive(:search).and_return(
        query: "kisko",
        number_of_results: 100,
        results: [
          {title: "A", url: "https://a.example", content: "Content A", score: 1.0},
          {title: "B", url: "https://b.example", content: "Content B", score: 0.9},
          {title: "C", url: "https://c.example", content: "Content C", score: 0.8},
          {title: "D", url: "https://d.example", content: "Content D", score: 0.7}
        ],
        infoboxes: []
      )
      allow(tool).to receive(:get_client).and_return(client)

      result = tool.call(query: "kisko", max_results: 2)

      expect(result).to include("Title: A")
      expect(result).to include("Title: B")
      expect(result).not_to include("Title: C")
      expect(result).not_to include("Title: D")
      expect(result).to include("Showing 2 of 4 on this page. Use pageno=2 for more.")
    end

    it "adds total-results hint when total exceeds current page size" do
      client = instance_double(Searxng::Client)
      allow(client).to receive(:search).and_return(
        query: "kisko",
        number_of_results: 50,
        results: [
          {title: "A", url: "https://a.example", content: "Content A", score: 1.0},
          {title: "B", url: "https://b.example", content: "Content B", score: 0.9}
        ],
        infoboxes: []
      )
      allow(tool).to receive(:get_client).and_return(client)

      result = tool.call(query: "kisko", max_results: 10, pageno: 3)

      expect(result).to include("Showing 2 results (page 3). 50 total. Use pageno=4 for more.")
    end
  end

  describe Searxng::Server::WebUrlReadTool do
    let(:tool) { described_class.new }

    before do
      described_class.class_variable_set(:@@url_cache, {})
    end

    it "has tool_name web_url_read" do
      expect(described_class.tool_name).to eq("web_url_read")
    end

    it "supports pagination and section extraction options" do
      markdown = <<~MD
        # Intro
        A

        ## Details
        B

        C
      MD
      allow(tool).to receive(:fetch_html).and_return("<html></html>")
      allow(tool).to receive(:convert_to_markdown).and_return(markdown)

      result = tool.call(url: "https://example.com", section: "Details", maxLength: 4)

      expect(result).to eq("## D")
    end

    it "routes gemini URLs through gemini fetch + gemtext conversion" do
      allow(tool).to receive(:fetch_gemini).and_return("# Gemini\n=> /docs Docs")
      allow(tool).to receive(:gemtext_to_markdown).and_return("# Gemini\n- [Docs](gemini://example.com/docs)")

      result = tool.call(url: "gemini://example.com")

      expect(result).to include("Gemini")
      expect(tool).to have_received(:fetch_gemini)
      expect(tool).to have_received(:gemtext_to_markdown)
    end

    it "routes ipfs URLs through gateway resolution + html conversion" do
      allow(tool).to receive(:resolve_ipfs_url).and_return("https://ipfs.io/ipfs/cid/path")
      allow(tool).to receive(:fetch_html).and_return("<h1>IPFS</h1>")
      allow(tool).to receive(:convert_to_markdown).and_return("# IPFS")

      result = tool.call(url: "ipfs://cid/path")

      expect(result).to eq("# IPFS")
      expect(tool).to have_received(:resolve_ipfs_url)
    end

    it "routes ftp URLs through ftp fetch + content conversion" do
      allow(tool).to receive(:fetch_ftp).and_return("hello from ftp")
      allow(tool).to receive(:convert_fetched_content).and_return("hello from ftp")

      result = tool.call(url: "ftp://example.com/path/file.txt")

      expect(result).to eq("hello from ftp")
      expect(tool).to have_received(:fetch_ftp)
    end

    it "routes sftp URLs through sftp fetch + content conversion" do
      allow(tool).to receive(:fetch_sftp).and_return("hello from sftp")
      allow(tool).to receive(:convert_fetched_content).and_return("hello from sftp")

      result = tool.call(url: "sftp://user@example.com/path/file.txt")

      expect(result).to eq("hello from sftp")
      expect(tool).to have_received(:fetch_sftp)
    end

    it "routes smb URLs through smb fetch + content conversion" do
      allow(tool).to receive(:fetch_smb).and_return("hello from smb")
      allow(tool).to receive(:convert_fetched_content).and_return("hello from smb")

      result = tool.call(url: "smb://fileserver/share/path/file.txt")

      expect(result).to eq("hello from smb")
      expect(tool).to have_received(:fetch_smb)
    end

    it "rejects unsupported schemes" do
      expect { tool.call(url: "spartan://example.com") }.to raise_error(Searxng::ConfigurationError, /Unsupported URL scheme/)
      expect { tool.call(url: "gopher://example.com") }.to raise_error(Searxng::ConfigurationError, /Unsupported URL scheme/)
    end

    it "extracts only headings when requested" do
      markdown = "# H1\ntext\n## H2\nmore"
      allow(tool).to receive(:fetch_html).and_return("<html></html>")
      allow(tool).to receive(:convert_to_markdown).and_return(markdown)

      result = tool.call(url: "https://example.com", readHeadings: true)

      expect(result).to eq("# H1\n## H2")
    end

    it "returns section and paragraph range validation messages" do
      markdown = "A\n\nB"
      missing_section = tool.send(:apply_options, markdown, start_char: 0, max_length: nil, section: "Missing", paragraph_range: nil, read_headings: false)
      bad_paragraph = tool.send(:apply_options, markdown, start_char: 0, max_length: nil, section: nil, paragraph_range: "999", read_headings: false)

      expect(missing_section).to include('Section "Missing" not found')
      expect(bad_paragraph).to include('Paragraph range "999" is invalid')
    end

    it "normalizes hostnames to https and rejects invalid URLs" do
      expect(tool.send(:normalize_url, "example.com")).to eq("https://example.com")
      expect { tool.send(:normalize_url, "bad url%%%") }.to raise_error(Searxng::ConfigurationError, /Invalid URL/)
      expect(tool.send(:normalize_url, "ftp://example.com/path")).to eq("ftp://example.com/path")
      expect(tool.send(:normalize_url, "sftp://example.com/path")).to eq("sftp://example.com/path")
      expect(tool.send(:normalize_url, "smb://example.com/share/file")).to eq("smb://example.com/share/file")
      expect { tool.send(:normalize_url, "gopher://example.com") }.to raise_error(Searxng::ConfigurationError, /Unsupported URL scheme/)
    end

    it "uses cache when available in fetch_html" do
      described_class.class_variable_set(:@@url_cache, {"https://example.com" => {at: Time.now.to_i, html: "<x>cached</x>"}})
      result = tool.send(:fetch_html, "https://example.com", timeout_ms: 1000)
      expect(result).to eq("<x>cached</x>")
    end

    it "raises APIError for non-success response in fetch_html" do
      response = instance_double(Net::HTTPBadRequest, body: "bad", code: "400", message: "Bad Request")
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_return(response)
      client = instance_double(Searxng::Client)
      allow(client).to receive(:build_http).and_return(http)
      allow(tool).to receive(:get_client).and_return(client)

      expect { tool.send(:fetch_html, "https://example.com", timeout_ms: 1000) }
        .to raise_error(Searxng::APIError, /400/)
    end

    it "raises APIError for empty response body in fetch_html" do
      response = instance_double(Net::HTTPOK, body: " ", code: "200", message: "OK")
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_return(response)
      client = instance_double(Searxng::Client)
      allow(client).to receive(:build_http).and_return(http)
      allow(tool).to receive(:get_client).and_return(client)

      expect { tool.send(:fetch_html, "https://example.com", timeout_ms: 1000) }
        .to raise_error(Searxng::APIError, /empty content/)
    end

    it "stores successful html fetches in cache" do
      described_class.class_variable_set(:@@url_cache, {})
      response = instance_double(Net::HTTPOK, body: "<html>ok</html>", code: "200", message: "OK")
      allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_return(response)
      client = instance_double(Searxng::Client)
      allow(client).to receive(:build_http).and_return(http)
      allow(tool).to receive(:get_client).and_return(client)

      result = tool.send(:fetch_html, "https://example.com", timeout_ms: 1000)

      expect(result).to eq("<html>ok</html>")
      cache = described_class.class_variable_get(:@@url_cache)
      expect(cache["https://example.com"][:html]).to eq("<html>ok</html>")
    end

    it "raises NetworkError on timeout in fetch_html" do
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request) { sleep 0.01 }
      client = instance_double(Searxng::Client)
      allow(client).to receive(:build_http).and_return(http)
      allow(tool).to receive(:get_client).and_return(client)

      expect { tool.send(:fetch_html, "https://example.com", timeout_ms: 1) }
        .to raise_error(Searxng::NetworkError, /Timeout Error/)
    end

    it "returns content warning when markdown conversion is empty" do
      allow(tool).to receive(:load_teplo_core!).and_return(true)
      stub_const("TeploCore", Module.new)
      allow(TeploCore).to receive(:parse_html).and_return(:ast)
      allow(TeploCore).to receive(:ast_to_markdown).and_return(" ")

      result = tool.send(:convert_to_markdown, "<html></html>", "https://example.com")

      expect(result).to include("Content Warning")
    end

    it "raises APIError when conversion fails" do
      allow(tool).to receive(:load_teplo_core!).and_raise(StandardError.new("boom"))
      expect { tool.send(:convert_to_markdown, "<html></html>", "https://example.com") }
        .to raise_error(Searxng::APIError, /Conversion Error/)
    end

    it "returns markdown on successful conversion" do
      allow(tool).to receive(:load_teplo_core!).and_return(true)
      stub_const("TeploCore", Module.new)
      allow(TeploCore).to receive(:parse_html).and_return(:ast)
      allow(TeploCore).to receive(:ast_to_markdown).and_return("# Converted")

      result = tool.send(:convert_to_markdown, "<html></html>", "https://example.com")

      expect(result).to eq("# Converted")
    end

    it "extracts headings fallback message when no headings found" do
      expect(tool.send(:extract_headings, "plain text")).to eq("No headings found in the content.")
    end

    it "extracts paragraph range variations" do
      markdown = "P1\n\nP2\n\nP3"
      expect(tool.send(:extract_paragraph_range, markdown, "2")).to eq("P2")
      expect(tool.send(:extract_paragraph_range, markdown, "2-")).to eq("P2\n\nP3")
      expect(tool.send(:extract_paragraph_range, markdown, "1-2")).to eq("P1\n\nP2")
    end

    it "returns plain text unchanged for non-markup fetched content" do
      expect(tool.send(:convert_fetched_content, "hello world", "ftp://example.com/path")).to eq("hello world")
    end

    it "converts markup fetched content via markdown converter" do
      allow(tool).to receive(:convert_to_markdown).and_return("# Converted")
      result = tool.send(:convert_fetched_content, "<html><body>hi</body></html>", "ftp://example.com/path")
      expect(result).to eq("# Converted")
    end

    it "converts gemtext links and relative targets to markdown" do
      base = URI.parse("gemini://gemini.example/path")
      result = tool.send(:gemtext_to_markdown, "=> /docs Documentation\n=> gemini://other.example Other", base)
      expect(result).to include("[Documentation](gemini://gemini.example/docs)")
      expect(result).to include("[Other](gemini://other.example)")
    end

    it "converts gemtext headings and quotes" do
      base = URI.parse("gemini://gemini.example/path")
      input = "### H3\n## H2\n# H1\n> quote\nplain"
      result = tool.send(:gemtext_to_markdown, input, base)
      expect(result).to include("### H3")
      expect(result).to include("## H2")
      expect(result).to include("# H1")
      expect(result).to include("> quote")
      expect(result).to include("plain")
    end

    it "resolves ipfs URLs via gateway env and validates gateway scheme" do
      original = ENV["IPFS_GATEWAY"]
      ENV["IPFS_GATEWAY"] = "https://gateway.example"
      expect(tool.send(:resolve_ipfs_url, URI.parse("ipfs://cid/path"))).to eq("https://gateway.example/ipfs/cid/path")

      ENV["IPFS_GATEWAY"] = "gemini://gateway.example"
      expect { tool.send(:resolve_ipfs_url, URI.parse("ipfs://cid/path")) }.to raise_error(Searxng::ConfigurationError, /must use http or https/)

      ENV["IPFS_GATEWAY"] = "%%%bad"
      expect { tool.send(:resolve_ipfs_url, URI.parse("ipfs://cid/path")) }.to raise_error(Searxng::ConfigurationError, /invalid format/)
    ensure
      ENV["IPFS_GATEWAY"] = original
    end

    it "fetches gemini content for successful responses" do
      uri = URI.parse("gemini://example.com")
      tcp = instance_double(TCPSocket, closed?: false)
      ssl = instance_double(OpenSSL::SSL::SSLSocket)
      allow(TCPSocket).to receive(:new).and_return(tcp)
      allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl)
      allow(ssl).to receive(:respond_to?).with(:hostname=).and_return(true)
      allow(ssl).to receive(:hostname=)
      allow(ssl).to receive(:connect)
      allow(ssl).to receive(:write)
      allow(ssl).to receive(:gets).with("\r\n").and_return("20 text/gemini\r\n")
      allow(ssl).to receive(:read).and_return("# hello")
      allow(ssl).to receive(:close)
      allow(tcp).to receive(:close)

      result = tool.send(:fetch_gemini, uri, timeout_ms: 1000)

      expect(result).to eq("# hello")
    end

    it "raises APIError when gemini response header is missing" do
      uri = URI.parse("gemini://example.com")
      tcp = instance_double(TCPSocket, closed?: false)
      ssl = instance_double(OpenSSL::SSL::SSLSocket)
      allow(TCPSocket).to receive(:new).and_return(tcp)
      allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl)
      allow(ssl).to receive(:respond_to?).with(:hostname=).and_return(false)
      allow(ssl).to receive(:connect)
      allow(ssl).to receive(:write)
      allow(ssl).to receive(:gets).with("\r\n").and_return(nil)
      allow(ssl).to receive(:read).and_return("")
      allow(ssl).to receive(:close)
      allow(tcp).to receive(:close)

      expect { tool.send(:fetch_gemini, uri, timeout_ms: 1000) }
        .to raise_error(Searxng::APIError, /empty response header/)
    end

    it "maps additional gemini status classes to API errors" do
      uri = URI.parse("gemini://example.com")
      tcp = instance_double(TCPSocket, closed?: false)
      ssl = instance_double(OpenSSL::SSL::SSLSocket)
      allow(TCPSocket).to receive(:new).and_return(tcp)
      allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl)
      allow(ssl).to receive(:respond_to?).with(:hostname=).and_return(false)
      allow(ssl).to receive(:connect)
      allow(ssl).to receive(:write)
      allow(ssl).to receive(:read).and_return("")
      allow(ssl).to receive(:close)
      allow(tcp).to receive(:close)

      allow(ssl).to receive(:gets).with("\r\n").and_return("41 temporary\r\n")
      expect { tool.send(:fetch_gemini, uri, timeout_ms: 1000) }.to raise_error(Searxng::APIError, /temporary failure/)

      allow(ssl).to receive(:gets).with("\r\n").and_return("51 permanent\r\n")
      expect { tool.send(:fetch_gemini, uri, timeout_ms: 1000) }.to raise_error(Searxng::APIError, /permanent failure/)

      allow(ssl).to receive(:gets).with("\r\n").and_return("61 cert\r\n")
      expect { tool.send(:fetch_gemini, uri, timeout_ms: 1000) }.to raise_error(Searxng::APIError, /certificate required/)

      allow(ssl).to receive(:gets).with("\r\n").and_return("10 input\r\n")
      expect { tool.send(:fetch_gemini, uri, timeout_ms: 1000) }.to raise_error(Searxng::APIError, /response error/)
    end

    it "raises APIError on gemini non-success statuses" do
      uri = URI.parse("gemini://example.com")
      tcp = instance_double(TCPSocket, closed?: false)
      ssl = instance_double(OpenSSL::SSL::SSLSocket)
      allow(TCPSocket).to receive(:new).and_return(tcp)
      allow(OpenSSL::SSL::SSLSocket).to receive(:new).and_return(ssl)
      allow(ssl).to receive(:respond_to?).with(:hostname=).and_return(false)
      allow(ssl).to receive(:connect)
      allow(ssl).to receive(:write)
      allow(ssl).to receive(:gets).with("\r\n").and_return("31 gemini://example.com/new\r\n")
      allow(ssl).to receive(:read).and_return("")
      allow(ssl).to receive(:close)
      allow(tcp).to receive(:close)

      expect { tool.send(:fetch_gemini, uri, timeout_ms: 1000) }
        .to raise_error(Searxng::APIError, /Gemini redirect/)
    end

    it "maps gemini socket failures to NetworkError" do
      uri = URI.parse("gemini://example.com")
      allow(TCPSocket).to receive(:new).and_raise(SocketError.new("fail"))

      expect { tool.send(:fetch_gemini, uri, timeout_ms: 1000) }
        .to raise_error(Searxng::NetworkError, /DNS Error|Network Error/)
    end

    it "keeps unresolved invalid gemtext URLs as-is" do
      base = URI.parse("gemini://example.com/")
      text = "=> :::: broken"
      result = tool.send(:gemtext_to_markdown, text, base)
      expect(result).to include("::::")
    end

    it "raises ConfigurationError when ftp gem is missing" do
      allow(tool).to receive(:require).with("net/ftp").and_raise(LoadError)
      expect { tool.send(:fetch_ftp, URI.parse("ftp://example.com"), timeout_ms: 1000) }
        .to raise_error(Searxng::ConfigurationError, /net-ftp/)
    end

    it "fetches ftp content successfully" do
      allow(tool).to receive(:require).with("net/ftp").and_return(true)
      stub_const("Net::FTP", Class.new)
      ftp = instance_double("Net::FTP", closed?: false)
      allow(Net::FTP).to receive(:new).and_return(ftp)
      allow(ftp).to receive(:connect)
      allow(ftp).to receive(:read_timeout=)
      allow(ftp).to receive(:open_timeout=)
      allow(ftp).to receive(:login)
      allow(ftp).to receive(:retrbinary) { |_cmd, _size, &blk| blk.call("abc") }
      allow(ftp).to receive(:close)

      result = tool.send(:fetch_ftp, URI.parse("ftp://example.com/path/file.txt"), timeout_ms: 1000)

      expect(result).to eq("abc")
    end

    it "raises ConfigurationError when sftp gem is missing" do
      allow(tool).to receive(:require).with("net/sftp").and_raise(LoadError)
      expect { tool.send(:fetch_sftp, URI.parse("sftp://user@example.com/path/file.txt"), timeout_ms: 1000) }
        .to raise_error(Searxng::ConfigurationError, /net-sftp/)
    end

    it "validates missing sftp username" do
      allow(tool).to receive(:require).with("net/sftp").and_return(true)
      expect { tool.send(:fetch_sftp, URI.parse("sftp://example.com/path/file.txt"), timeout_ms: 1000) }
        .to raise_error(Searxng::ConfigurationError, /requires username/)
    end

    it "maps sftp status/auth/general errors to APIError" do
      allow(tool).to receive(:require).with("net/sftp").and_return(true)
      stub_const("Net::SFTP", Module.new)
      stub_const("Net::SSH", Module.new)
      status_exception_class = Class.new(StandardError) do
        def description
          "status desc"
        end
      end
      auth_exception_class = Class.new(StandardError)
      stub_const("Net::SFTP::StatusException", status_exception_class)
      stub_const("Net::SSH::AuthenticationFailed", auth_exception_class)
      sftp_mod = Net::SFTP

      allow(sftp_mod).to receive(:start).and_raise(StandardError.new("generic"))
      expect { tool.send(:fetch_sftp, URI.parse("sftp://user@example.com/path/file.txt"), timeout_ms: 1000) }
        .to raise_error(Searxng::APIError, /SFTP Error: generic/)

      allow(sftp_mod).to receive(:start).and_raise(Net::SSH::AuthenticationFailed.new("auth"))
      expect { tool.send(:fetch_sftp, URI.parse("sftp://user@example.com/path/file.txt"), timeout_ms: 1000) }
        .to raise_error(Searxng::APIError, /authentication failed/)

      allow(sftp_mod).to receive(:start).and_raise(Net::SFTP::StatusException.new("status"))
      expect { tool.send(:fetch_sftp, URI.parse("sftp://user@example.com/path/file.txt"), timeout_ms: 1000) }
        .to raise_error(Searxng::APIError, /SFTP Error: status desc/)
    end

    it "validates smb path format and missing smbclient binary" do
      expect { tool.send(:parse_smb_path, URI.parse("smb://host/share")) }
        .to raise_error(Searxng::APIError, /must include share and file/)

      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)
      expect { tool.send(:fetch_smb, URI.parse("smb://host/share/path/file.txt"), timeout_ms: 1000) }
        .to raise_error(Searxng::ConfigurationError, /smbclient/)
    end
  end

  describe Searxng::Server::ServerConfigResource do
    around do |example|
      original = ENV.to_h
      begin
        example.run
      ensure
        ENV.replace(original)
      end
    end

    it "returns config JSON with capabilities" do
      ENV["SEARXNG_URL"] = "https://user:pass@example.com"
      ENV["SEARXNG_USER"] = "u"
      ENV["SEARXNG_PASSWORD"] = "p"
      ENV["HTTP_PROXY"] = "http://proxy.local:8080"
      ENV["NO_PROXY"] = "localhost"

      content = described_class.new.content
      data = JSON.parse(content)

      expect(data.dig("server_info", "name")).to eq("searxng")
      expect(data.dig("environment", "searxng_url")).to eq("https://example.com")
      expect(data.dig("environment", "has_auth")).to eq(true)
      expect(data.dig("environment", "has_proxy")).to eq(true)
      expect(data.dig("capabilities", "tools")).to include("web_url_read")
    end

    it "returns placeholders for missing and invalid URLs" do
      ENV["SEARXNG_URL"] = "not a valid url"
      bad = JSON.parse(described_class.new.content)
      expect(bad.dig("environment", "searxng_url")).to eq("(invalid URL)")

      ENV["SEARXNG_URL"] = ""
      missing = JSON.parse(described_class.new.content)
      expect(missing.dig("environment", "searxng_url")).to eq("(not configured)")
    end
  end

  describe Searxng::Server::UsageGuideResource do
    it "returns markdown usage content" do
      content = described_class.new.content
      expect(content).to include("SearXNG MCP Server Help")
      expect(content).to include("web_url_read")
      expect(content).to include("Protocol Notes")
      expect(content).to include("gemini")
      expect(content).to include("ftp")
      expect(content).to include("sftp")
      expect(content).to include("smb")
      expect(content).to include("ipfs")
      expect(content).to include("tor")
      expect(content).to include("i2p")
      expect(content).to include("socks5")
    end
  end
end
