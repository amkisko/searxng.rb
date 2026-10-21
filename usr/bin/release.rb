#!/usr/bin/env ruby
require_relative "../lib/release_version_check"

def execute_command(command)
  green = "\033[0;32m"
  red = "\033[1;31m"
  nc = "\033[0m"

  puts "#{green}#{command}#{nc}"
  ok = system("bash", "-o", "pipefail", "-c", command)
  unless ok
    puts "#{red}Command failed: #{command}#{nc}"
    exit 1
  end
end

def assert_clean_worktree!
  status = `git status --porcelain --untracked-files=all`.strip
  return if status.empty?

  puts "\033[1;31mgit working directory not clean, please commit your changes first \033[0m"
  puts status
  puts "\033[1;33mNote: rubocop -a may have modified files. Review and commit changes before releasing.\033[0m"
  exit 1
end

execute_command("bundle install")
execute_command("bundle exec appraisal generate")
execute_command("bundle exec rubocop -a 2>&1 | tee tmp/rubocop.log")
execute_command("bundle exec rbs validate")
execute_command("POLYRUN_COVERAGE=1 bundle exec polyrun parallel-rspec --workers 5 --merge-failures 2>&1 | tee tmp/polyrun-rspec.log")

puts "Tests passed. Checking git status..."
assert_clean_worktree!

gem_name = "searxng"
version_file = "lib/searxng/version.rb"
version_content = File.read(version_file)
version = version_content.match(/VERSION\s*=\s*"([0-9.]+)"/)[1]
gem_file = "#{gem_name}-#{version}.gem"

ReleaseVersionCheck.warn_if_already_released(version: version, package_name: gem_name, registry: :rubygems)

assert_clean_worktree!
execute_command("gem build #{gem_name}.gemspec")

puts "Ready to release #{gem_file} #{version}"
print "Continue? [y/N] "
answer = $stdin.gets.to_s.chomp
unless answer == "y" || answer == "Y"
  puts "Exiting"
  exit 1
end

execute_command("gem push #{gem_file}")
execute_command("git tag #{version}")
execute_command("git push origin HEAD \"refs/tags/#{version}\"")
execute_command("gh release create #{version} --generate-notes")
