# Running SearXNG locally and trying the gem

## Run SearXNG with Docker

**Quick one-liner** (uses image defaults; may 403 if JSON format or limiter is strict):

```bash
docker run -d -p 8080:8080 searxng/searxng:latest
```

**Recommended: docker-compose with config** (enables JSON and disables limiter for local use):

From repo root:

```bash
docker compose -f examples/docker-compose.yml up -d
```

Or from the `examples/` directory:

```bash
docker compose up -d
```

SearXNG will be at **http://localhost:8080**. The compose file mounts `examples/searxng/settings.yml` so that JSON format is enabled and the limiter is off.

## Config files (when using docker-compose)

The compose file mounts `./searxng` (relative to the compose file) into the container as `/etc/searxng`. So the files you need are under **examples/searxng/**:

- **settings.yml** – main settings (formats, limiter, secret_key)
- **limiter.toml** – optional; bot-detection IP lists and burst limits

### settings.yml

The example **examples/searxng/settings.yml** already includes:

- **search.formats**: `[html, json]` – JSON is required for API/script access; if it’s missing, SearXNG returns **403** for `format=json` requests.
- **server.limiter**: `false` – disables the rate/bot limiter for private/local use. Set to `true` for public instances.

If you run without mounting this file, ensure your instance has JSON in `search.formats` and consider turning the limiter off for testing.

### limiter.toml (optional)

If you keep the limiter on but want to allow your script’s IP, create **examples/searxng/limiter.toml**:

```toml
[botdetection.ip_lists]
pass_ip = [
    "127.0.0.1",
    "172.18.0.1"   # common Docker bridge gateway
]

[botdetection.ip_limit]
burst_max = 50
long_max = 500
```

### Apply changes

Config is read at startup. After editing settings, restart:

```bash
docker compose -f examples/docker-compose.yml restart searxng
# or from examples/:  docker compose restart searxng
```

### Quick debug via environment

You can disable the limiter via environment in **docker-compose.yml** without editing files:

```yaml
environment:
  - SEARXNG_LIMITER=false
  - SEARXNG_SETTINGS_PATH=/etc/searxng/settings.yml
```

The example compose already sets these when using the mounted **examples/searxng/settings.yml**.

## Set environment for the gem

```bash
export SEARXNG_URL="http://localhost:8080"
```

Optional: Basic auth (if your instance uses it):

```bash
export SEARXNG_USER="your_user"
export SEARXNG_PASSWORD="your_password"
```

## Troubleshooting 403 Forbidden

SearXNG often returns **403** for scripted or “bot-like” requests. Fix from both server and client.

### 1. Server-side (you control the instance)

| Cause | What to do |
|-------|------------|
| **JSON format disabled** | In `settings.yml`, set `search.formats` to include `json`. Missing format → 403. |
| **Limiter / bot detection** | For local/testing, set `server.limiter: false` in `settings.yml` or `SEARXNG_LIMITER=false` in the container env. |
| **IP blocked** | If limiter is on, add your script’s IP (e.g. `127.0.0.1`, Docker gateway) to `limiter.toml` `pass_ip`, or restart SearXNG to clear the limiter cache. |

### 2. Client-side (Ruby script / gem)

| Cause | What to do |
|-------|------------|
| **Missing or bot-like User-Agent** | The gem sends a default User-Agent. If the instance still blocks, set a browser-like one: `export SEARXNG_USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"` or pass `user_agent:` to `Searxng::Client.new`. |
| **Missing Accept header** | The gem sends `Accept: application/json`; required for JSON API. |
| **Rate / Limiter** | Sending requests too fast (e.g. &lt; 1–2 s apart) can trigger the limiter. Add `sleep(2)` between requests in loops. |

### 3. Filtron (reverse proxy)

If the instance sits behind Filtron, you may need to whitelist your IP in Filtron’s config or add a delay between requests.

---

**Minimal Ruby check** (headers matter):

```ruby
require "searxng"
client = Searxng::Client.new
# Optional: custom User-Agent if instance is strict
# client = Searxng::Client.new(user_agent: "Mozilla/5.0 (compatible; MyBot/1.0)")
data = client.search("ruby programming")
puts data[:results].size
```

## Run the MCP server

From the gem repo (or after `gem install searxng`):

```bash
bundle exec searxng serve
# or: gem exec searxng serve
```

Use this command in Cursor MCP settings (see root README).

## Run example queries with the CLI

```bash
bundle exec searxng search "ruby programming"
bundle exec searxng search "SearXNG" --page 1 --json
```

Or run the example script:

```bash
bundle exec ruby examples/run_queries.rb
```

If you hit 403, ensure the instance has JSON enabled and limiter relaxed (see above), and that the client sends a proper User-Agent (and optional `SEARXNG_USER_AGENT`).
