# RainMaker

Keeping macOS fleet applications up to date is a tedious, error-prone process. Version checks are manual, security verification is often skipped, and deploying updates to an MDM platform requires multiple disconnected steps. RainMaker replaces that with a GitOps-driven automation kit: you declare the apps your fleet needs as YAML manifests, and GitHub Actions handles version monitoring against the Homebrew API, SHA256 integrity verification, optional VirusTotal malware scanning, and deployment to the Iru MDM platform. Every update flows through a pull request with a full security risk assessment before anything reaches your fleet.

## Features

- **GitOps-driven package declarations** -- define every managed app as a version-controlled YAML manifest
- **Automated Homebrew cask version monitoring** -- detects newer versions via the public Homebrew API
- **SHA256 verification and optional VirusTotal scanning** -- every download is integrity-checked; VirusTotal adds malware analysis when an API key is configured
- **Automated PR generation with security risk assessment** -- version bumps arrive as pull requests tagged with a risk level (LOW / MEDIUM / HIGH / CRITICAL)
- **Optional Iru MDM integration** -- on merge to `main`, verified installers are uploaded to Iru via S3 signed URL and metadata is patched automatically

## How It Works

Two GitHub Actions workflows handle the full lifecycle:

**`check-versions.yml`** runs on `workflow_dispatch` (cron schedule available but commented out by default). It validates every YAML manifest in `packages/`, queries the Homebrew API for newer cask versions, downloads and verifies the installer, optionally submits it to VirusTotal, and opens a pull request with the updated version and a security assessment.

**`iru-sync.yml`** triggers on push to `main` when files under `packages/` change. It detects which packages were modified, filters to those with an `iru_library_item_id`, downloads and SHA256-verifies each installer, and uploads it to the Iru MDM platform.

## Quick Start

### 1. Fork or clone the repository

Fork this repository to your own GitHub organization, or clone it directly if you prefer to manage it without forking.

### 2. Configure GitHub Actions secrets

Add the following secrets under **Settings > Secrets and variables > Actions**:

| Secret | Used by | Required |
|--------|---------|----------|
| `VIRUSTOTAL_API_KEY` | `check-versions.yml` | Optional -- scan is skipped if absent |
| `IRU_API_KEY` | `iru-sync.yml` | Yes, if using Iru sync |
| `IRU_TENANT_URL` | `iru-sync.yml` | Yes, if using Iru sync |

The exception being the `GITHUB_TOKEN`, which is automatically provided by GitHub Actions and does not require manual configuration:

| Secret | Used by | Required |
|--------|---------|----------|
| `GITHUB_TOKEN` | `check-versions.yml` | Built-in -- no configuration needed |

### 3. (Optional) Enable scheduled runs

Uncomment the cron schedule in `.github/workflows/check-versions.yml` to run version checks automatically:

```yaml
on:
  schedule:
    - cron: "0 6 * * 1-5"   # weekdays at 06:00 UTC, adjust as needed
  workflow_dispatch:
```

### 4. Add your first package manifest

