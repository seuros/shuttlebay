# Running a Rails app on Shuttlebay

From `rails new` (or an app on Puma) to production behind Mothership. Any
Rack app works the same way; the Rails-specific parts are marked.

Mothership is the HTTP server: it terminates connections, serves `public/`,
compresses, limits, caches and routes. Shuttlebay runs your app on threads
that Mothership hands finished requests to. There is no Puma, no Thruster
and no nginx left in the request path.

## 1. Install

```ruby
# Gemfile
gem "shuttlebay"
gem "guardship"   # the mothership binary, prebuilt for macOS, Linux, FreeBSD 15+
```

```bash
bundle install
bundle exec mothership --help
```

Keep Puma in the Gemfile if you like: nothing below removes it, and
`rails server` without `-u` still uses it.

## 2. Development and system tests

```bash
bin/rails server -u shuttlebay
```

```ruby
# test/application_system_test_case.rb
require "shuttlebay/capybara"
Capybara.server = :shuttlebay
```

Both start a Mothership attached to the app, so what you test is the stack
you deploy.

## 3. The manifest

Mothership reads `ship-manifest.toml` from the directory it starts in:

```toml
[mothership]
compression = true

[mothership.bind]
http = "0.0.0.0:3000"

[[mothership.static_dirs]]
path = "./public"
prefix = "/"
headers = { "cache-control" = "public, max-age=31536000" }

[[bays.http]]
name = "web"
command = "bundle"
args = ["exec", "shuttlebay", "config.ru"]
env = { RAILS_ENV = "production" }
workers = "auto"
threads = 5
routes = [{ bind = "http", pattern = "/.*" }]
```

```bash
bundle exec mothership clearance   # validate the manifest
bundle exec mothership chart       # what is routed where
bundle exec mothership             # run
```

- `workers = "auto"` forks one worker per CPU the process may use, as many as
  memory affords (512 MiB each); a 1 CPU or 1 GiB container serves from one
  process. A number, or `"$WEB_CONCURRENCY"`, works too.
- `threads` is the threads per worker, each with its own docking link to
  Mothership. A request goes only to an idle thread; when all are busy it
  waits in Mothership (`queue_timeout`, 30 s, then `503`).
- The static dir serves `public/` before any request reaches Rails, `/about`
  from `about.html` and precompressed `.br`/`.gz` files included. The
  Railtie sees that and drops `ActionDispatch::Static`. Give it the headers
  your `config.public_file_server.headers` sets: the Railtie logs a warning at
  boot for any it does not see there.

## 4. Coming from Puma

| `config/puma.rb` | With Shuttlebay |
|---|---|
| `workers ENV.fetch("WEB_CONCURRENCY")` | `workers = "$WEB_CONCURRENCY"` (or `"auto"`) |
| `threads n, n` / `RAILS_MAX_THREADS` | `threads = "$RAILS_MAX_THREADS"` |
| `port` / `bind` | `[mothership.bind]` |
| `preload_app!` | always: `config.ru` loads in the master, then workers fork |
| `before_fork`, `on_worker_boot`, `on_worker_shutdown`, `out_of_band` | `Shuttlebay.before_fork { }` and friends, in `config.ru` |
| `worker_timeout` | the bay's `request_timeout` (`504`, then the stuck worker is recycled) |
| `pumactl phased-restart` / `plugin :tmp_restart` | `kill -USR1` the mothership process |
| `wait_for_less_busy_worker` | built in: requests only go to idle threads |

Hooks go in `config.ru`, before `run`:

```ruby
# config.ru
require_relative "config/environment"

Shuttlebay.on_worker_boot { |index| Rails.logger.info("worker #{index} up") }
Shuttlebay.out_of_band { GC.start }   # when a worker has no request in flight

run Rails.application
Rails.application.load_server
```

`config/puma.rb` can stay for `rails server`; Shuttlebay never reads it.

## 5. Let Mothership do the middleware's work

Under Mothership the Railtie removes, on its own, what Mothership already does:
`Rack::Sendfile`, `ActionDispatch::Static` (when the static dir serves
`public/`) and `Rack::ETag` / `Rack::ConditionalGet` (Mothership tags pages and
answers revalidations itself, off the GVL). Nothing changes under Puma.

`Rack::Attack` rules are your configuration, so you move them yourself:

```ruby
# config/initializers/rack_attack.rb, before
Rack::Attack.throttle("api", limit: 60, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/api/")
end
```

```toml
# ship-manifest.toml, after
[[mothership.rate_limits]]
pattern = "^/api/"
limit = 60
period = "1m"
```

Mothership keeps the counts in memory, with no cache-store write per request,
and answers `429` with `Retry-After`. Allowlists move to
`[[mothership.ip_allowlist]]`; see the Mothership README for both.

## 6. Behind a CDN or a proxy

Behind Cloudflare, Kamal proxy or a load balancer, tell Mothership which
proxies to see through, so allowlists and rate limits apply to the visitor,
not to the proxy:

```toml
[mothership]
trusted_proxies = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]   # + your CDN's ranges
```

The app's `REMOTE_ADDR` is the address that connected to Mothership (or the
PROXY-protocol one, with `proxy_protocol = true` on the bind), and the
forwarding headers pass through. Rails resolves `request.remote_ip` from them
as it always has: keep the configuration you need for that today (for
Cloudflare, `cloudflare-rails`).

## 7. Caching

Mothership can cache whole responses in memory, the way a CDN does, purged by
tag when the data changes:

