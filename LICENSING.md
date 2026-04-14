# AGPL-3.0 Licensing Guide

This document provides plain-English guidance on how the GNU Affero General Public License v3.0 (AGPL-3.0) applies to RainMaker. It is intended to help organizations that fork or copy this repository understand their obligations quickly, without reading the full license text.

**This is not legal advice.** Organizations should consult their own legal counsel for compliance decisions. The canonical license text is in the [LICENSE](LICENSE) file.

---

## What You Can Do Freely

The following actions do **not** trigger any public source disclosure obligation:

- **Fork the repository and deploy it privately** within your organization.
- **Add, modify, or remove package manifests** (`packages/*.yaml`). These files are your organization's configuration data describing which applications your fleet manages. They are not derivative works of the RainMaker tooling.
- **Configure GitHub Actions secrets** such as API keys, tenant URLs, and tokens.
- **Set Iru library item UUIDs** and other org-specific identifiers in your package manifests.
- **Use the tooling internally** to manage your macOS fleet.

---

## What Requires Public Disclosure

If you modify the **tooling itself**, the AGPL-3.0 requires you to make the modified source code publicly available under the same license. This applies when you:

- **Modify scripts** in `scripts/` -- for example, adding support for a new package source beyond Homebrew, integrating a new MDM platform, or improving security scanning logic.
- **Modify workflows** in `.github/workflows/` -- for example, adding new pipeline stages or changing the PR generation logic.
- **Add new general-purpose tooling files** to the repository that extend or replace the existing automation.
- **Distribute modified versions** of RainMaker to third parties (e.g., sharing a modified fork).

In all of these cases, the complete modified source code must be made publicly available under AGPL-3.0.

---

## What Does NOT Require Disclosure

To be explicit, the following are **excluded** from disclosure obligations:

- **Package YAML files** (`packages/*.yaml`) -- org-specific configuration data.
- **GitHub Actions secrets and environment variables** -- API keys, tokens, and credentials.
- **Iru tenant URLs, API keys, and library item UUIDs** -- private operational values tied to your MDM environment.
- **Internal deployment procedures and runbooks** -- how you operate RainMaker within your organization.
- **The specific list of applications** your organization manages.

---

## How to Contribute Back

If you improve the tooling, consider contributing your changes to the broader ecosystem:

- **Open a pull request** against the original RainMaker repository from a feature branch on your fork.
- **Maintain a public fork** with your improvements visible on the `upstream` branch.
- See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines, script conventions, and workflow expectations.

---

## Summary

| Action | Disclosure Required? |
|--------|---------------------|
| Adding package manifests | No |
| Configuring secrets and MDM identifiers | No |
| Modifying scripts or workflows | Yes |
| Adding new tooling | Yes |
| Using RainMaker internally as-is | No |
| Distributing modified RainMaker | Yes |
