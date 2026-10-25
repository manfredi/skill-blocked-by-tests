# blocked-by-tests

> **OpenCode Skill & CLI Tooling for SUSE QAM Dashboard & openQA Triage**

`blocked-by-tests` is an OpenCode skill and standalone CLI toolkit designed to automate the triage of blocked maintenance updates and staging submissions on the [SUSE QAM Dashboard](https://dashboard.qam.suse.de).

It resolves live failure data directly from openQA, pinpoints the exact **failing Perl test modules** (e.g. `tests/updinstall/SLFO_update_install.pm`), extracts the **failure reason message from the openQA step box** (e.g. `#step/SLFO_update_install/23`), and provides safe **one-click restart/retry workflows**.

---

## Table of Contents

- [Features](#features)
- [Repository Structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Skill Installation](#skill-installation)
  - [Method 1: Global Installation (All Projects)](#method-1-global-installation-all-projects)
  - [Method 2: Project-Local Configuration](#method-2-project-local-configuration)
  - [Method 3: Direct Project Copy](#method-3-direct-project-copy)
- [Using the Skill in OpenCode](#using-the-skill-in-opencode)
  - [Example Prompts](#example-prompts)
- [Standalone CLI Usage](#standalone-cli-usage)
  - [1. Failure Reasons & Step Box Inspection](#1-failure-reasons--step-box-inspection)
  - [2. Failing Perl Modules Only](#2-failing-perl-modules-only)
  - [3. Job IDs & Links for Automation](#3-job-ids--links-for-automation)
  - [4. Retrying / Restarting openQA Jobs](#4-retrying--restarting-openqa-jobs)
- [Technical Architecture](#technical-architecture)
- [License](#license)

---

## Features

- **Automated QAM Dashboard Scraping**: Queries active submissions via `/app/api/blocked`.
- **Target Filtering**: Regex matching on test group names (default: `"core,func"`) and calculated states (`failed`, `stopped`).
- **Accurate openQA Resolution**: Uses `/api/v1/jobs/overview` scoped to the current build, completely bypassing the openQA trap where `/api/v1/jobs?latest=1` returns obsolete historical job runs.
- **Failing Perl Module Extraction**: Maps openQA step executions back to the exact test module filename (`tests/<category>/<module>.pm`).
- **Failure Box Message Extraction**: Captures the exact error message and stack trace from the failure step box (e.g. `#step/SLFO_update_install/23`).
- **Direct Job Inspection**: Inspect any openQA job URL or job ID directly without querying the dashboard first.
- **Parallel HTTP Queries**: Concurrently fetches job details in background workers for fast execution (< 2 seconds for dozens of jobs).
- **Safety-Gated Job Restarts**: Preview restarts with `--dry-run`, interactive confirmation prompts, and authentication auto-detection (`OPENQA_TOKEN_OSD` or `~/.config/openqa/openqa.ini`).

---

## Repository Structure

```text
.
├── opencode.json                       # OpenCode project configuration
├── README.md                           # Repository documentation & installation guide
└── skills/
    └── blocked-by-tests/               # The OpenCode skill package (self-contained)
        ├── SKILL.md                    # Agent instructions & triage guidelines
        ├── scripts/
        │   └── get_blocked_failed_reasons.sh  # Main executable query & triage script
        └── references/
            └── README.md               # Reference copy for OpenCode skill runtime
```

---

## Prerequisites

- **`bash`** (v4.0+)
- **`curl`**
- **`jq`**
- *(Optional)* **`openqa-cli`** (required only if triggering job restarts with `--retry`)
  - Configured via `~/.config/openqa/openqa.ini` or environment variable `OPENQA_TOKEN_OSD="user:key:secret"`.

---

## Skill Installation

You can install `blocked-by-tests` into OpenCode using any of the following methods:

### Method 1: Global Installation (All Projects)

To make the skill available across all your OpenCode sessions and projects:

```bash
mkdir -p ~/.config/opencode/skills
cp -r /path/to/blocked-by-tests/skills/blocked-by-tests ~/.config/opencode/skills/
```

### Method 2: Project-Local Configuration

If you cloned this repository into a shared location or submodule, reference its `skills` directory in your project's `opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "skills": [
    "/path/to/blocked-by-tests/skills"
  ]
}
```

### Method 3: Direct Project Copy

Copy the skill directly into your project's `.opencode/skills/` directory:

```bash
mkdir -p <your-project>/.opencode/skills
cp -r skills/blocked-by-tests <your-project>/.opencode/skills/
```

---

## Using the Skill in OpenCode

Once installed, OpenCode automatically discovers `blocked-by-tests`. You can mention it explicitly as `@blocked-by-tests` or ask questions about blocked submissions, failed openQA jobs, or failing test modules.

### Example Prompts

#### 1. General Triage
> *"Check the QAM dashboard for blocked submissions and list all failing Perl test modules."*

#### 2. Investigating a Specific Incident
> *"Why is incident 9372 blocked on QAM? Show me the failing openQA jobs, the failed step URL, and the message in the error box."*

#### 3. Investigating a Specific openQA Job
> *"Inspect job https://openqa.suse.de/tests/25025671. What test module failed and what is the error message in the step box?"*

#### 4. Restarting Failing Jobs
> *"Run a dry-run retry of all failed openQA jobs for incident 9426."*
> *"Restart all failing jobs for incident 9426 on openQA."*

---

## Standalone CLI Usage

The script `skills/blocked-by-tests/scripts/get_blocked_failed_reasons.sh` can also be used directly from the command line outside of OpenCode:

```bash
# Convenient alias or direct invocation:
SCRIPT="./skills/blocked-by-tests/scripts/get_blocked_failed_reasons.sh"
```

### 1. Failure Reasons & Step Box Inspection

```bash
# Query all blocked submissions matching core,func (default)
$SCRIPT

# Inspect a specific incident or package
$SCRIPT -i 9372

# Directly inspect any openQA job URL or ID
$SCRIPT https://openqa.suse.de/tests/25025671

# Display complete multi-line failure box including full stack trace
$SCRIPT https://openqa.suse.de/tests/25025671 --full-reason

# Output only the reason line per failure (easy to grep)
$SCRIPT -i 9372 --reasons-only
```

*Example Output:*
```text
  - [25025671] sle-16.0-Online-Updates-Staging-Install-ppc64le-Build:git:9372:python3-qam-incidentinstall-SLFO@ppc64le-p10-virtio (failed)
    Failed module: tests/updinstall/SLFO_update_install.pm
    Failed step: #step/SLFO_update_install/23 (https://openqa.suse.de/tests/25025671#step/SLFO_update_install/23)
    Reason: # Test died: No patch found! at sle/tests/qam-updinstall/SLFO_update_install.pm line 108, <$isotovideo> line 1.
    Job URL: https://openqa.suse.de/tests/25025671
```

### 2. Failing Perl Modules Only

```bash
# Output full module paths (one per line, deduplicated):
$SCRIPT -m

# Output with .pm extension:
$SCRIPT -m --module-format pm

# Output bare module name:
$SCRIPT -m --module-format name
```

*Example Output:*
```text
tests/console/pkcon.pm
tests/updinstall/SLFO_update_install.pm
tests/console/rsyslog_ossl_server.pm
tests/console/ovs_server.pm
tests/x11/tomcat.pm
```

### 3. Job IDs & Links for Automation

```bash
# Extract job IDs (ideal for xargs or batch commands)
$SCRIPT -i 9372 --ids-only

# Extract job URLs
$SCRIPT -i 9372 --links-only

# Aggregate full JSON output
$SCRIPT -i 9372 --json | jq .
```

### 4. Retrying / Restarting openQA Jobs

```bash
# 1. Preview which jobs would be restarted (dry-run, no changes made)
$SCRIPT -i 9426 --retry --dry-run

# 2. Interactive restart (prompts for confirmation [y/N])
$SCRIPT -i 9426 --retry

# 3. Non-interactive restart (batch mode)
$SCRIPT -i 9426 --retry -y
```

---

## Technical Architecture

### 1. Avoiding the openQA `latest=1` Trap
A common issue in openQA scripting is querying `/api/v1/jobs?build=...&result=failed&latest=1`. In openQA's SQL schema, `latest=1` is applied *after* the `result=failed` filter. As a result, older historical runs of a job that failed and were subsequently restarted and passed are still returned as "failed".

`blocked-by-tests` queries `/api/v1/jobs/overview`, which first resolves the single active job per scenario and then evaluates results. This guarantees 100% agreement with the QAM Dashboard UI.

### 2. Group State Computation
Group state calculation precisely replicates QEM Dashboard's Vue frontend logic:
- `failed`: `failed > 0`
- `stopped`: `stopped > 0` (includes `incomplete`, `parallel_failed`, `timeout_exceeded`, `user_cancelled`, `skipped`)
- `waiting`: `waiting > 0`
- `accepted`: `accepted > 0`
- `passed`: all jobs finished successfully

---

## License

GPL-2.0 / MIT (aligned with openQA / os-autoinst tooling conventions).
