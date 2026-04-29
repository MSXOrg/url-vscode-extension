// @ts-check
const vscode = require('vscode');
const path = require('path');
const fs = require('fs').promises;
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
        const api = gitExt.exports.getAPI(1);
        return api;
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
    let chosen = undefined;
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
        if ((stat.type & vscode.FileType.Directory) !== 0) {
            return 'directory';
        }
        if ((stat.type & vscode.FileType.File) !== 0) {
            return 'file';
        }
    } catch {
        // ignore fallthrough
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
    const relClean = rel === '' ? '' : rel;

    /** @type {'file' | 'directory' | 'unknown'} */
    let kind = hint || 'unknown';
    if (!kind || kind === 'unknown') {
        kind = await detectResourceKind(uri);
    }

    const treatAsDirectory = kind === 'directory' || relClean === '';
    if (treatAsDirectory) {
        return composeFolderUrl(info, branch, relClean);
    }

    if (!relClean) {
        throw new Error('Unable to determine repository-relative path for the selected file.');
    }

    return composeFileUrl(info, branch, relClean);
}

/**
 * @param {any} target
 */
async function openRemoteForTarget(target) {
    /** @type {vscode.Uri | undefined} */
    let uri;
    if (!target) {
        return;
    }
    if (target instanceof vscode.Uri) {
        uri = target;
    } else if (target.resourceUri) {
        uri = target.resourceUri;
    } else if (target.uri) {
        uri = target.uri;
    }

    if (!uri) {
        vscode.window.showErrorMessage('Could not determine a URI for this item.');
        return;
    }

    let kind = 'unknown';
    try {
        kind = await detectResourceKind(uri);
        if (kind === 'unknown') {
            vscode.window.showWarningMessage('Could not determine whether the item is a file or folder. Attempting to open anyway.');
        }
    } catch {
        // ignore and attempt anyway
    }

    const url = await computeRemoteUrl(uri, /** @type {any} */(kind));
    await vscode.env.openExternal(vscode.Uri.parse(url));
    vscode.window.setStatusBarMessage('Opened remote URL: ' + url, 3000);
}

/** @type {import('vscode').TreeDataProvider<any>} */
class RemoteFoldersProvider {
    constructor() {
        this._onDidChangeTreeData = new vscode.EventEmitter();
        this.onDidChangeTreeData = this._onDidChangeTreeData.event;
    }

    refresh() { this._onDidChangeTreeData.fire(); }

    /**
     * @param {any} element
     * @returns {Promise<any[]>}
     */
    async getChildren(element) {
        /** @type {readonly vscode.WorkspaceFolder[]} */
        const folders = vscode.workspace.workspaceFolders || [];
        const excludes = vscode.workspace.getConfiguration('remoteFolders').get('exclude') || [];
        const excludeSet = new Set(excludes);
        if (!element) {
            return folders.map((/** @type {vscode.WorkspaceFolder} */ f) => ({ uri: f.uri, depth: 0, label: path.basename(f.uri.fsPath) }));
        }
        try {
            /** @type {any[]} */
            const entries = await fs.readdir(element.uri.fsPath, { withFileTypes: true });
            const dirs = entries
                .filter((/** @type {any} */ e) => e.isDirectory())
                .map((/** @type {any} */ e) => e.name);
            const filtered = dirs.filter((/** @type {string} */ name) => !excludeSet.has(name));
            return filtered.map((/** @type {string} */ name) => ({
                uri: vscode.Uri.file(path.join(element.uri.fsPath, name)),
                depth: (element.depth || 0) + 1,
                label: name
            }));
        } catch (e) {
            return [];
        }
    }

    /**
     * @param {any} element
     * @returns {Promise<vscode.TreeItem>}
     */
    async getTreeItem(element) {
        const item = new vscode.TreeItem(element.label, vscode.TreeItemCollapsibleState.Collapsed);
        item.resourceUri = element.uri;
        item.contextValue = 'rf.folder';

        let remoteUrl = undefined;

        try {
            const gitApi = await getGitApi();
            if (gitApi) {
                const repo = getRepositoryForUri(gitApi, element.uri);
                if (repo) {
                    /** @type {Array<{name?: string, fetchUrl?: string, pushUrl?: string}>} */
                    const remotes = repo.state.remotes || [];
                    const origin = remotes.find(r => r.name === 'origin') || remotes[0];
                    if (origin && (origin.fetchUrl || origin.pushUrl)) {
                        item.description = '🌐';
                        remoteUrl = await computeRemoteUrl(element.uri, 'directory');
                    }
                }
            }
        } catch {
            // Ignore errors
        }

        if (remoteUrl) {
            const tooltip = new vscode.MarkdownString();
            tooltip.isTrusted = true;
            tooltip.appendMarkdown(`\`${toPosix(element.uri.fsPath)}\``);
            tooltip.appendMarkdown(`\n\n[Open remote folder](${remoteUrl})`);
            tooltip.appendMarkdown('\n\nUse the inline globe button to open in your browser.');
            item.tooltip = tooltip;
        } else {
            item.tooltip = element.uri.fsPath;
        }

        return item;
    }
}

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
    const provider = new RemoteFoldersProvider();

    context.subscriptions.push(
        vscode.window.registerTreeDataProvider('remoteFoldersView', provider)
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('remoteFolders.openRemote',
            /** @param {any} arg */
            async (arg) => {
                openRemoteForTarget(arg);
            })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('remoteFolders.openRemoteFromExplorer',
            /** @param {any} uri @param {any[]} [selectedUris] */
            async (uri, selectedUris) => {
                if (Array.isArray(selectedUris) && selectedUris.length > 1) {
                    for (const u of selectedUris) {
                        await openRemoteForTarget(u);
                    }
                } else {
                    await openRemoteForTarget(uri);
                }
            })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('remoteFolders.refresh', () => {
            provider.refresh();
        })
    );

    context.subscriptions.push(
        vscode.commands.registerCommand('remoteFolders.openRemoteForActiveFile', async () => {
            const activeEditor = vscode.window.activeTextEditor;
            let targetUri;

            if (activeEditor) {
                targetUri = activeEditor.document.uri;
            } else {
                const workspaceFolders = vscode.workspace.workspaceFolders;
                if (workspaceFolders && workspaceFolders.length > 0) {
                    targetUri = workspaceFolders[0].uri;
                } else {
                    vscode.window.showErrorMessage('No active file or workspace folder found.');
                    return;
                }
            }

            await openRemoteForTarget(targetUri);
        })
    );
}

function deactivate() { }

module.exports = { activate, deactivate };
