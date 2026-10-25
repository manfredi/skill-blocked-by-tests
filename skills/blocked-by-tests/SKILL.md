---
name: blocked-by-tests
description: Query dashboard.qam.suse.de for blocked submissions matching specified group names and states, fetch corresponding failed openQA jobs, identify failing Perl test modules, extract the exact failure reason message from the openQA step failure box (e.g. #step/SLFO_update_install/23), and optionally retry/restart failed jobs.
license: GPL-2.0-or-later
compatibility: opencode
metadata:
  audience: jobs reviewers
---

# Skill: blocked-by-tests

Use this skill when investigating submissions, maintenance updates, or pull requests blocked on [SUSE QAM Dashboard](https://dashboard.qam.suse.de) due to failing openQA tests, identifying the root cause in the failing Perl test modules, and triaging or retrying openQA test jobs.

---

## Capabilities & Resources

- **Main Script**: `scripts/get_blocked_failed_reasons.sh` (or `./get_blocked_failed_reasons.sh` in the project root)
- **Reference Documentation**: `references/README.md`
- **Dashboard API**: `https://dashboard.qam.suse.de/app/api/blocked`
- **openQA API**: `https://openqa.suse.de/api/v1/jobs/overview` and `/api/v1/jobs/<id>/details`

---

## Core Workflows

### 1. Sweep All Blocked Submissions

To inspect all blocked submissions matching the default test groups (`core,func`) and states (`failed,stopped`):

```bash
./scripts/get_blocked_failed_reasons.sh
```

This displays:
- Submission / Incident ID, target project, and affected packages
- openQA Test Group ID and overview link
- List of failed openQA jobs (job ID, scenario name, result)
- Exact failing Perl test module (e.g. `tests/updinstall/SLFO_update_install.pm`)
- Failing step anchor link (e.g. `#step/SLFO_update_install/23`)
- The failure reason message extracted directly from the step failure box

### 2. Triage a Specific Incident or Submission

To narrow the search to a specific incident number or package:

```bash
# By incident number
./scripts/get_blocked_failed_reasons.sh -i <incident_number>

# By package name
./scripts/get_blocked_failed_reasons.sh -i <package_name>
```

### 3. Inspect a Single openQA Job Directly

To bypass the dashboard query and directly extract the failure reason and step box for a specific openQA job:

```bash
# By job URL
./scripts/get_blocked_failed_reasons.sh https://openqa.suse.de/tests/<job_id>

# By job ID with full stack trace box
./scripts/get_blocked_failed_reasons.sh -j <job_id> --full-reason
```

*Example:*
```bash
./scripts/get_blocked_failed_reasons.sh https://openqa.suse.de/tests/25025671
```
Yields:
```text
Job: [25025671] sle-16.0-Online-Updates-Staging-Install-ppc64le-Build:git:9372:python3-qam-incidentinstall-SLFO@ppc64le-p10-virtio (failed)
URL: https://openqa.suse.de/tests/25025671

  Failed module: tests/updinstall/SLFO_update_install.pm
  Failed step: #step/SLFO_update_install/23 (https://openqa.suse.de/tests/25025671#step/SLFO_update_install/23)
  Reason: # Test died: No patch found! at sle/tests/qam-updinstall/SLFO_update_install.pm line 108, <$isotovideo> line 1.
```

### 4. Output Formats for Pipeline & CLI Tooling

- **Failing Perl Modules Only** (one per line, deduplicated):
  ```bash
  ./scripts/get_blocked_failed_reasons.sh -m
  ./scripts/get_blocked_failed_reasons.sh -m --module-format pm
  ./scripts/get_blocked_failed_reasons.sh -m --module-format name
  ```
- **Failing Reasons Only**:
  ```bash
  ./scripts/get_blocked_failed_reasons.sh --reasons-only
  ```
- **Job IDs Only** (for `xargs` / batching):
  ```bash
  ./scripts/get_blocked_failed_reasons.sh --ids-only
  ```
- **Job URLs Only**:
  ```bash
  ./scripts/get_blocked_failed_reasons.sh --links-only
  ```
- **Structured JSON**:
  ```bash
  ./scripts/get_blocked_failed_reasons.sh --json | jq .
  ```

### 5. Retry / Restart Failed openQA Jobs

Restart jobs that failed due to sporadic infrastructure issues or transient glitches:

```bash
# 1. Always preview first with dry-run
./scripts/get_blocked_failed_reasons.sh -i <incident> --retry --dry-run

# 2. Execute restart with interactive confirmation
./scripts/get_blocked_failed_reasons.sh -i <incident> --retry

# 3. Non-interactive batch restart
./scripts/get_blocked_failed_reasons.sh -i <incident> --retry -y
```

---

## Triage Guidelines

When reviewing the failure reason extracted by the script:

1. **Product Bug vs Test Issue**:
   - `command '...' failed` / `output not validating`: Compare expected behavior with test code. Check if recent package changes modified CLI flags, error messages, or configuration formats.
   - `No patch found!`: Often indicates maintenance update repository or patch metadata synchronization delay.
   - `timed out`: Differentiate between network/IBS mirror stalls and software hangs.

2. **Cluster / Multi-machine Failures**:
   - In multimachine test suites (e.g. `ha_hawk`, `ovs`, `rsyslog`), check the **server** job first. Client jobs reporting `parallel_failed` are victims of the server node failure.
   - Restart the server job (which automatically restarts or re-triggers dependent cluster jobs).

3. **openQA Overview Resolution**:
   - The script intentionally uses `/api/v1/jobs/overview` rather than `/api/v1/jobs?latest=1` to guarantee querying the current live state and avoid returning older obsoleted job runs.
