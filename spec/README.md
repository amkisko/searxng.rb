# Running Tests

## Using rspec

Run tests with `bundle exec rspec`:

```bash
# Run all tests
bundle exec rspec

# Run with fail-fast (stop on first failure)
bundle exec rspec --fail-fast

# Show zero coverage lines (uncovered file:line)
SHOW_ZERO_COVERAGE=1 bundle exec rspec

# Run single spec file
bundle exec rspec spec/searxng/client_spec.rb
```

## Coverage

- Minimum line coverage is 90% (configured in spec_helper).
- Coverage reports: `coverage/index.html`, `coverage/coverage.xml`.
- Use `SHOW_ZERO_COVERAGE=1` to print uncovered lines after a run.

## Guidelines

- Test behavior (public API), not implementation.
- Use WebMock to stub HTTP (SearXNG API); avoid real network calls.
- Prefer `instance_double` for external boundaries when needed.
