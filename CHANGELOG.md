# Changelog

## Unreleased

## 0.2.0

- MCP: Added `web_url_read` tool (URL fetch + Markdown conversion with pagination/section options).
- MCP: Added `gemini://` support in `web_url_read` (Gemini fetch + Gemtext to Markdown).
- MCP: Added `ipfs://` support in `web_url_read` via configurable `IPFS_GATEWAY`.
- MCP: Added `ftp://`, `sftp://`, and `smb://` support in `web_url_read`.
- MCP: Added resources `config://server-config` and `help://usage-guide`.
- MCP: Added startup environment validation for `SEARXNG_URL` and auth variable pairs.
- Errors: Added richer, user-facing configuration/network/HTTP messages.
- Client: Added auth env aliases (`AUTH_USERNAME`/`AUTH_PASSWORD`) and proxy auto-detection from `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` with `NO_PROXY`.
- Docs: Added protocol support notes for Gemini, IPFS, Tor, I2P, and SOCKS5-related setups.
- Docs: Added protocol support and environment notes for FTP/SFTP/SMB.
- Search tool: Improved no-results response to include actionable guidance.

## 0.1.0

- Initial release.
- `Searxng::Client` for SearXNG `/search` JSON API (results, infoboxes, suggestions, answers, corrections).
- CLI: `searxng search QUERY` and `searxng serve` (MCP server).
- MCP tool `searxng_web_search` (query, pageno, time_range, language, safesearch).
- Configuration via SEARXNG_URL, SEARXNG_USER, SEARXNG_PASSWORD.
