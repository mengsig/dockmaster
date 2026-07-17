# Security

## Trust model

The manhandler is read-only over the repositories it manages except for a few
narrow, guarded fast-forward paths (clone, sync, approved local landing); it
never force-pushes, rewrites history, or discards unlanded work. Credentials a
crewmate needs are passed **by reference, never by value** — the secret is never
written into a brief, commit, task record, log, or review artifact.

## Reporting a vulnerability

Report privately — please do **not** open a public issue for a security problem.
Use GitHub's private vulnerability reporting on this repository ("Security" tab →
"Report a vulnerability"), which discloses the report only to the maintainer.
