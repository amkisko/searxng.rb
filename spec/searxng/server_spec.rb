require "spec_helper"
require "searxng/server"

RSpec.describe Searxng::Server do
  describe ".start" do
    it "responds to start" do
      expect(described_class).to respond_to(:start)
    end

    it "creates server with name, version, and NullLogger and registers tool" do
      server_double = instance_double(FastMcp::Server)
      allow(FastMcp::Server).to receive(:new).and_return(server_double)
      allow(server_double).to receive(:register_tool)
      allow(server_double).to receive(:start)

      described_class.start

      expect(FastMcp::Server).to have_received(:new).with(
        name: "searxng",
        version: Searxng::VERSION,
        logger: an_instance_of(Searxng::Server::NullLogger)
      )
      expect(server_double).to have_received(:register_tool).with(Searxng::Server::SearxngWebSearchTool)
      expect(server_double).to have_received(:start)
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
  end
end
