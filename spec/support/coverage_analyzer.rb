# Coverage Analyzer - Shows lines with zero hits from coverage.xml
# Usage: Set SHOW_ZERO_COVERAGE=1 before running rspec
#
# This script parses coverage.xml (SimpleCov's final merged output) to get
# accurate coverage data and displays all uncovered lines (0 hits) in file:line format.
# It waits for coverage.xml to be created/updated after tests complete.
#
# Note: For accurate coverage measurement, run all tests without --fail-fast:
#   SHOW_ZERO_COVERAGE=1 bundle exec rspec

require "rexml/document"

module CoverageAnalyzer
  COVERAGE_XML_PATH = "coverage/coverage.xml"
  MAX_WAIT_SECONDS = 30
  WAIT_INTERVAL = 0.2

  def self.run
    return unless ENV["SHOW_ZERO_COVERAGE"] == "1"

    wait_for_coverage_file

    unless File.exist?(COVERAGE_XML_PATH)
      warn "⚠️  Coverage XML not found at #{COVERAGE_XML_PATH}"
      warn "   Run rspec first to generate coverage data"
      return
    end

    uncovered = extract_uncovered_lines
    return if uncovered.empty?

    uncovered.sort_by { |e| [e[:file], e[:line]] }.each do |line_info|
      puts "#{line_info[:file]}:#{line_info[:line]}"
    end
  end

  def self.wait_for_coverage_file
    return if File.exist?(COVERAGE_XML_PATH)

    elapsed = 0.0
    while !File.exist?(COVERAGE_XML_PATH) && elapsed < MAX_WAIT_SECONDS
      sleep(WAIT_INTERVAL)
      elapsed += WAIT_INTERVAL
    end
  end

  def self.extract_uncovered_lines
    uncovered = []
    xml_content = File.read(COVERAGE_XML_PATH)
    doc = REXML::Document.new(xml_content)

    doc.elements.each("//class") do |class_elem|
      filename = class_elem.attributes["filename"]
      next unless filename&.start_with?("lib/")

      class_elem.elements.each("lines/line") do |line_elem|
        hits = line_elem.attributes["hits"].to_i
        line_num = line_elem.attributes["number"].to_i
        uncovered << {file: filename, line: line_num} if hits == 0
      end
    end

    uncovered
  end

  private_class_method :wait_for_coverage_file, :extract_uncovered_lines
end
