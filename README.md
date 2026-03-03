# searxng

[![Gem Version](https://badge.fury.io/rb/searxng.svg)](https://badge.fury.io/rb/searxng) [![Test Status](https://github.com/amkisko/searxng.rb/actions/workflows/test.yml/badge.svg)](https://github.com/amkisko/searxng.rb/actions/workflows/test.yml) [![codecov](https://codecov.io/gh/amkisko/searxng.rb/graph/badge.svg)](https://codecov.io/gh/amkisko/searxng.rb)

Ruby gem providing a SearXNG HTTP client, CLI (search), and MCP (Model Context Protocol) server for web search. Integrates with MCP-compatible clients like Codex, Cursor, Claude, and other MCP-enabled tools.

Sponsored by [Kisko Labs](https://www.kiskolabs.com).

<a href="https://www.kiskolabs.com">
  <img src="kisko.svg" width="200" alt="Sponsored by Kisko Labs" />
</a>

## Requirements

- **Ruby 3.1 or higher** (Ruby 3.0 and earlier are not supported). For managing Ruby versions, [rbenv](https://github.com/rbenv/rbenv) or [mise](https://mise.jdx.dev/) are recommended; system Ruby may be sufficient if it meets the version requirement.

## Quick Start

```bash
gem install searxng
```

Or add to your Gemfile:

```ruby
gem "searxng"
```

### Configuration

- **SEARXNG_URL** (required for remote): Base URL of your SearXNG instance (e.g. `http://localhost:8080` or `https://search.example.com`). Defaults to `http://localhost:8080` when not set.
- **SEARXNG_USER** / **SEARXNG_PASSWORD** (optional): Basic auth credentials if your instance is protected.
- **SEARXNG_CA_FILE** / **SEARXNG_CA_PATH** (optional): Custom CA certificate file or directory for HTTPS. You can also pass `ca_file:`, `ca_path:`, or `verify_mode:` to `Searxng::Client.new`.
- **SEARXNG_USER_AGENT** (optional): Custom User-Agent string. The client sends a default identifying the gem; if your instance returns 403 Forbidden (e.g. bot detection), set a custom User-Agent or pass `user_agent:` to `Searxng::Client.new`.

To fully customize the HTTP client (e.g. custom certs, proxy, timeouts), override `#build_http(uri)` in a subclass, or pass a `configure_http:` callable to the client; it is invoked with the `Net::HTTP` instance and the request URI before each request.

### Cursor IDE Configuration

For Cursor IDE, create or update `.cursor/mcp.json` in your project:

```json
{
  "mcpServers": {
    "searxng": {
      "command": "bundle",
      "args": ["exec", "searxng", "serve"],
      "env": {
        "SEARXNG_URL": "http://localhost:8080"
      }
    }
  }
}
```

**Note**: Using `gem exec searxng serve` (with `command`: `"gem"`, `args`: `["exec", "searxng", "serve"]`) ensures the correct Ruby version is used when the gem is installed globally.

### Claude Desktop Configuration

For Claude Desktop, edit the MCP configuration file:

**macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`  
**Windows**: `%APPDATA%\Claude\claude_desktop_config.json`

```json
{
  "mcpServers": {
    "searxng": {
      "command": "bundle",
      "args": ["exec", "searxng", "serve"],
      "env": {
        "SEARXNG_URL": "http://localhost:8080"
      }
    }
  }
}
```

**Note**: After updating the configuration, restart Claude Desktop for changes to take effect.

### Running the MCP Server manually

After installation, you can start the MCP server immediately:

```bash
# With bundler
bundle exec searxng serve

# Or if installed globally
gem exec searxng serve
```

The server will start and communicate via STDIN/STDOUT using the MCP protocol.

### Testing with MCP Inspector

You can test the MCP server using the [MCP Inspector](https://github.com/modelcontextprotocol/inspector) tool:

```bash
# Ensure a SearXNG instance is running (e.g. docker compose -f examples/docker-compose.yml up -d)
export SEARXNG_URL="http://localhost:8080"

# Run the MCP inspector with the server
npx @modelcontextprotocol/inspector bundle exec searxng serve
```

The inspector will:

1. Start a proxy server and open a browser interface
2. Connect to your MCP server via STDIO
3. Allow you to test all available tools interactively
4. Display request/response messages and any errors

Useful for testing the `searxng_web_search` tool before integrating with Cursor or other MCP clients.

## Features

- **SearXNG HTTP Client**: Full-featured client for the SearXNG search API (results, infoboxes, suggestions, answers, corrections)
- **CLI**: `searxng search` for ad-hoc queries and `searxng serve` for the MCP server
- **MCP Server Integration**: Ready-to-use MCP server with web search tool, compatible with Cursor IDE, Claude Desktop, and other MCP-enabled tools
- **Configurable HTTP**: Optional custom CA, verify mode, and `configure_http` hook or `build_http` override for proxy/timeouts/certs
- **Basic Auth**: Optional Basic authentication via options or ENV

## Basic Usage

### Ruby API

```ruby
require "searxng"

client = Searxng::Client.new
data = client.search("ruby programming", pageno: 1, language: "en")

data[:results].each do |r|
  puts r[:title], r[:url], r[:content]
end
```

### CLI

```bash
searxng search "your query"
searxng search "ruby" --page 2 --language en --time-range day --json
```

Options: `--url`, `--page`, `--language`, `--time-range` (day|month|year), `--safesearch` (0|1|2), `--json`.

## MCP Tools

The MCP server provides the following tools:

1. **searxng_web_search** - Web search via SearXNG
   - Parameters: `query` (required), `pageno` (optional), `max_results` (optional, default 10), `time_range` (optional), `language` (optional), `safesearch` (optional). Use `max_results` to limit how many results are returned in one response (reduces token usage); use `pageno` for the next page.

## Examples

See [examples/SETUP.md](examples/SETUP.md) for running SearXNG locally (e.g. Docker) and [examples/run_queries.rb](examples/run_queries.rb) for a small script using the client.

## Development

```bash
# Install dependencies
bundle install

# Run tests
bundle exec rspec

# Run tests across multiple Ruby versions
bundle exec appraisal install
bundle exec appraisal rspec

# Run linting
bundle exec rubocop

# Validate RBS type signatures
bundle exec rbs validate
```

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/amkisko/searxng.rb.

Contribution policy:
- New features are not necessarily added to the gem
- Pull request should have test coverage for affected parts
- Pull request should have changelog entry

Review policy:
- It might take up to 2 calendar weeks to review and merge critical fixes
- It might take up to 6 calendar months to review and merge pull request
- It might take up to 1 calendar year to review an issue

For more information, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

If you discover a security vulnerability, please report it responsibly. See [SECURITY.md](SECURITY.md) for details.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
