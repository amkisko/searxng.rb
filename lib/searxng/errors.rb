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
end
