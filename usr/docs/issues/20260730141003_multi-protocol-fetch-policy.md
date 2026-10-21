# Multi-protocol fetch policy

## Decisions

web_url_read uses one destination policy across HTTP, HTTPS, FTP, SFTP, SMB, Gemini, and IPFS gateway requests. Every hostname is resolved and checked against private and reserved address ranges before connecting, and transports pin or otherwise bind the validated destination where their client supports it.

HTTP, HTTPS, and IPFS remain enabled by default. FTP, SFTP, SMB, and Gemini require explicit SEARXNG_WEB_URL_SCHEMES opt-in. Environment-provided FTP, SFTP, and SMB credentials are used only for hosts named in SEARXNG_WEB_URL_CREDENTIAL_HOSTS. SFTP host-key verification and Gemini hostname verification remain mandatory, and SMB paths reject command separators.

## Effects

The broad SSRF and ambient-credential paths are closed while preserving operator-controlled protocol support. README and the MCP usage resource describe the opt-in and credential-host contracts.

The complete make test command passed after the implementation and documentation changes.

## Next

- Keep non-HTTP protocols disabled unless a deployment explicitly needs them.
- Prefer process-level network isolation for deployments that expose open-world fetching to untrusted callers.

## Source

- lib/searxng/network_policy.rb
- lib/searxng/server.rb
- spec/searxng/server_spec.rb
- README.md
