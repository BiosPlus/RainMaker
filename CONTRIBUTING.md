# Contributing to RainMaker

Contributions to the public RainMaker repository are welcome. This guide covers how to report issues and submit improvements to the shared tooling -- scripts, workflows, and documentation.

If you are looking for instructions on adding packages to your own fork, see the [Managing Packages](README.md#managing-packages) section in the README.

---

## Opening Issues

Use GitHub Issues to report bugs or request features. When filing an issue, include:

- A clear description of the problem or suggestion
- Steps to reproduce (for bugs)
- Expected vs. actual behavior
- Relevant log output or error messages

---

## Contributing Tooling Changes

RainMaker's shared tooling lives in `scripts/` and `.github/workflows/`. To contribute improvements:

1. Fork the repository on GitHub.
2. Create a feature branch from `main`:

```bash
git checkout main
git checkout -b fix/my-improvement
```

3. Make your changes to scripts, workflows, or documentation.
4. Test your changes locally where possible (e.g., run scripts with sample data, validate YAML syntax).
5. Push your branch and open a pull request against the `main` branch of the original RainMaker repository:

```bash
git push origin fix/my-improvement
```

### What belongs in a contribution

- Bug fixes or improvements to scripts in `scripts/`
- Enhancements to GitHub Actions workflows in `.github/workflows/`
- New general-purpose automation that benefits all users
- Documentation improvements

### What does not belong in a contribution

- Organization-specific package manifests (`packages/*.yaml`) -- these are private configuration for your own fork
- Changes tied to a specific MDM tenant, API key, or internal process

---

## Script Conventions

When modifying or adding scripts in `scripts/`, follow these patterns:

- Shebang: `#!/usr/bin/env bash` with `set -euo pipefail`
- HTTP requests: use the `curl_with_retry` wrapper (3 attempts, 2s/4s backoff)
- JSON construction: always use `jq -n --arg key "$value"` -- never string-interpolate into JSON
- Logging: informational output to stdout, errors to stderr (`>&2`)

---

## Documentation Changes

Improvements to `README.md`, `CONTRIBUTING.md`, and `LICENSING.md` are welcome. Keep documentation concise, accurate, and focused on helping users get started quickly.

---

## Pull Request Review

- PRs are reviewed for correctness, clarity, and adherence to the conventions above.
- Keep PRs focused -- one logical change per PR.
- Include a clear description of what the PR changes and why.
- If a PR touches workflow logic, describe how you tested it.

---

## License

By contributing to RainMaker, you agree that your contributions will be licensed under the [AGPL-3.0](LICENSE). See [LICENSING.md](LICENSING.md) for details on how the license applies to different parts of the repository.
