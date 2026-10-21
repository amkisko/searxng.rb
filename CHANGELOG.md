# Changelog

## Unreleased

## 0.2.1 (2026-10-21)

- Fix cleartext HTTP proxy fetches to dial the `NetworkPolicy`-pinned IP and set `Host` to the original hostname.
- Fix unbounded `web_url_read` response buffering with a shared byte ceiling across HTTP, FTP, SFTP, SMB, and Gemini.
- Fix process-wide `@@url_cache` growth with TTL purge, entry cap, byte budget, and a mutex.
- Fix Gemini TLS verification by loading the default CA store via `SSLContext#set_params`.
- Fix SMB credentials leaking through `smbclient` argv; pass the password via `PASSWD`.
- Fix website HTTP errors mislabeled as SearXNG search failures; include redirect `Location` when present.
- Fix invalid `time_range` / `safesearch` values being silently dropped; raise `ConfigurationError`.
- Fix IPFS gateway path traversal via unsafe CID or `..` path segments.
- Fix `timeoutMs` of `0` disabling deadlines; clamp to `1000..30000`.
- Fix release gate ignoring lint/test failures (`pipefail`) and dirty staged/untracked trees.
- Fix `searxng serve` swallowing startup errors into an unbounded `StringIO`; reopen stderr to `File::NULL` and print configuration failures.
- Add `NetworkPolicy` coverage for local NAT64 (`64:ff9b:1::/48`), IPv4-compatible embeds, documentation ranges, and bracketed IPv6 hostnames via `uri.hostname`.
- Document Ruby `>= 3.4` and that `.onion` / `.i2p` are not supported by `web_url_read`.
- Redact URL userinfo from fetch error URIs; default `maxLength` to `20000`; honor `SEARXNG_USER_AGENT` for URL reads.

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
