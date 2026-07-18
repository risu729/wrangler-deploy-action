# Contributing

Use Conventional Commit subjects so Release Please can determine the next
semantic version:

- `fix:` for a patch release
- `feat:` for a minor release
- `feat!:` or a `BREAKING CHANGE:` footer for a major release

Install and validate the repository with mise:

```sh
mise install
mise run check --lint
mise run test
```

Pull requests should keep the action focused on Wrangler deployment mechanics.
Workflow triggers, job permissions, environments, builds, and required-check
guards belong to the calling repository.
