# Remote Folder URL Button

A lightweight VS Code extension that adds a context menu action to open the Git remote URL for any file or folder in your default browser:

- **Explorer**: Right-click a file or folder → **Open Remote URL in Browser**
- **Source Control**: Right-click a changed file → **Open Remote URL in Browser**

## Supported Hosts

| Host | Folder URL | File URL |
| --- | --- | --- |
| GitHub / GH Enterprise | `tree/<branch>/<path>` | `blob/<branch>/<path>` |
| GitLab | `-/tree/<branch>/<path>` | `-/blob/<branch>/<path>` |
| Bitbucket | `src/<branch>/<path>` | `src/<branch>/<path>` |
| Azure DevOps | `?path=/path&version=GB<branch>` | same |

## Development

```bash
npm install
```

Press `F5` in VS Code to launch the Extension Development Host.

## Packaging

```bash
npm run package
```

## CI/CD

The GitHub Actions workflow automatically:

1. **Calculates the version** from PR labels and existing releases (no manual version bumps needed)
2. **Generates metadata** (version, repository URL, license) in `package.json` at build time
3. **Builds, lints, and packages** the VSIX on every push and PR to `main`
4. **Publishes prereleases** to the Marketplace when a PR has the `prerelease` label
5. **Publishes stable releases** and creates GitHub Releases on merge to `main`
6. **Cleans up prereleases** on merge or when a PR is abandoned

Version bumps are controlled by PR labels: `major`/`breaking`, `minor`/`feature`, `patch`/`fix`. If no label is set, auto-patching applies. Use `NoRelease` to skip releasing.

The publish step requires a `VSCE_PAT` repository secret containing a Visual Studio Marketplace Personal Access Token.

## Settings

- `remoteFolders.preferBranch` — Fallback branch when HEAD cannot be determined

## License

MIT
A repo for managing a VSCode extension that adds a menu option for opening the remote url for a file or folder