```toml
[mothership]
metrics_port = 9090   # also serves the purge endpoint, on 127.0.0.1

[mothership.response_cache]
status_header = true  # Cache-Status on responses

[[mothership.response_cache.rules]]
pattern = "^/api/"
ttl = "5m"
stale = "1m"
bypass_cookies = ["_myapp_session"]   # signed-in users skip the cache
```

```ruby
class BooksController < ApplicationController
  def show
    @book = Book.find(params[:id])
    Shuttlebay::Cache.tag(response.headers, "book-#{@book.id}")
  end
end

class Book < ApplicationRecord
  after_commit { Shuttlebay::Cache.purge(tags: ["book-#{id}"]) }
end
```

A successful `POST`/`PUT`/`PATCH`/`DELETE` through Mothership already
invalidates its own URL. Requests with `Authorization`, or with a cookie a rule
does not let through, never touch a rule's cache. The README's caching section
covers the rest.

## 8. TLS and HTTP/2

Behind a CDN or Kamal proxy, they terminate TLS and speak HTTP/2 to browsers;
Mothership listens on plain HTTP behind them, and nothing here is needed.

To terminate TLS in Mothership itself (guardship 0.2.1 and later), get a
certificate first, then add a TLS bind.

**The certificate.** Mothership serves `public/`, so certbot's webroot mode
works while the app runs on plain HTTP:

```bash
mkdir -p public/.well-known/acme-challenge   # create it before certbot runs
certbot certonly --webroot -w ./public -d example.com -d www.example.com
```

Create `.well-known` beforehand: Mothership skips the filesystem for
top-level names it has not seen in `public/` (it re-lists the directory
about once a second), so one certbot creates on the spot can miss the
validation request. One certificate can name every domain (`-d` repeated).

**The binds.**

```toml
[mothership.bind]
http = "0.0.0.0:80"
https = { addr = "0.0.0.0:443", tls = { cert = "/etc/letsencrypt/live/example.com/fullchain.pem", key = "/etc/letsencrypt/live/example.com/privkey.pem" } }

[[bays.http]]
name = "web"
# command, args, workers, threads as before
routes = [
  { bind = "http", pattern = "/.*" },
  { bind = "https", pattern = "/.*" },
]
```

```ruby
# config/environments/production.rb
config.force_ssl = true   # redirects HTTP to HTTPS, sends HSTS, secures cookies
```

- Browsers get HTTP/2 (negotiated over ALPN). On the TLS bind the app sees
  `rack.url_scheme = "https"` and `HTTPS=on`, so `force_ssl` and
  `request.ssl?` work with no `assume_ssl` or forwarded headers.
- Renewals are picked up without a restart, within 30 s of certbot writing
  them. A renewal that does not load is logged; the old one keeps serving.
- Let's Encrypt keys are readable by root only: run with access to them, or
  have a certbot `--deploy-hook` copy the pair where the app's user can read
  it. Ports 80 and 443 need `setcap cap_net_bind_service=+ep` on the binary,
  `AmbientCapabilities=CAP_NET_BIND_SERVICE` under systemd, or a container.

From guardship 0.3, Mothership can also redirect HTTP to HTTPS itself
(`http = { addr = "0.0.0.0:80", https_redirect = true }`, ACME challenges
left on HTTP) and serve a certificate per domain on one bind
(`tls = [{ cert, key }, ...]`, picked by SNI); see the Mothership README.

## 9. Docker and Kamal

Mothership replaces `./bin/thrust ./bin/rails server` in the Dockerfile Rails
generates:

```dockerfile
EXPOSE 80
CMD ["bundle", "exec", "mothership"]
```

with the bind on port 80 (`http = "0.0.0.0:80"`), where kamal-proxy expects
the app. Rails' `bin/docker-entrypoint` prepares the database only when the
command is `./bin/rails server`, so run that as a prelaunch job instead:

```toml
[[mothership.prelaunch]]
name = "db-prepare"
command = "bin/rails"
args = ["db:prepare"]
```

```yaml
# config/deploy.yml
proxy:
  host: app.example.com
  ssl: true
  healthcheck:
    path: /up
```

Mothership runs fine as PID 1: on Linux it reaps and forwards signals itself
(`docker run --init` is still the safer default elsewhere). Kamal deploys by
starting a new container and moving traffic to it once `/up` answers, so
phased restarts (`kill -USR1`) are for servers you deploy to in place.

On several hosts:

- Run prelaunch jobs (migrations) once: tag one host and elect it.

  ```yaml
  servers:
    web:
      - 10.0.0.5: flagship
      - 10.0.0.6
  env:
    tags:
      flagship:
        MS_FLAGSHIP: "true"
  ```

  ```toml
  [mothership.flagship]
  enabled = true
  election = "static"
  static_flagship = "$MS_FLAGSHIP"
  ```

- With a response cache, let the hosts relay purges and invalidations to one
  another (`[mothership.response_cache.peers]` in the Mothership README).

## 10. Watching it run

- `bundle exec mothership health` prints the fleet's health as JSON (needs
  `metrics_port`); `/metrics` serves Prometheus metrics, `mothership_http_bay_*`
  among them.
- Both Mothership and Shuttlebay log JSON lines to stdout.
- `503 Starting`: the bay is still booting (`boot_timeout`, 120 s).
- `503` once running: every thread was busy for `queue_timeout`; add
  `threads` (I/O-bound apps) or `workers` (CPU-bound ones).
- `504`: no response head within `request_timeout` (60 s); the stuck worker
  is recycled.
