#!/usr/bin/env ruby

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "searxng"

url = ENV["SEARXNG_URL"] || "http://localhost:8080"
client = Searxng::Client.new(base_url: url)

queries = ["ruby programming", "SearXNG metasearch"]
queries.each_with_index do |query, i|
  sleep(2) if i > 0  # avoid limiter when instance rate-limits requests
  puts "=== #{query} ==="
  data = client.search(query)
  data[:results]&.first(3)&.each do |r|
    puts "- #{r[:title]}"
    puts "  #{r[:url]}"
    puts "  #{r[:content][0..120]}..."
  end
  puts ""
end
