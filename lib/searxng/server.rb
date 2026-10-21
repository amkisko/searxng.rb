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
require "searxng/network_policy"

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
      CACHE_MAX_ENTRIES = 32
      CACHE_MAX_BYTES = 8 * 1024 * 1024
      MAX_FETCH_BYTES = 2 * 1024 * 1024
      DEFAULT_MAX_LENGTH = 20_000
      MIN_TIMEOUT_MS = 1_000
      MAX_TIMEOUT_MS = 30_000
      DEFAULT_URL_SCHEMES = %w[http https ipfs].freeze
      SUPPORTED_URL_SCHEMES = %w[http https ftp sftp smb gemini ipfs].freeze
      @@url_cache = {} # rubocop:disable Style/ClassVars
      @@url_cache_bytes = 0 # rubocop:disable Style/ClassVars
      @@url_cache_mutex = Mutex.new # rubocop:disable Style/ClassVars

      arguments do
        required(:url).filled(:string).description("URL to fetch and read")
        optional(:startChar).filled(:integer).description("Starting character position (default: 0)")
        optional(:maxLength).filled(:integer).description("Maximum characters to return (default: 20000)")
        optional(:section).filled(:string).description("Extract by heading text")
        optional(:paragraphRange).filled(:string).description("Paragraph range, e.g. '1-5', '3', '10-'")
        optional(:readHeadings).filled(:bool).description("Return only headings when true")
        optional(:timeoutMs).filled(:integer).description("Request timeout in ms (default: 10000, clamped 1000..30000)")
      end

      def call(url:, **kwargs)
        start_char = kwargs.fetch(:startChar, 0)
        max_length = kwargs.fetch(:maxLength, DEFAULT_MAX_LENGTH)
        section = kwargs[:section]
        paragraph_range = kwargs[:paragraphRange]
        read_headings = kwargs.fetch(:readHeadings, false)
        timeout_ms = clamp_timeout_ms(kwargs.fetch(:timeoutMs, 10_000))

        normalized = normalize_url(url)
        uri = URI.parse(normalized)
        ensure_scheme_enabled!(uri.scheme)
        unless uri.scheme == "ipfs"
          _validated_uri, ip_address = NetworkPolicy.validate!(
            normalized,
            allowed_schemes: [uri.scheme],
            allow_userinfo: !%w[http https].include?(uri.scheme)
          )
        end
        markdown = case uri.scheme
        when "http", "https"
          html = fetch_html(normalized, timeout_ms: timeout_ms)
          convert_to_markdown(html, redact_uri_string(normalized))
        when "ftp"
          content = fetch_ftp(uri, ip_address: ip_address, timeout_ms: timeout_ms)
          convert_fetched_content(content, redact_uri_string(normalized))
        when "sftp"
          content = fetch_sftp(uri, ip_address: ip_address, timeout_ms: timeout_ms)
          convert_fetched_content(content, redact_uri_string(normalized))
        when "smb"
          content = fetch_smb(uri, ip_address: ip_address, timeout_ms: timeout_ms)
          convert_fetched_content(content, redact_uri_string(normalized))
        when "gemini"
          gemtext = fetch_gemini(uri, ip_address: ip_address, timeout_ms: timeout_ms)
          gemtext_to_markdown(gemtext, uri)
        when "ipfs"
          gateway_url = resolve_ipfs_url(uri)
          html = fetch_html(gateway_url, timeout_ms: timeout_ms)
          convert_to_markdown(html, gateway_url)
        else
          raise ConfigurationError, %(Unsupported URL scheme "#{uri.scheme}". Supported schemes: http, https, ftp, sftp, smb, gemini, ipfs.)
        end
        apply_options(markdown, start_char: start_char, max_length: max_length, section: section, paragraph_range: paragraph_range, read_headings: read_headings)
      rescue Searxng::Error => e
        "Error: #{e.message}"
      end

      private

      def normalize_url(url)
        raw = url.to_s.strip
        uri = URI.parse(raw)
        if uri.scheme
          scheme = uri.scheme.downcase
          return raw if uri.host && %w[http https ftp sftp smb gemini ipfs].include?(scheme)

          raise ConfigurationError, %(Unsupported URL scheme "#{uri.scheme}". Supported schemes: http, https, ftp, sftp, smb, gemini, ipfs.)
        end

        candidate = "https://#{raw}"
        parsed = URI.parse(candidate)
        return candidate if parsed.host

        raise ArgumentError
      rescue URI::InvalidURIError, ArgumentError
        raise ConfigurationError, %(URL Format Error: Invalid URL "#{url}")
      end

      def ensure_scheme_enabled!(scheme)
        return if enabled_url_schemes.include?(scheme)

        raise ConfigurationError, %(URL scheme "#{scheme}" is not enabled)
      end

      def enabled_url_schemes
        configured = ENV["SEARXNG_WEB_URL_SCHEMES"]
        return DEFAULT_URL_SCHEMES unless configured

        configured.split(",").map { |scheme| scheme.strip.downcase } & SUPPORTED_URL_SCHEMES
      end

      def clamp_timeout_ms(value)
        value.to_i.clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
      end

      def redact_uri_string(url)
        uri = url.is_a?(URI) ? url.dup : URI.parse(url.to_s)
        uri.user = nil
        uri.password = nil
        uri.to_s
      rescue URI::InvalidURIError
        "(invalid URL)"
      end

      def fetch_html(url, timeout_ms:)
        now = Time.now.to_i
        cached = cache_get(url, now: now)
        return cached if cached

        uri, ip_address = NetworkPolicy.validate!(url, allowed_schemes: %w[http https])
        client = get_client
        http = build_fetch_http(client, uri, ip_address, timeout_ms: timeout_ms)
        request = Net::HTTP::Get.new(uri.request_uri)
        request["Host"] = uri.hostname || uri.host
        request["User-Agent"] = ENV["SEARXNG_USER_AGENT"].to_s.strip.empty? ? "searxng-ruby/#{Searxng::VERSION} web_url_read" : ENV["SEARXNG_USER_AGENT"]
        request["Accept-Encoding"] = "identity"
        safe_url = redact_uri_string(url)
        body = nil
        status_code = nil
        status_message = nil
        location = nil
        Timeout.timeout(timeout_ms / 1000.0) do
          http.request(request) do |response|
            status_code = response.code.to_i
            status_message = response.message
            location = response["location"]
            unless response.is_a?(Net::HTTPSuccess)
              read_limited_body(response)
              raise APIError.new(
                ErrorMessages.fetch_http_error(status_code, status_message, location: location),
                status_code: status_code,
                uri: safe_url
              )
            end
            body = read_limited_body(response)
          end
        end
        if body.to_s.strip.empty?
          raise APIError.new("Content Error: Website returned empty content.", status_code: status_code, uri: safe_url)
        end

        cache_put(url, body, at: now)
        body
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{URI.parse(url).host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, OpenSSL::SSL::SSLError, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: URI.parse(url), target: "website")
      end

      def build_fetch_http(client, uri, ip_address, timeout_ms:)
        proxy_uri = client.send(:proxy_uri_for, uri)
        seconds = [timeout_ms / 1000.0, 1.0].max
        if proxy_uri && uri.scheme == "http"
          http = Net::HTTP::Proxy(proxy_uri.host, proxy_uri.port, proxy_uri.user, proxy_uri.password)
            .new(ip_address, uri.port)
          http.open_timeout = seconds
          http.read_timeout = seconds
          http.max_retries = 0 if http.respond_to?(:max_retries=)
          return http
        end

        http = client.send(:build_http, uri)
        http.ipaddr = ip_address
        http.open_timeout = seconds
        http.read_timeout = seconds
        http.max_retries = 0 if http.respond_to?(:max_retries=)
        http
      end

      def read_limited_body(response)
        body = +""
        response.read_body do |chunk|
          body << chunk
          if body.bytesize > MAX_FETCH_BYTES
            raise APIError.new("Content Error: response exceeds #{MAX_FETCH_BYTES} bytes", uri: nil)
          end
        end
        body
      end

      def cache_get(url, now:)
        @@url_cache_mutex.synchronize do
          purge_expired_cache!(now)
          entry = @@url_cache[url]
          (entry && (now - entry[:at] <= CACHE_TTL_SECONDS)) ? entry[:html] : nil
        end
      end

      def cache_put(url, html, at:)
        @@url_cache_mutex.synchronize do
          purge_expired_cache!(at)
          while (@@url_cache.size >= CACHE_MAX_ENTRIES || (@@url_cache_bytes + html.bytesize) > CACHE_MAX_BYTES) && !@@url_cache.empty?
            evict_oldest_cache_entry!
          end
          return if html.bytesize > CACHE_MAX_BYTES

          previous = @@url_cache[url]
          @@url_cache_bytes -= previous[:html].bytesize if previous
          @@url_cache[url] = {at: at, html: html}
          @@url_cache_bytes += html.bytesize
        end
      end

      def purge_expired_cache!(now)
        @@url_cache.delete_if do |_key, entry|
          expired = now - entry[:at] > CACHE_TTL_SECONDS
          @@url_cache_bytes -= entry[:html].bytesize if expired
          expired
        end
      end

      def evict_oldest_cache_entry!
        oldest_key, oldest = @@url_cache.min_by { |_key, entry| entry[:at] }
        return unless oldest_key

        @@url_cache_bytes -= oldest[:html].bytesize
        @@url_cache.delete(oldest_key)
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
      rescue Searxng::Error
        raise
      rescue => e
        raise APIError.new("Conversion Error: Cannot convert HTML to Markdown (#{base_url}) - #{e.message}", uri: base_url)
      end

      def convert_fetched_content(content, base_url)
        text = content.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
        return text if text.strip.empty?

        looks_like_markup = text.match?(/\A\s*<(?:!doctype|html|body|xml|rss|feed|svg|\?xml)/i)
        looks_like_markup ? convert_to_markdown(text, base_url) : text
      end

      def fetch_ftp(uri, timeout_ms:, ip_address: nil)
        begin
          require "net/ftp"
        rescue LoadError
          raise ConfigurationError, "FTP support requires the 'net-ftp' gem."
        end

        ip_address ||= validated_ip_address(uri, allow_userinfo: true)
        body = +""
        ftp = nil
        safe_uri = redact_uri_string(uri)
        Timeout.timeout(timeout_ms / 1000.0) do
          ftp = Net::FTP.new
          ftp.passive = true
          ftp.use_pasv_ip = false if ftp.respond_to?(:use_pasv_ip=)
          begin
            ftp.connect(ip_address, uri.port || 21)
            ftp.read_timeout = [timeout_ms / 1000.0, 1.0].max
            ftp.open_timeout = [timeout_ms / 1000.0, 1.0].max
            user = uri.user || credential_for(uri.host, "FTP_USER") || "anonymous"
            pass = uri.password || credential_for(uri.host, "FTP_PASSWORD") || "anonymous@"
            ftp.login(user, pass)
            path = URI.decode_www_form_component(uri.path.to_s)
            raise APIError.new("FTP path is required", uri: safe_uri) if path.empty? || path == "/"
            raise ConfigurationError, "FTP path contains unsupported characters" if path.match?(/[\r\n\x00]/)

            ftp.retrbinary("RETR #{path}", 16_384) do |chunk|
              body << chunk
              if body.bytesize > MAX_FETCH_BYTES
                raise APIError.new("Content Error: response exceeds #{MAX_FETCH_BYTES} bytes", uri: safe_uri)
              end
            end
          ensure
            ftp&.close unless ftp.nil? || ftp.closed?
          end
        end
        body
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{uri.host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: uri, target: "FTP server")
      rescue Searxng::Error
        raise
      rescue => e
        if e.class.name.start_with?("Net::FTP")
          raise APIError.new("FTP Error: #{e.message}", uri: redact_uri_string(uri))
        end
        raise e
      end

      def fetch_sftp(uri, timeout_ms:, ip_address: nil)
        begin
          require "net/sftp"
        rescue LoadError
          raise ConfigurationError, "SFTP support requires the 'net-sftp' gem."
        end

        ip_address ||= validated_ip_address(uri, allow_userinfo: true)
        user = uri.user || credential_for(uri.host, "SFTP_USER")
        password = uri.password || credential_for(uri.host, "SFTP_PASSWORD")
        raise ConfigurationError, "SFTP requires username (sftp://user@host/path or SFTP_USER)." unless user

        path = URI.decode_www_form_component(uri.path.to_s)
        safe_uri = redact_uri_string(uri)
        raise APIError.new("SFTP path is required", uri: safe_uri) if path.empty? || path == "/"
        raise ConfigurationError, "SFTP path contains unsupported characters" if path.match?(/[\r\n\x00]/)

        result = nil
        Timeout.timeout(timeout_ms / 1000.0) do
          options = {password: password, port: uri.port || 22, non_interactive: true, verify_host_key: :always}
          options[:host_key_alias] = uri.host if uri.host
          Net::SFTP.start(ip_address, user, **options) do |sftp|
            result = sftp.download!(path).to_s
          end
        end
        if result.to_s.bytesize > MAX_FETCH_BYTES
          raise APIError.new("Content Error: response exceeds #{MAX_FETCH_BYTES} bytes", uri: safe_uri)
        end
        result.to_s
      rescue Timeout::Error
        raise NetworkError, "Timeout Error: #{uri.host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: uri, target: "SFTP server")
      rescue Searxng::Error
        raise
      rescue => e
        raise e if e.is_a?(ConfigurationError)
        if e.class.name.include?("StatusException")
          description = e.respond_to?(:description) ? e.description : e.message
          raise APIError.new("SFTP Error: #{description}", uri: safe_uri)
        end
        if e.class.name.include?("AuthenticationFailed")
          raise APIError.new("SFTP authentication failed", uri: safe_uri)
        end
        raise APIError.new("SFTP Error: #{e.message}", uri: safe_uri)
      end

      def fetch_smb(uri, timeout_ms:, ip_address: nil)
        ip_address ||= validated_ip_address(uri, allow_userinfo: true)
        share, remote_path = parse_smb_path(uri)
        user = uri.user || credential_for(uri.host, "SMB_USER")
        pass = uri.password || credential_for(uri.host, "SMB_PASSWORD")
        domain = credential_for(uri.host, "SMB_DOMAIN")

        full_user = if user
          (domain && !domain.empty?) ? "#{domain}\\#{user}" : user
        end

        cmd = ["smbclient", "//#{ip_address}/#{share}", "-c", %(get "#{remote_path}" -), "-t", [(timeout_ms / 1000.0).ceil, 1].max.to_s]
        env = {}
        if full_user
          cmd << "-U" << full_user
          env["PASSWD"] = pass.to_s
        else
          cmd << "-N"
        end

        stdout = +""
        stderr = +""
        status = nil
        wait_thr = nil
        Timeout.timeout(timeout_ms / 1000.0) do
          Open3.popen3(env, *cmd) do |stdin, out, err, thr|
            stdin.close
            wait_thr = thr
            stdout = out.read.to_s
            stderr = err.read.to_s
            status = thr.value
          end
        end
        if stdout.bytesize > MAX_FETCH_BYTES
          raise APIError.new("Content Error: response exceeds #{MAX_FETCH_BYTES} bytes", uri: redact_uri_string(uri))
        end

        raise APIError.new("SMB Error: #{stderr.strip.empty? ? "request failed" : stderr.strip[0, 500]}", uri: redact_uri_string(uri)) unless status&.success?

        stdout
      rescue Errno::ENOENT
        raise ConfigurationError, "SMB support requires 'smbclient' to be installed and available in PATH."
      rescue Timeout::Error
        if wait_thr&.alive?
          begin
            Process.kill("TERM", wait_thr.pid)
          rescue Errno::ESRCH
          end
        end
        raise NetworkError, "Timeout Error: #{uri.host} took longer than #{timeout_ms}ms to respond"
      rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, EOFError => e
        raise NetworkError, ErrorMessages.network_error(e, uri: uri, target: "SMB server")
      end

      def parse_smb_path(uri)
        raw_path = uri.path.to_s
        segments = raw_path.split("/").reject(&:empty?).map { |segment| URI.decode_www_form_component(segment) }
        share = segments.shift
        remote = segments.join("/")
        raise APIError.new("SMB path must include share and file (smb://host/share/path/file)", uri: redact_uri_string(uri)) if share.to_s.empty? || remote.empty?
        if share.match?(/[\x00-\x1f\x7f;"\\]/) || remote.match?(/[\x00-\x1f\x7f;"\\]/)
          raise ConfigurationError, "SMB path contains unsupported characters"
        end

        [share, remote]
      end

      def fetch_gemini(uri, timeout_ms:, ip_address: nil)
        ip_address ||= validated_ip_address(uri)
        response_header = nil
        body = +""
        tcp = nil
        ssl = nil
        safe_uri = redact_uri_string(uri)
        Timeout.timeout(timeout_ms / 1000.0) do
          tcp = TCPSocket.new(ip_address, uri.port || 1965)
          begin
            ctx = OpenSSL::SSL::SSLContext.new
            if ENV["GEMINI_INSECURE"] == "1"
              ctx.verify_mode = OpenSSL::SSL::VERIFY_NONE
            else
              ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
            end
            ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
            ssl.hostname = uri.host if ssl.respond_to?(:hostname=)
            ssl.connect
            ssl.post_connection_check(uri.host) unless ENV["GEMINI_INSECURE"] == "1"
            ssl.write("#{uri}\r\n")
            response_header = ssl.gets("\r\n", 2048)
            while body.bytesize <= MAX_FETCH_BYTES
              chunk = ssl.read(16_384)
              break if chunk.nil? || chunk.empty?
              body << chunk
            end
            raise APIError.new("Content Error: response exceeds #{MAX_FETCH_BYTES} bytes", uri: safe_uri) if body.bytesize > MAX_FETCH_BYTES
          ensure
            ssl&.close
            tcp&.close unless tcp.nil? || tcp.closed?
          end
        end

        unless response_header
          raise APIError.new("Gemini response error: empty response header", uri: safe_uri)
        end

        status, meta = response_header.strip.split(/\s+/, 2)
        status_code = status.to_i
        case status_code
        when 20..29
          body
        when 30..39
          raise APIError.new("Gemini redirect (#{status_code}): #{meta}", status_code: status_code, uri: safe_uri)
        when 40..49
          raise APIError.new("Gemini temporary failure (#{status_code}): #{meta}", status_code: status_code, uri: safe_uri)
        when 50..59
          raise APIError.new("Gemini permanent failure (#{status_code}): #{meta}", status_code: status_code, uri: safe_uri)
        when 60..69
          raise APIError.new("Gemini certificate required (#{status_code}): #{meta}", status_code: status_code, uri: safe_uri)
        else
          raise APIError.new("Gemini response error (#{status_code}): #{meta}", status_code: status_code, uri: safe_uri)
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
            "> #{line[2..]}"
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
      rescue URI::Error
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
        unless cid.match?(/\A[a-zA-Z0-9_-]+\z/)
          raise ConfigurationError, "IPFS CID is invalid"
        end

        path = uri.path.to_s
        segments = path.split("/").reject(&:empty?)
        segments.each do |segment|
          decoded = URI.decode_www_form_component(segment)
          if decoded == "." || decoded == ".." || decoded.include?("\0")
            raise ConfigurationError, "IPFS path is not allowed"
          end
        end

        query = uri.query ? "?#{uri.query}" : ""
        "#{gateway}/ipfs/#{cid}#{path}#{query}"
      rescue URI::InvalidURIError
        raise ConfigurationError, "IPFS_GATEWAY has invalid format: #{gateway.inspect}"
      end

      def credential_for(host, variable)
        allowed_hosts = ENV["SEARXNG_WEB_URL_CREDENTIAL_HOSTS"].to_s
          .split(",")
          .map { |candidate| candidate.strip.downcase }
        ENV[variable] if allowed_hosts.include?(host.downcase)
      end

      def validated_ip_address(uri, allow_userinfo: false)
        NetworkPolicy.validate!(
          uri.to_s,
          allowed_schemes: [uri.scheme],
          allow_userinfo: allow_userinfo
        )[1]
      end

      def load_teplo_core!
        return if defined?(TeploCore)

        require "teplo_core"
      rescue LoadError
        local = File.expand_path("../../../textplorer/core-ruby/lib/teplo_core", __dir__)
        if File.exist?("#{local}.rb")
          require local
        else
          raise ConfigurationError, "web_url_read requires the teplo_core gem for HTML to Markdown conversion."
        end
      end

      def apply_options(markdown, start_char:, max_length:, section:, paragraph_range:, read_headings:)
        result = markdown.to_s
        return extract_headings(result) if read_headings

        if section && !section.strip.empty?
          section_text = extract_section(result, section)
          return %(Section "#{section}" not found in the content.) if section_text.empty?

          result = section_text
        end

        if paragraph_range && !paragraph_range.strip.empty?
          paragraph_text = extract_paragraph_range(result, paragraph_range)
          return %(Paragraph range "#{paragraph_range}" is invalid or out of bounds.) if paragraph_text.empty?

          result = paragraph_text
        end

        start = [start_char.to_i, 0].max
        result = (start >= result.length) ? "" : result[start..]

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
            has_proxy: !!(ENV["HTTP_PROXY"] || ENV["HTTPS_PROXY"] || ENV["http_proxy"] || ENV["https_proxy"] || ENV["ALL_PROXY"] || ENV["all_proxy"]),
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
          - `SEARXNG_WEB_URL_SCHEMES` (comma-separated opt-in protocols; default: `http,https,ipfs`)
          - `SEARXNG_WEB_URL_CREDENTIAL_HOSTS` (comma-separated hosts allowed to receive environment credentials)
          - `FTP_USER` / `FTP_PASSWORD` (optional credentials for allowlisted hosts)
          - `SFTP_USER` / `SFTP_PASSWORD` (optional credentials for allowlisted hosts)
          - `SMB_USER` / `SMB_PASSWORD` / `SMB_DOMAIN` (optional credentials for allowlisted hosts)
          - `IPFS_GATEWAY` (default: `https://ipfs.io`)
          - `GEMINI_INSECURE=1` (optional, disables TLS verification for Gemini)

          ## Protocol Notes
          - `http` / `https`: fully supported (`searxng_web_search` + `web_url_read`)
          - `ftp`: opt-in through `SEARXNG_WEB_URL_SCHEMES` (file retrieval via FTP)
          - `sftp`: opt-in through `SEARXNG_WEB_URL_SCHEMES` (requires `net-sftp` gem)
          - `smb`: opt-in through `SEARXNG_WEB_URL_SCHEMES` via `smbclient`
          - `gemini`: opt-in through `SEARXNG_WEB_URL_SCHEMES` (Gemini fetch + Gemtext conversion)
          - `ipfs`: supported via HTTP gateway mapping (`ipfs://...` -> `IPFS_GATEWAY`)
          - `.onion` / `.i2p`: not supported by `web_url_read` (local DNS and destination policy run before any proxy)
          - `socks5`: may work for SearXNG search via proxy env; not a bypass for `web_url_read` destination policy

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
