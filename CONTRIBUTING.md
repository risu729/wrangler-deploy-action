# Contributing

Use Conventional Commit subjects to keep the project history machine-readable:

- `fix:` for a patch release
- `feat:` for a minor release
- `feat!:` or a `BREAKING CHANGE:` footer for a major release

Install and validate the repository with mise:

```sh
mise install
mise run check --lint
```
