require "fast_mcp"
require "searxng"
require "json"
require "net/http"
require "openssl"
require "open3"
require "socket"
require "time"
require "timeout"
require "uri"

FastMcp = MCP unless defined?(FastMcp)

module Searxng
  class Server
    class NullLogger
      attr_accessor :transport, :client_initialized

      def initialize
        @transport = nil
        @client_initialized = false
        @level = nil
      end

      attr_writer :level
      attr_reader :level

      def debug(*)
      end

      def info(*)
      end

      def warn(*)
      end

      def error(*)
      end

      def fatal(*)
      end

      def unknown(*)
      end

      def client_initialized?
        @client_initialized
      end

      def set_client_initialized(value = true)
        @client_initialized = value
      end

      def stdio_transport?
        @transport == :stdio
      end

      def rack_transport?
        @transport == :rack
      end
    end

    def self.start
      validate_environment!
      server = FastMcp::Server.new(
        name: "searxng",
        version: Searxng::VERSION,
        logger: NullLogger.new
      )
      register_tools(server)
      register_resources(server)
      server.start
    end

    def self.register_tools(server)
      server.register_tool(SearxngWebSearchTool)
      server.register_tool(WebUrlReadTool)
    end

    def self.register_resources(server)
      server.register_resource(ServerConfigResource)
      server.register_resource(UsageGuideResource)
    end

    def self.validate_environment!
      searxng_url = ENV["SEARXNG_URL"]
      if searxng_url.nil? || searxng_url.strip.empty?
        raise ConfigurationError, ErrorMessages.configuration_missing_url
      end

      uri = URI.parse(searxng_url)
      unless %w[http https].include?(uri.scheme)
        raise ConfigurationError, ErrorMessages.configuration_invalid_protocol(uri.scheme)
      end

      user = ENV["SEARXNG_USER"] || ENV["AUTH_USERNAME"]
      password = ENV["SEARXNG_PASSWORD"] || ENV["AUTH_PASSWORD"]
      if (user && !password) || (!user && password)
        raise ConfigurationError, ErrorMessages.configuration_auth_pair
      end
    rescue URI::InvalidURIError
      raise ConfigurationError, ErrorMessages.configuration_invalid_url(searxng_url)
    end

    class BaseTool < FastMcp::Tool
      protected

      def get_client
        Client.new
      end
    end

    class SearxngWebSearchTool < BaseTool
      tool_name "searxng_web_search"
      description "Performs a web search using the SearXNG API. Use this to find information on the web. Aggregates results from multiple search engines."
      annotations(readOnlyHint: true, openWorldHint: true) if respond_to?(:annotations)

      arguments do
        required(:query).filled(:string).description("The search query")
        optional(:pageno).filled(:integer).description("Search page number (default: 1)")
        optional(:max_results).filled(:integer).description("Max number of results to return in the response (default: 10). Use pageno for more.")
        optional(:time_range).filled(:string).description("Time range: day, month, or year")
        optional(:language).filled(:string).description("Language code (e.g. en, fr). Default: all")
        optional(:safesearch).filled(:integer).description("Safe search: 0=none, 1=moderate, 2=strict")
      end

      def call(query:, pageno: 1, max_results: 10, time_range: nil, language: "all", safesearch: nil)
        data = get_client.search(
          query,
          pageno: pageno,
          time_range: time_range,
          language: language,
          safesearch: safesearch
        )
        format_search_result(data, max_results: max_results, pageno: pageno)
      end

      private

      def format_search_result(data, max_results: 10, pageno: 1)
        out = []
        query = data[:query].to_s
        data[:infoboxes]&.each do |ib|
          out << "Infobox: #{ib[:infobox]}"
          out << "ID: #{ib[:id]}"
          out << "Content: #{ib[:content]}"
          out << ""
        end
        results = data[:results] || []
        total = data[:number_of_results]
        if results.empty?
          out << ErrorMessages.no_results(query.empty? ? "your query" : query)
        else
          limit = [max_results.to_i, 1].max
          shown = results.first(limit)
          shown.each do |r|
            out << "Title: #{r[:title]}"
            out << "URL: #{r[:url]}"
            out << "Content: #{r[:content]}"
            out << "Score: #{r[:score]}"
            out << ""
          end
          if results.size > limit
            out << "Showing #{limit} of #{results.size} on this page. Use pageno=#{pageno + 1} for more."
          elsif total && total > results.size
            out << "Showing #{shown.size} results (page #{pageno}). #{total} total. Use pageno=#{pageno + 1} for more."
          end
        end
        out.join("\n").strip
      end
    end

    class WebUrlReadTool < BaseTool
      tool_name "web_url_read"
      description "Reads a URL and converts HTML/XML content into Markdown. Supports character pagination, section extraction, paragraph ranges, and heading-only mode."
      annotations(readOnlyHint: true, openWorldHint: true) if respond_to?(:annotations)

      CACHE_TTL_SECONDS = 300
      @@url_cache = {} # rubocop:disable Style/ClassVars

      arguments do
        required(:url).filled(:string).description("URL to fetch and read")
        optional(:startChar).filled(:integer).description("Starting character position (default: 0)")
        optional(:maxLength).filled(:integer).description("Maximum characters to return")
        optional(:section).filled(:string).description("Extract by heading text")
        optional(:paragraphRange).filled(:string).description("Paragraph range, e.g. '1-5', '3', '10-'")
        optional(:readHeadings).filled(:bool).description("Return only headings when true")
        optional(:timeoutMs).filled(:integer).description("Request timeout in ms (default: 10000)")
      end

      def call(url:, startChar: 0, maxLength: nil, section: nil, paragraphRange: nil, readHeadings: false, timeoutMs: 10_000)
        normalized = normalize_url(url)
        uri = URI.parse(normalized)
        markdown = case uri.scheme
        when "http", "https"
          html = fetch_html(normalized, timeout_ms: timeoutMs.to_i)
          convert_to_markdown(html, normalized)
        when "ftp"
          content = fetch_ftp(uri, timeout_ms: timeoutMs.to_i)
          convert_fetched_content(content, normalized)
        when "sftp"
          content = fetch_sftp(uri, timeout_ms: timeoutMs.to_i)
          convert_fetched_content(content, normalized)
        when "smb"
          content = fetch_smb(uri, timeout_ms: timeoutMs.to_i)
          convert_fetched_content(content, normalized)
        when "gemini"
          gemtext = fetch_gemini(uri, timeout_ms: timeoutMs.to_i)
          gemtext_to_markdown(gemtext, uri)
        when "ipfs"
          gateway_url = resolve_ipfs_url(uri)
          html = fetch_html(gateway_url, timeout_ms: timeoutMs.to_i)
          convert_to_markdown(html, gateway_url)
        else
          raise ConfigurationError, %(Unsupported URL scheme "#{uri.scheme}". Supported schemes: http, https, ftp, sftp, smb, gemini, ipfs.)
        end
        apply_options(markdown, start_char: startChar, max_length: maxLength, section: section, paragraph_range: paragraphRange, read_headings: readHeadings)
      end

      private

      def normalize_url(url)
        raw = url.to_s.strip
        uri = URI.parse(raw)
        if uri.scheme
          scheme = uri.scheme.downcase
          return raw if uri.host && %w[http https ftp sftp smb gemini ipfs spartan].include?(scheme)

          raise ConfigurationError, %(Unsupported URL scheme "#{uri.scheme}". Supported schemes: http, https, ftp, sftp, smb, gemini, ipfs.)
        end

        candidate = "https://#{raw}"
        parsed = URI.parse(candidate)
        return candidate if parsed.host

        raise ArgumentError
      rescue URI::InvalidURIError, ArgumentError
        raise ConfigurationError, %(URL Format Error: Invalid URL "#{url}")
      end

      def fetch_html(url, timeout_ms:)
        now = Time.now.to_i
        cached = @@url_cache[url]
        if cached && (now - cached[:at] <= CACHE_TTL_SECONDS)
          return cached[:html]
        end

        uri = URI.parse(url)
        client = get_client
        http = client.send(:build_http, uri)
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "searxng-ruby/#{Searxng::VERSION} web_url_read"
        response = nil
        Timeout.timeout(timeout_ms / 1000.0) { response = http.request(request) }
        unless response.is_a?(Net::HTTPSuccess)
          raise APIError.new(
            ErrorMessages.api_error(response.code.to_i, response.message),
            status_code: response.code.to_i,
            response_data: response.body,
            uri: url
          )
        end

        body = response.body.to_s
        if body.strip.empty?
          raise APIError.new("Content Error: Website returned empty content.", status_code: response.code.to_i, uri: url)
        end

        @@url_cache[url] = {at: now, html: body}
        body
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{URI.parse(url).host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, OpenSSL::SSL::SSLError, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: URI.parse(url), target: "website")
      end

      def convert_to_markdown(html, base_url)
        load_teplo_core!
        ast = TeploCore.parse_html(html)
        markdown = TeploCore.ast_to_markdown(ast, base_url)
        if markdown.to_s.strip.empty?
          "Content Warning: Page fetched but appears empty after conversion (#{base_url}). May contain only media or require JavaScript."
        else
          markdown
        end
      rescue StandardError => e
        raise APIError.new("Conversion Error: Cannot convert HTML to Markdown (#{base_url}) - #{e.message}", uri: base_url)
      end

      def convert_fetched_content(content, base_url)
        text = content.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        return text if text.strip.empty?

        looks_like_markup = text.match?(/\A\s*<(?:!doctype|html|body|xml|rss|feed|svg|\?xml)/i)
        looks_like_markup ? convert_to_markdown(text, base_url) : text
      end

      def fetch_ftp(uri, timeout_ms:)
        begin
          require "net/ftp"
        rescue LoadError
          raise ConfigurationError, "FTP support requires the 'net-ftp' gem."
        end

        body = +""
        Timeout.timeout(timeout_ms / 1000.0) do
          ftp = Net::FTP.new
          begin
            ftp.connect(uri.host, uri.port || 21)
            ftp.read_timeout = [timeout_ms / 1000.0, 1.0].max
            ftp.open_timeout = [timeout_ms / 1000.0, 1.0].max
            user = uri.user || ENV["FTP_USER"] || "anonymous"
            pass = uri.password || ENV["FTP_PASSWORD"] || "anonymous@"
            ftp.login(user, pass)
            path = uri.path.to_s
            raise APIError.new("FTP path is required", uri: uri.to_s) if path.empty? || path == "/"

            ftp.retrbinary("RETR #{path}", 16_384) { |chunk| body << chunk }
          ensure
            ftp.close unless ftp.closed?
          end
        end
        body
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{uri.host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: uri, target: "FTP server")
      rescue StandardError => e
        if e.class.name.start_with?("Net::FTP")
          raise APIError.new("FTP Error: #{e.message}", uri: uri.to_s)
        end
        raise e
      end

      def fetch_sftp(uri, timeout_ms:)
        begin
          require "net/sftp"
        rescue LoadError
          raise ConfigurationError, "SFTP support requires the 'net-sftp' gem."
        end

        user = uri.user || ENV["SFTP_USER"]
        password = uri.password || ENV["SFTP_PASSWORD"]
        raise ConfigurationError, "SFTP requires username (sftp://user@host/path or SFTP_USER)." unless user

        path = uri.path.to_s
        raise APIError.new("SFTP path is required", uri: uri.to_s) if path.empty? || path == "/"

        result = nil
        Timeout.timeout(timeout_ms / 1000.0) do
          Net::SFTP.start(uri.host, user, password: password, port: (uri.port || 22), non_interactive: true, verify_host_key: :never) do |sftp|
            result = sftp.download!(path)
          end
        end
        result.to_s
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{uri.host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: uri, target: "SFTP server")
      rescue StandardError => e
        raise e if e.is_a?(ConfigurationError)
        if e.class.name.include?("StatusException")
          description = e.respond_to?(:description) ? e.description : e.message
          raise APIError.new("SFTP Error: #{description}", uri: uri.to_s)
        end
        if e.class.name.include?("AuthenticationFailed")
          raise APIError.new("SFTP authentication failed", uri: uri.to_s)
        end
        raise APIError.new("SFTP Error: #{e.message}", uri: uri.to_s)
      end

      def fetch_smb(uri, timeout_ms:)
        share, remote_path = parse_smb_path(uri)
        user = uri.user || ENV["SMB_USER"]
        pass = uri.password || ENV["SMB_PASSWORD"]
        domain = ENV["SMB_DOMAIN"]

        auth = if user
          full_user = domain && !domain.empty? ? "#{domain}\\#{user}" : user
          "#{full_user}%#{pass}"
        else
          nil
        end

        escaped_remote = remote_path.gsub('"', '\"')
        cmd = ["smbclient", "//#{uri.host}/#{share}", "-c", %(get "#{escaped_remote}" -)]
        if auth
          cmd << "-U" << auth
        else
          cmd << "-N"
        end

        stdout = +""
        stderr = +""
        status = nil
        Timeout.timeout(timeout_ms / 1000.0) do
          stdout, stderr, status = Open3.capture3(*cmd)
        end

        raise APIError.new("SMB Error: #{stderr.strip.empty? ? 'request failed' : stderr.strip}", uri: uri.to_s) unless status.success?

        stdout
      rescue Errno::ENOENT
        raise ConfigurationError, "SMB support requires 'smbclient' to be installed and available in PATH."
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{uri.host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: uri, target: "SMB server")
      end

      def parse_smb_path(uri)
        segments = uri.path.to_s.split("/").reject(&:empty?)
        share = segments.shift
        remote = segments.join("/")
        raise APIError.new("SMB path must include share and file (smb://host/share/path/file)", uri: uri.to_s) if share.to_s.empty? || remote.empty?

        [share, remote]
      end

      def fetch_gemini(uri, timeout_ms:)
        response_header = nil
        body = +""
        Timeout.timeout(timeout_ms / 1000.0) do
          tcp = TCPSocket.new(uri.host, uri.port || 1965)
          begin
            ctx = OpenSSL::SSL::SSLContext.new
            ctx.verify_mode = ENV["GEMINI_INSECURE"] == "1" ? OpenSSL::SSL::VERIFY_NONE : OpenSSL::SSL::VERIFY_PEER
            ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
            ssl.hostname = uri.host if ssl.respond_to?(:hostname=)
            ssl.connect
            ssl.write("#{uri}\r\n")
            response_header = ssl.gets("\r\n")
            body = ssl.read.to_s
            ssl.close
          ensure
            tcp.close unless tcp.closed?
          end
        end

        unless response_header
          raise APIError.new("Gemini response error: empty response header", uri: uri.to_s)
        end

        status, meta = response_header.strip.split(/\s+/, 2)
        status_code = status.to_i
        case status_code
        when 20..29
          body
        when 30..39
          raise APIError.new("Gemini redirect (#{status_code}): #{meta}", status_code: status_code, uri: uri.to_s)
        when 40..49
          raise APIError.new("Gemini temporary failure (#{status_code}): #{meta}", status_code: status_code, uri: uri.to_s)
        when 50..59
          raise APIError.new("Gemini permanent failure (#{status_code}): #{meta}", status_code: status_code, uri: uri.to_s)
        when 60..69
          raise APIError.new("Gemini certificate required (#{status_code}): #{meta}", status_code: status_code, uri: uri.to_s)
        else
          raise APIError.new("Gemini response error (#{status_code}): #{meta}", status_code: status_code, uri: uri.to_s)
        end
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{uri.host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, OpenSSL::SSL::SSLError, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: uri, target: "Gemini server")
      end

      def gemtext_to_markdown(gemtext, base_uri)
        lines = gemtext.to_s.split("\n")
        out = lines.map do |line|
          if line.start_with?("=>")
            target, *label_parts = line.sub(/\A=>\s*/, "").split(/\s+/)
            label = label_parts.join(" ").strip
            next "" if target.to_s.empty?
            resolved = resolve_relative_uri(base_uri, target)
            display = label.empty? ? resolved : label
            "- [#{display}](#{resolved})"
          elsif line.start_with?("### ")
            "### #{line[4..].to_s.strip}"
          elsif line.start_with?("## ")
            "## #{line[3..].to_s.strip}"
          elsif line.start_with?("# ")
            "# #{line[2..].to_s.strip}"
          elsif line.start_with?("> ")
            "> #{line[2..].to_s}"
          else
            line
          end
        end
        out.join("\n")
      end

      def resolve_relative_uri(base_uri, target)
        target_uri = URI.parse(target)
        return target if target_uri.scheme

        URI.join(base_uri.to_s, target).to_s
      rescue URI::InvalidURIError
        target
      end

      def resolve_ipfs_url(uri)
        gateway = ENV["IPFS_GATEWAY"] || "https://ipfs.io"
        gateway = gateway.sub(%r{/+\z}, "")
        parsed_gateway = URI.parse(gateway)
        unless %w[http https].include?(parsed_gateway.scheme)
          raise ConfigurationError, "IPFS_GATEWAY must use http or https, got: #{parsed_gateway.scheme.inspect}"
        end

        cid = uri.host.to_s
        path = uri.path.to_s
        query = uri.query ? "?#{uri.query}" : ""
        "#{gateway}/ipfs/#{cid}#{path}#{query}"
      rescue URI::InvalidURIError
        raise ConfigurationError, "IPFS_GATEWAY has invalid format: #{gateway.inspect}"
      end

      def load_teplo_core!
        return if defined?(TeploCore)

        require "teplo_core"
      rescue LoadError
        local = File.expand_path("../../../textplorer/core-ruby/lib/teplo_core", __dir__)
        if File.exist?("#{local}.rb")
          require local
        else
          raise ConfigurationError, "web_url_read requires teplo_core. Install the gem or provide textplorer/core-ruby in the expected workspace location."
        end
      end

      def apply_options(markdown, start_char:, max_length:, section:, paragraph_range:, read_headings:)
        result = markdown.to_s
        return extract_headings(result) if read_headings

        if section && !section.strip.empty?
          section_text = extract_section(result, section)
          result = section_text.empty? ? %(Section "#{section}" not found in the content.) : section_text
        end

        if paragraph_range && !paragraph_range.strip.empty?
          paragraph_text = extract_paragraph_range(result, paragraph_range)
          result = paragraph_text.empty? ? %(Paragraph range "#{paragraph_range}" is invalid or out of bounds.) : paragraph_text
        end

        start = [start_char.to_i, 0].max
        result = start >= result.length ? "" : result[start..]

        if max_length
          max = max_length.to_i
          result = result[0, max] if max.positive?
        end
        result
      end

      def extract_section(markdown, heading)
        lines = markdown.split("\n")
        section_regex = /^\#{1,6}\s*.*#{Regexp.escape(heading)}.*$/i

        start_index = -1
        current_level = 0
        lines.each_with_index do |line, idx|
          next unless line.match?(section_regex)

          start_index = idx
          current_level = line[/^#+/].to_s.length
          break
        end
        return "" if start_index < 0

        end_index = lines.length
        lines[(start_index + 1)..]&.each_with_index do |line, offset|
          level = line[/^#+/].to_s.length
          next if level.zero? || level > current_level

          end_index = start_index + 1 + offset
          break
        end

        lines[start_index...end_index].join("\n")
      end

      def extract_paragraph_range(markdown, range)
        paragraphs = markdown.split(/\n{2,}/).map(&:strip).reject(&:empty?)
        match = range.to_s.strip.match(/\A(\d+)(?:-(\d*))?\z/)
        return "" unless match

        start = match[1].to_i - 1
        return "" if start.negative? || start >= paragraphs.length

        if match[2].nil?
          paragraphs[start].to_s
        elsif match[2].empty?
          paragraphs[start..].join("\n\n")
        else
          ending = match[2].to_i
          paragraphs[start...ending].join("\n\n")
        end
      end

      def extract_headings(markdown)
        headings = markdown.split("\n").select { |line| line.match?(/^\#{1,6}\s+/) }
        headings.empty? ? "No headings found in the content." : headings.join("\n")
      end
    end

    class ServerConfigResource < FastMcp::Resource
      uri "config://server-config"
      resource_name "Server Configuration"
      description "Current SearXNG MCP server configuration and capabilities"
      mime_type "application/json"

      def content
        searxng_url = ENV["SEARXNG_URL"].to_s
        user = ENV["SEARXNG_USER"] || ENV["AUTH_USERNAME"]
        password = ENV["SEARXNG_PASSWORD"] || ENV["AUTH_PASSWORD"]
        config = {
          server_info: {
            name: "searxng",
            version: Searxng::VERSION
          },
          environment: {
            searxng_url: safe_url(searxng_url),
            has_auth: !!(user && password),
            has_proxy: !!(ENV["HTTP_PROXY"] || ENV["HTTPS_PROXY"] || ENV["http_proxy"] || ENV["https_proxy"]),
            has_no_proxy: !!(ENV["NO_PROXY"] || ENV["no_proxy"])
          },
          capabilities: {
            tools: %w[searxng_web_search web_url_read],
            resources: %w[config://server-config help://usage-guide],
            transport: ["stdio"]
          }
        }
        JSON.pretty_generate(config)
      end

      private

      def safe_url(raw)
        return "(not configured)" if raw.nil? || raw.strip.empty?

        uri = URI.parse(raw)
        uri.user = nil
        uri.password = nil
        uri.to_s
      rescue URI::InvalidURIError
        "(invalid URL)"
      end
    end

    class UsageGuideResource < FastMcp::Resource
      uri "help://usage-guide"
      resource_name "Usage Guide"
      description "Short guide for using SearXNG MCP tools and environment variables"
      mime_type "text/markdown"

      def content
        <<~MD
          # SearXNG MCP Server Help

          ## Tools
          1. `searxng_web_search` - Search the web via SearXNG.
          2. `web_url_read` - Fetch a URL and return Markdown-converted content.

          ## Required Environment
          - `SEARXNG_URL` (must be `http://` or `https://`)

          ## Optional Environment
          - `SEARXNG_USER` and `SEARXNG_PASSWORD` (or `AUTH_USERNAME` and `AUTH_PASSWORD`)
          - `HTTP_PROXY` / `HTTPS_PROXY`
          - `ALL_PROXY` (for shared proxy config)
          - `NO_PROXY`
          - `FTP_USER` / `FTP_PASSWORD` (optional FTP credentials)
          - `SFTP_USER` / `SFTP_PASSWORD` (optional SFTP credentials)
          - `SMB_USER` / `SMB_PASSWORD` / `SMB_DOMAIN` (optional SMB credentials)
          - `IPFS_GATEWAY` (default: `https://ipfs.io`)
          - `GEMINI_INSECURE=1` (optional, disables TLS verification for Gemini)

          ## Protocol Notes
          - `http` / `https`: fully supported (`searxng_web_search` + `web_url_read`)
          - `ftp`: supported in `web_url_read` (file retrieval via FTP)
          - `sftp`: supported in `web_url_read` (requires `net-sftp` gem)
          - `smb`: supported in `web_url_read` via `smbclient` command
          - `gemini`: supported in `web_url_read` (Gemini fetch + Gemtext conversion)
          - `spartan`: currently not supported directly (use a bridge/gateway)
          - `ipfs`: supported via HTTP gateway mapping (`ipfs://...` -> `IPFS_GATEWAY`)
          - `tor` / `i2p`: supported via `.onion` / `.i2p` hosts over HTTP(S) with proxy configuration
          - `socks5`: configure via proxy environment and run through a local bridge/proxy compatible with your client setup

          ## Examples
          - Search: `{"query":"latest ruby news","time_range":"day"}`
          - Read URL: `{"url":"https://example.com","section":"Introduction","maxLength":2000}`
          - Read FTP: `{"url":"ftp://ftp.example.com/path/file.txt"}`
          - Read SFTP: `{"url":"sftp://user@example.com/path/file.txt"}`
          - Read SMB: `{"url":"smb://fileserver/share/path/file.txt"}`
          - Read Gemini: `{"url":"gemini://geminiprotocol.net"}`
          - Read IPFS: `{"url":"ipfs://bafybeigdyrzt.../index.html"}`
        MD
      end
    end
  end
end
