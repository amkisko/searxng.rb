# Engineering audit findings (multi-model)

## Participants

- Operator: Andrei Makarov

## Decisions

Ship a patch release that closes confirmed high-severity boundary bugs first: response and cache byte ceilings, cleartext-proxy IP pin, NetworkPolicy range and hostname gaps, Gemini CA store, SMB credential argv, release gate (`pipefail` + porcelain status), website error wording, invalid search-filter rejection, IPFS path safety, and documentation that claimed Tor/I2P support the process cannot provide.

Treat FTP PASV SSRF as already mitigated by current `net-ftp` `use_pasv_ip=false` default; set the flag explicitly. Keep `teplo_core` as an optional conversion dependency until it is published on RubyGems; stop rewriting `ConfigurationError` as a conversion failure and drop the workspace path from the user-facing message.

## Effects

Four model audits (Claude, GPT, Grok, Gemini) were fact-checked against this tree and Ruby 4.0.7 `net/http` / `net-ftp` / OpenSSL behaviour. Confirmed consensus items moved into code and specs on `patch/engineering-audit-fixes`. Refuted: classic PASV data-host SSRF under current `net-ftp` defaults; claim that `http.ipaddr=` makes Net::HTTP dial the target on the proxy port (TCP still goes to the proxy; cleartext absolute-URI hostname re-resolution remains the real gap).

## Next

- Publish or path-declare `teplo_core` for clean gem installs of `web_url_read` HTML conversion.
- Optional: bounded redirect following with per-hop `NetworkPolicy`.
- Optional: SFTP `host_key_alias` for hostname known_hosts entries.
- Split `server.rb` when cohesion allows (`AGENTS.md` size guidance).

## Source

- Audits: Claude, GPT, Grok, Gemini subagents in the parent session
- `lib/searxng/network_policy.rb`, `lib/searxng/server.rb`, `lib/searxng/client.rb`, `usr/bin/release.rb`, `bin/searxng`
- Prior policy note: `usr/docs/issues/20260730141003_multi-protocol-fetch-policy.md`
