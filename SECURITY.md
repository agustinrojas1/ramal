# Security policy

## Supported versions

Ramal is pre-1.0. Only the latest released version receives security fixes.

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private reporting: on the repository's [Security tab](https://github.com/agustinrojas1/ramal/security), choose "Report a vulnerability". Include the Ramal, Ash and AshPostgres versions, the resource and action involved, and a failing test or the smallest call sequence that shows the problem.

You can expect an acknowledgement within a week. A fix is released as a patch version, and the report is credited in `CHANGELOG.md` unless you ask otherwise.

## What counts

Ramal sits between your actions and your data layer, so the reports that matter most are:

- A write inside a branch that reaches the database before `Ramal.merge/2`.
- A read inside a branch that returns rows a policy or filter should have excluded, or a branch that sees another branch's changes.
- A merge that skips validations or policies that the real action would run.
- Branch storage (`Ramal.Storage.Postgres`) loading data that creates atoms or runs code.
