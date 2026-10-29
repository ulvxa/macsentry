# Security Policy

MacSentry moves files on users' disks, so safety bugs are treated as security bugs.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through GitHub's private vulnerability reporting:

1. Go to the [Security tab](https://github.com/ulvxa/macsentry/security) of the repository.
2. Click **Report a vulnerability**.
3. Describe the issue, the affected version, and steps or a fixture to reproduce it.

You will get an acknowledgement as soon as possible, and a fix or mitigation plan once the report is confirmed. Credit is given in the release notes unless you prefer otherwise.

## What counts

- Any path where MacSentry moves, trashes or modifies something `ProtectionPolicy` should deny (system files, credentials, keychains, user data, git working trees, never-touch patterns).
- Any way to make MacSentry delete a file directly instead of moving it to quarantine or the Trash.
- Path traversal or symlink tricks that move items outside the quarantine folder, or restore them somewhere unexpected.
- A rule that matches user data and marks it green.
- Anything that causes MacSentry to make network requests or leak file paths.

## Supported versions

Only the latest release receives fixes.
