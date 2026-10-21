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
    return warn_missing_coverage_file unless File.exist?(COVERAGE_XML_PATH)

    print_uncovered_lines(extract_uncovered_lines)
  end

  def self.wait_for_coverage_file
    return if File.exist?(COVERAGE_XML_PATH)

    elapsed = 0.0
    while !File.exist?(COVERAGE_XML_PATH) && elapsed < MAX_WAIT_SECONDS
      sleep(WAIT_INTERVAL)
      elapsed += WAIT_INTERVAL
    end
  end

  def self.warn_missing_coverage_file
    warn "⚠️  Coverage XML not found at #{COVERAGE_XML_PATH}"
    warn "   Run rspec first to generate coverage data"
  end

  def self.print_uncovered_lines(uncovered_lines)
    return if uncovered_lines.empty?

    uncovered_lines.sort_by { |entry| [entry[:file], entry[:line]] }.each do |line_information|
      puts "#{line_information[:file]}:#{line_information[:line]}"
    end
  end

  def self.extract_uncovered_lines
    uncovered_lines = []
    coverage_document = REXML::Document.new(File.read(COVERAGE_XML_PATH))
    coverage_document.elements.each("//class") do |class_element|
      append_uncovered_from_class(uncovered_lines, class_element)
    end
    uncovered_lines
  end

  def self.append_uncovered_from_class(uncovered_lines, class_element)
    filename = class_element.attributes["filename"]
    return unless filename&.start_with?("lib/")

    class_element.elements.each("lines/line") do |line_element|
      append_uncovered_line(uncovered_lines, filename, line_element)
    end
  end

  def self.append_uncovered_line(uncovered_lines, filename, line_element)
    return unless line_element.attributes["hits"].to_i.zero?

    uncovered_lines << {file: filename, line: line_element.attributes["number"].to_i}
  end

  private_class_method :wait_for_coverage_file, :warn_missing_coverage_file, :print_uncovered_lines,
    :extract_uncovered_lines, :append_uncovered_from_class, :append_uncovered_line
end
