# Security Policy

AppWrangler pauses, resumes, re-prioritises and can quit other processes, so we take bugs in that area seriously.

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

**Please don't open a public issue.** Report privately through GitHub:

**[Report a vulnerability](https://github.com/IntarsO/AppWrangler/security/advisories/new)** (repository → *Security* → *Advisories* → *Report a vulnerability*)

Please include what you found, how to reproduce it, and the impact you expect. You should get a reply within a week. Once a fix is released, we'll credit you in the release notes unless you'd rather stay anonymous.

## What's in scope

- Ways to make AppWrangler stop, freeze or kill processes it shouldn't (for example, getting around the protected-process list or the per-user boundary).
- Ways for another local user or app to control AppWrangler: the data folder, `rules.json`, or the distributed-notification commands.
- Apps left suspended after AppWrangler exits (other than `kill -9`, which can't be caught).

## Design notes

- AppWrangler runs as **your user**, with no privileged helper and no admin rights. It can only affect processes you could already `kill` from Terminal.
- It isn't sandboxed (the sandbox forbids signalling other apps) and asks for no special permissions.
- It makes **no network connections**.
- CLI commands arrive as distributed notifications, which any process in your login session can post. They can only do what you could already do with `kill`: freeze, unfreeze, pause, resume. Rules are changed only through the `rules.json` file in your own Library folder.
