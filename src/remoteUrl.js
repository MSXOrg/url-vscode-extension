// @ts-check

/**
 * Convert a git remote URL to a base HTTP(S) URL and provider tag
 * @param {string} remote
 * @returns {{ base: string, provider: 'github'|'gitlab'|'bitbucket'|'azure'|'unknown', host: string, repoPath: string }}
 */
function normalizeRemote(remote) {
    let host = '';
    let repoPath = '';
    if (!remote) {
        return { base: '', provider: 'unknown', host: '', repoPath: '' };
    }

    remote = remote.trim();

    // Collapse duplicated URL schemes like https://https://example.com
    remote = remote.replace(/^(https?):\/\/(?:https?:\/\/)+/i, (_, scheme) => `${scheme.toLowerCase()}://`);
    // Normalize excessive slashes immediately after the scheme
    remote = remote.replace(/^(https?):\/\/\/+/, (_, scheme) => `${scheme.toLowerCase()}://`);

    // Handle HTTP(S) URLs via URL parser for robustness
    if (/^https?:\/\//i.test(remote)) {
        try {
            const url = new URL(remote);
            const protocol = (url.protocol || 'https:').toLowerCase();
            const origin = `${protocol}//${url.host}`;
            host = url.host;
            repoPath = url.pathname.replace(/^\/+/, '').replace(/\.git$/, '');

            if (host.includes('dev.azure.com') || host.includes('visualstudio.com')) {
                const base = `${origin}/${repoPath}`;
                return { base, provider: 'azure', host, repoPath };
            }

            const base = repoPath ? `${origin}/${repoPath}` : origin;
            /** @type {'github'|'gitlab'|'bitbucket'|'unknown'} */
            let provider = 'unknown';
            if (host.includes('github')) provider = 'github';
            else if (host.includes('gitlab')) provider = 'gitlab';
            else if (host.includes('bitbucket')) provider = 'bitbucket';

            return { base, provider, host, repoPath };
        } catch {
            // Fall through to other handlers
        }
    }

    // Handle SSH scp-like: git@host:owner/repo.git
    const scpLike = /^(?:.+@)?([^:\/]+):(.+)$/;
    const sshProto = /^ssh:\/\/(?:.+@)?([^\/:]+)[:\/](.+)$/i;

    const scpMatch = scpLike.exec(remote);
    if (scpMatch) {
        host = scpMatch[1];
        repoPath = scpMatch[2];
    } else {
        const sshMatch = sshProto.exec(remote);
        if (sshMatch) {
            host = sshMatch[1];
            repoPath = sshMatch[2];
        } else {
            try {
                const u = new URL(remote);
                host = u.host;
                repoPath = u.pathname.replace(/^\/+/, '');
            } catch {
                return { base: '', provider: 'unknown', host: '', repoPath: '' };
            }
        }
    }

    // Azure DevOps special cases
    if (host.includes('dev.azure.com') || host.includes('visualstudio.com')) {
        const base = `https://${host}/${repoPath.replace(/\.git$/, '')}`;
        return { base, provider: 'azure', host, repoPath };
    }

    // Strip .git suffix
    repoPath = repoPath.replace(/\.git$/, '');

    const base = `https://${host}/${repoPath}`;
    /** @type {'github'|'gitlab'|'bitbucket'|'unknown'} */
    let provider = 'unknown';
    if (host.includes('github')) provider = 'github';
    else if (host.includes('gitlab')) provider = 'gitlab';
    else if (host.includes('bitbucket')) provider = 'bitbucket';

    return { base, provider, host, repoPath };
}

/**
 * Compose a URL to view a folder at a given branch and relative path for the given provider
 * @param {{base: string, provider: string}} info
 * @param {string} branch
 * @param {string} relPosix
 */
function composeFolderUrl(info, branch, relPosix) {
    const rel = relPosix ? `/${encodeURIComponent(relPosix).replace(/%2F/g, '/')}` : '';
    const br = encodeURIComponent(branch || 'HEAD');

    switch (info.provider) {
        case 'github':
            return `${info.base}/tree/${br}${rel}`;
        case 'gitlab':
            return `${info.base}/-/tree/${br}${rel}`;
        case 'bitbucket':
            return `${info.base}/src/${br}${rel}`;
        case 'azure': {
            const qp = new URLSearchParams();
            qp.set('path', '/' + (relPosix || ''));
            qp.set('version', 'GB' + (branch || 'HEAD'));
            qp.set('_a', 'contents');
            return `${info.base}?${qp.toString()}`;
        }
        default:
            return `${info.base}/tree/${br}${rel}`;
    }
}

/**
 * Compose a URL to view a file at a given branch and relative path for the given provider
 * @param {{base: string, provider: string}} info
 * @param {string} branch
 * @param {string} relPosix
 */
function composeFileUrl(info, branch, relPosix) {
    const rel = relPosix ? `/${encodeURIComponent(relPosix).replace(/%2F/g, '/')}` : '';
    const br = encodeURIComponent(branch || 'HEAD');

    switch (info.provider) {
        case 'github':
            return `${info.base}/blob/${br}${rel}`;
        case 'gitlab':
            return `${info.base}/-/blob/${br}${rel}`;
        case 'bitbucket':
            return `${info.base}/src/${br}${rel}`;
        case 'azure': {
            const qp = new URLSearchParams();
            qp.set('path', '/' + (relPosix || ''));
            qp.set('version', 'GB' + (branch || 'HEAD'));
            qp.set('_a', 'contents');
            return `${info.base}?${qp.toString()}`;
        }
        default:
            return `${info.base}/blob/${br}${rel}`;
    }
}

module.exports = { normalizeRemote, composeFolderUrl, composeFileUrl };
