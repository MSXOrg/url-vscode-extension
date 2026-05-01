// @ts-check
const vscode = require('vscode');
const path = require('path');
const { normalizeRemote, composeFolderUrl, composeFileUrl } = require('./remoteUrl');

/**
 * @param {string} p
 * @returns {string}
 */
function toPosix(p) {
    return p.replace(/\\/g, '/');
}

/**
 * Try to get the Git API from the built-in vscode.git extension
 * @returns {Promise<any | undefined>}
 */
async function getGitApi() {
    try {
        const gitExt = vscode.extensions.getExtension('vscode.git');
        if (!gitExt) return undefined;
        if (!gitExt.isActive) {
            await gitExt.activate();
        }
        return gitExt.exports.getAPI(1);
    } catch {
        return undefined;
    }
}

/**
 * Find the git repository object owning the given URI (via vscode.git API)
 * @param {any} gitApi
 * @param {vscode.Uri} uri
 */
function getRepositoryForUri(gitApi, uri) {
    if (!gitApi) return undefined;
    const repos = gitApi.repositories || [];
    let chosen;
    for (const r of repos) {
        const root = r.rootUri;
        if (uri.fsPath.startsWith(root.fsPath)) {
            if (!chosen || root.fsPath.length > chosen.rootUri.fsPath.length) {
                chosen = r;
            }
        }
    }
    return chosen;
}

/**
 * Detect whether the given URI points to a file or folder (best-effort)
 * @param {vscode.Uri} uri
 * @returns {Promise<'file' | 'directory' | 'unknown'>}
 */
async function detectResourceKind(uri) {
    try {
        const stat = await vscode.workspace.fs.stat(uri);
        if ((stat.type & vscode.FileType.Directory) !== 0) return 'directory';
        if ((stat.type & vscode.FileType.File) !== 0) return 'file';
    } catch {
        // ignore
    }
    return 'unknown';
}

/**
 * Compute remote URL for a given URI
 * @param {vscode.Uri} uri
 * @param {'file' | 'directory' | 'unknown'} [hint]
 * @returns {Promise<string>}
 */
async function computeRemoteUrl(uri, hint) {
    const gitApi = await getGitApi();
    if (!gitApi) {
        throw new Error('Git extension API is not available.');
    }
    const repo = getRepositoryForUri(gitApi, uri);
    if (!repo) {
        throw new Error('No Git repository found for the selected item.');
    }

    /** @type {Array<{name?: string, fetchUrl?: string, pushUrl?: string}>} */
    const remotes = repo.state.remotes || [];
    const origin = remotes.find(remote => remote.name === 'origin') || remotes[0];
    const remoteUrl = origin && (origin.fetchUrl || origin.pushUrl);
    if (!remoteUrl) {
        throw new Error('No Git remote URL found (e.g., origin).');
    }

    const info = normalizeRemote(remoteUrl);

    const head = repo.state.HEAD;
    const branch = (head && head.name) || (vscode.workspace.getConfiguration('remoteFolders').get('preferBranch') || 'HEAD');

    const rel = toPosix(path.relative(repo.rootUri.fsPath, uri.fsPath));

    /** @type {'file' | 'directory' | 'unknown'} */
    let kind = hint || 'unknown';
    if (kind === 'unknown') {
        kind = await detectResourceKind(uri);
    }

    const treatAsDirectory = kind === 'directory' || rel === '';
    if (treatAsDirectory) {
        return composeFolderUrl(info, branch, rel);
    }

    if (!rel) {
        throw new Error('Unable to determine repository-relative path for the selected file.');
    }

    return composeFileUrl(info, branch, rel);
}

/**
 * Resolve a URI from any context-menu argument shape (Uri, TreeItem, SCM resource state, etc.)
 * @param {any} target
 * @returns {vscode.Uri | undefined}
 */
function resolveUri(target) {
    if (!target) return undefined;
    if (target instanceof vscode.Uri) return target;
    if (target.resourceUri instanceof vscode.Uri) return target.resourceUri;
    if (target.uri instanceof vscode.Uri) return target.uri;
    return undefined;
}

/**
 * @param {any} target
 */
async function openRemoteForTarget(target) {
    const uri = resolveUri(target);
    if (!uri) {
        vscode.window.showErrorMessage('Could not determine a URI for this item.');
        return;
    }

    const kind = await detectResourceKind(uri);
    try {
        const url = await computeRemoteUrl(uri, kind);
        await vscode.env.openExternal(vscode.Uri.parse(url));
        vscode.window.setStatusBarMessage('Opened remote URL: ' + url, 3000);
    } catch (err) {
        const message = err instanceof Error ? err.message : String(err);
        vscode.window.showErrorMessage(message);
    }
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
    context.subscriptions.push(
        vscode.commands.registerCommand('remoteFolders.openRemote',
            /** @param {any} arg @param {any[]} [selected] */
            async (arg, selected) => {
                if (Array.isArray(selected) && selected.length > 1) {
                    for (const item of selected) {
                        await openRemoteForTarget(item);
                    }
                } else {
                    await openRemoteForTarget(arg);
                }
            })
    );
}

function deactivate() { }

module.exports = { activate, deactivate };
