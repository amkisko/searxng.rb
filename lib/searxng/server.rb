require "fast_mcp"
require "searxng"

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
      server = FastMcp::Server.new(
        name: "searxng",
        version: Searxng::VERSION,
        logger: NullLogger.new
      )
      server.register_tool(SearxngWebSearchTool)
      server.start
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
        data[:infoboxes]&.each do |ib|
          out << "Infobox: #{ib[:infobox]}"
          out << "ID: #{ib[:id]}"
          out << "Content: #{ib[:content]}"
          out << ""
        end
        results = data[:results] || []
        total = data[:number_of_results]
        if results.empty?
          out << "No results found"
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
  end
end