Create a YAML file in `packages/` named after the Homebrew cask (e.g., `packages/slack.yaml`). See `packages/example.yaml` for the full schema and the [Managing Packages](#managing-packages) section below for detailed instructions.

### 5. Trigger the workflow

Push your manifest to `main`, or run the **Check Package Versions** workflow manually from the GitHub Actions UI via **Actions > Check Package Versions > Run workflow**.

## Managing Packages

This section covers how to add, modify, and remove package manifests in your own fork of RainMaker.

### Adding a New Package

#### 1. Find the Homebrew cask name

The `source` field must match the exact Homebrew cask identifier. Look it up:

```bash
brew search <app-name>
brew info --cask <cask-name>
```

Or check the [Homebrew cask list](https://formulae.brew.sh/cask/) directly. Confirm the cask exists via the API:

```bash
curl -fsSL "https://formulae.brew.sh/api/cask/<cask-name>.json" | jq '{version, url, sha256}'
```

#### 2. Create the package file

Create `packages/<cask-name>.yaml`. The filename must match the Homebrew cask name exactly.

Start from this template:

```yaml
name: "App Name"
source_type: "brew"
source: "cask-name"
file_type: "dmg"             # dmg | pkg | zip
version: "1.0.0"             # set to the current version you have deployed
iru_library_item_id: ""      # leave empty unless you have an Iru library item UUID

install_enforcement: "install_once"
active: true
restart: false

preinstall_script: ""
postinstall_script: ""
audit_script: ""

show_in_self_service: false
self_service_category_id: ""
self_service_recommended: false
```

**Set `version` to the version you currently have deployed** -- not an older one. The workflow detects updates by comparing this value against the Homebrew API, so starting with the correct current version avoids any gaps in waiting for a new update to release.

#### 3. Conditional fields

| Situation | What to fill in |
|-----------|-----------------|
| `file_type: zip` | Set `unzip_location` (e.g., `/Applications`) |
| `install_enforcement: continuously_enforce` | Set `audit_script` (non-empty shell script) |
| `show_in_self_service: true` | Set `self_service_category_id` to a valid Iru category UUID |

#### 4. Enable Iru sync (optional)

To have the package automatically uploaded to Iru when a version PR is merged:

1. Create (or locate) the app in your Iru library
2. Copy the library item UUID (from the URL or API) for that app. It looks like `123e4567-e89b-12d3-a456-426614174000`.
3. Set `iru_library_item_id` to that UUID

Without this, the package is tracked for version updates and security scanning only -- no Iru upload occurs.

#### 5. Commit and push

```bash
git checkout -b add/<cask-name>
git add packages/<cask-name>.yaml
git commit -m "add <App Name> package"
git push origin add/<cask-name>
```

Open a PR against your `main` branch. The `check-versions.yml` workflow will run automatically to validate the YAML and check for any available updates.

### Modifying an Existing Package

- To change install behavior, scripts, or self-service settings, edit the relevant fields and open a PR.
- Do not manually change `version` -- version bumps are handled automatically by the `check-versions.yml` workflow via its automated PRs.
- If you need to force a re-sync to Iru without a version change, coordinate a manual workflow dispatch after merging a metadata-only change.

### Removing a Package

Delete the file from `packages/` and open a PR. No other changes are required -- the workflows discover packages by scanning the directory.

If the package has an Iru library item associated, archive or remove it from Iru manually after merging.

### Workflow Validation

The `check-versions.yml` workflow validates all YAML files on every run. It checks:

- Required fields are present and non-empty: `name`, `source_type`, `source`, `file_type`, `version`
- `source_type` is `brew`
- `file_type` is one of `dmg`, `pkg`, `zip`

A validation failure blocks the entire workflow. Fix any reported errors before re-running.

### Running Workflows Manually

Both workflows support manual dispatch from the GitHub Actions UI:

1. Go to the **Actions** tab
2. Select the workflow (`Check Package Versions` or `Iru Package Sync`)
3. Click **Run workflow**

This is useful for testing a newly added package without waiting for a push trigger.

## Package Manifest Schema

Each file in `packages/` declares a single managed application. The filename must match the Homebrew cask name exactly (e.g., `firefox.yaml`). See `packages/example.yaml` for a complete working example.

```yaml
name: "Mozilla Firefox"
source_type: "brew"
source: "firefox"
file_type: "dmg"
version: "149.0"
iru_library_item_id: ""
install_enforcement: "install_once"
active: true
restart: false
preinstall_script: ""
postinstall_script: ""
audit_script: ""
show_in_self_service: false
self_service_category_id: ""
self_service_recommended: false
```

### Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Human-readable display name |
| `source_type` | Yes | Package source; only `brew` is currently supported |
| `source` | Yes | Homebrew cask name |
| `file_type` | Yes | `dmg`, `pkg`, or `zip` |
| `version` | Yes | Currently tracked version |
| `iru_library_item_id` | No | Iru library item UUID; leave empty to skip Iru sync |
| `install_enforcement` | Yes | `install_once`, `continuously_enforce`, or `no_enforcement` |
| `unzip_location` | Conditional | Required when `file_type` is `zip` |
| `active` | Yes | Whether the package is active in Iru |
| `restart` | Yes | Whether a restart is required after installation |
| `preinstall_script` | No | Shell script to run before installation |
| `postinstall_script` | No | Shell script to run after installation |
| `audit_script` | Conditional | Required when `install_enforcement` is `continuously_enforce` |
| `show_in_self_service` | Yes | Whether to surface the app in Iru Self Service |
| `self_service_category_id` | Conditional | Required when `show_in_self_service` is `true` |
| `self_service_recommended` | Yes | Mark as recommended in Self Service |

## Security Risk Levels

Every version-bump PR includes a security risk assessment based on SHA256 verification and VirusTotal results:

| Level | Condition |
|-------|-----------|
| LOW | All checks passed |
| MEDIUM | Download URL not from a vendor-verified domain |
| HIGH | Suspicious VirusTotal flags |
| CRITICAL | Malware detected by VirusTotal |

## Limitations

- Only `source_type: brew` is supported; other package sources are not yet implemented
- The cron schedule is commented out by default -- version checks run on `workflow_dispatch` only until you uncomment it.
- Version comparison uses `sort -V`, which may behave unexpectedly with non-semver version strings, needless to say if your packages don't use semver, you're not going to have a good time.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for instructions on contributing improvements to the public RainMaker repository -- tooling changes, bug fixes, and documentation.

## License

RainMaker is licensed under the [GNU Affero General Public License v3.0](LICENSE) (AGPL-3.0).

You are free to fork this repository and deploy it privately with your own package manifests, secrets, and MDM identifiers. If you modify the core tooling -- scripts, workflows, or shared infrastructure -- those changes must be made publicly available. Company-specific configurations (specifically: package YAMLs, tenant URLs, library item IDs) are excluded from this requirement.

See [LICENSING.md](LICENSING.md) for detailed compliance guidance.
