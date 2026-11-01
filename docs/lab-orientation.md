# Lab Orientation

Where things live in the iron-cloud workspace.

## Layout

- `platform/` — core platform configuration and glue.
- `departments/` — per-team content and tooling.
- `lab/` — experiments and staging areas; anything here may break at any time.
- `reports/` — generated or curated reports.
- `tests/` — checks over the above.

## Conventions

- New experiments start in `lab/`; once stable, they graduate into `platform/` or `departments/`.
- Departments should not depend on `lab/` content.
- Each directory change that affects others gets a line in this doc or the main README.
