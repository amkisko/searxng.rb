require "uri"
require "net/http"
require "openssl"
require "json"

module Searxng
  class Client
    DEFAULT_BASE_URL = "http://localhost:8080"
    DEFAULT_USER_AGENT = "searxng-ruby/#{Searxng::VERSION} (https://github.com/amkisko/searxng.rb)".freeze
    VALID_TIME_RANGES = %w[day month year].freeze
    VALID_SAFESEARCH = [0, 1, 2].freeze

    def initialize(
      base_url: nil,
      user: nil,
      password: nil,
      open_timeout: 10,
      read_timeout: 10,
      ca_file: nil,
      ca_path: nil,
      verify_mode: nil,
      user_agent: nil,
      configure_http: nil
    )
      @base_url = (base_url || ENV["SEARXNG_URL"] || DEFAULT_BASE_URL).to_s.chomp("/")
      @user = user || ENV["SEARXNG_USER"]
      @password = password || ENV["SEARXNG_PASSWORD"]
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @ca_file = ca_file || ENV["SEARXNG_CA_FILE"]
      @ca_path = ca_path || ENV["SEARXNG_CA_PATH"]
      @verify_mode = verify_mode
      @user_agent = user_agent || ENV["SEARXNG_USER_AGENT"] || DEFAULT_USER_AGENT
      @configure_http = configure_http
    end

    def search(query, pageno: 1, time_range: nil, language: "all", safesearch: nil)
      raise ConfigurationError, "SEARXNG_URL not set" if @base_url.nil? || @base_url.empty?

      uri = build_search_uri(query, pageno: pageno, time_range: time_range, language: language, safesearch: safesearch)
      response = perform_request(uri)
      parse_response(response, uri, query)
    end

    private

    def build_search_uri(query, pageno:, time_range:, language:, safesearch:)
      uri = URI.join("#{@base_url}/", "search")
      params = {"q" => query, "format" => "json", "pageno" => pageno.to_s}
      params["time_range"] = time_range if time_range && VALID_TIME_RANGES.include?(time_range.to_s)
      params["language"] = language if language && language != "all"
      params["safesearch"] = safesearch.to_s if safesearch && VALID_SAFESEARCH.include?(safesearch.to_i)
      uri.query = URI.encode_www_form(params)
      uri
    end

    def perform_request(uri)
      http = build_http(uri)
      @configure_http&.call(http, uri)

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = @user_agent
      request.basic_auth(@user, @password) if @user && @password

      http.request(request)
    rescue SocketError, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::ECONNRESET, Errno::EPIPE, Timeout::Error, OpenSSL::SSL::SSLError, EOFError => e
      raise NetworkError, "Connection failed: #{e.message}"
    end

    # Builds and returns a configured Net::HTTP instance. Override in a subclass to customize
    # timeouts, SSL, proxy, or other options. Called once per request.
    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      apply_ssl_config(http) if http.use_ssl?
      http
    end

    def apply_ssl_config(http)
      http.verify_mode = @verify_mode || OpenSSL::SSL::VERIFY_PEER
      default_ca = OpenSSL::X509::DEFAULT_CERT_FILE
      http.ca_file = @ca_file if @ca_file && File.exist?(@ca_file)
      http.ca_file = default_ca if !http.ca_file && File.exist?(default_ca)
      http.ca_path = @ca_path if @ca_path && File.directory?(@ca_path)
    end

    def parse_response(response, uri, query)
      case response
      when Net::HTTPSuccess
        body = response.body
        data = JSON.parse(body)
        {
          query: data["query"] || query,
          number_of_results: data["number_of_results"],
          results: normalize_results(data["results"] || []),
          infoboxes: normalize_infoboxes(data["infoboxes"] || []),
          suggestions: data["suggestions"] || [],
          answers: data["answers"] || [],
          corrections: data["corrections"] || []
        }
      else
        raise APIError.new(
          "SearXNG returned #{response.code} #{response.message}",
          status_code: response.code.to_i,
          response_data: response.body,
          uri: uri.to_s
        )
      end
    rescue JSON::ParserError => e
      raise APIError.new(
        "Invalid JSON response: #{e.message}",
        response_data: response&.body,
        uri: uri.to_s
      )
    end

    def normalize_results(results)
      Array(results).map do |r|
        {
          title: r["title"].to_s,
          url: r["url"].to_s,
          content: r["content"].to_s,
          score: (r["score"] || 0).to_f
        }
      end
    end

    def normalize_infoboxes(infoboxes)
      Array(infoboxes).map do |ib|
        {
          infobox: ib["infobox"].to_s,
          id: ib["id"].to_s,
          content: ib["content"].to_s,
          urls: Array(ib["urls"]).map { |u| {title: u["title"].to_s, url: u["url"].to_s} }
        }
      end
    end
  end
end
