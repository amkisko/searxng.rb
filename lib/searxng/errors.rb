module Searxng
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class NetworkError < Error; end

  class APIError < Error
    attr_reader :status_code, :response_data, :uri

    def initialize(message, status_code: nil, response_data: nil, uri: nil)
      super(message)
      @status_code = status_code
      @response_data = response_data
      @uri = uri
    end
  end

  module ErrorMessages
    module_function

    def configuration_missing_url
      "SEARXNG_URL not set. Set it to your SearXNG instance (e.g., http://localhost:8080 or https://search.example.com)"
    end

    def configuration_invalid_url(url)
      "SEARXNG_URL has invalid format: #{url.inspect}. Use format: http://localhost:8080 or https://search.example.com"
    end

    def configuration_invalid_protocol(protocol)
      "SEARXNG_URL must use http or https protocol, got: #{protocol.inspect}"
    end

    def configuration_auth_pair
      "Authentication variables must be set together: SEARXNG_USER with SEARXNG_PASSWORD (or AUTH_USERNAME with AUTH_PASSWORD)"
    end

    def no_results(query)
      %(No results found for "#{query}". Try different search terms or check if SearXNG search engines are working.)
    end

    def network_error(exception, uri: nil, target: "SearXNG server")
      case exception
      when SocketError
        host = uri&.host || "unknown host"
        %(DNS Error: Cannot resolve hostname "#{host}".)
      when Errno::ECONNREFUSED
        "Connection Error: #{target} is not responding."
      when Errno::ETIMEDOUT, Timeout::Error
        "Timeout Error: #{target} is too slow to respond."
      when OpenSSL::SSL::SSLError
        "SSL Error: Certificate or TLS problem while connecting to #{target}."
      else
        message = exception&.message.to_s.strip
        "Network Error: #{message.empty? ? "Connection failed" : message}"
      end
    end

    def api_error(status_code, status_message)
      case status_code.to_i
      when 403
        "SearXNG Error (403): Authentication required or IP blocked."
      when 404
        "SearXNG Error (404): Search endpoint not found."
      when 429
        "SearXNG Error (429): Rate limit exceeded."
      when 500..599
        "SearXNG Error (#{status_code}): Internal server error."
      else
        "SearXNG returned #{status_code} #{status_message}".strip
      end
    end
  end
end
