const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { Info, Debug, Success, Error, Warn } = require('../helpers/messages');

// Key lives on the container's ephemeral filesystem, never in the server volume
const KEY_PATH = '/tmp/.carbon_git_key';
const KNOWN_HOSTS = '/home/container/.ssh/known_hosts';

// Pterodactyl variables are single-line, so accept the key in several shapes:
// a file path under /home/container, a PEM with real or literal "\n" newlines,
// a PEM whose newlines were flattened into spaces, or a base64-encoded PEM.
function normalizeKey(raw) {
  let val = (raw || '').trim();
  if (!val) return '';

  if (!val.includes('-----BEGIN')) {
    const candidate = path.resolve('/home/container', val);
    if (val.length < 4096 && fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
      return normalizeKey(fs.readFileSync(candidate, 'utf8'));
    }
    const decoded = Buffer.from(val, 'base64').toString('utf8');
    if (decoded.includes('-----BEGIN')) return normalizeKey(decoded);
    return '';
  }

  val = val.replace(/\\n/g, '\n').replace(/\r/g, '');
  const m = val.match(/(-----BEGIN [A-Z0-9 ]+-----)([\s\S]*?)(-----END [A-Z0-9 ]+-----)/);
  if (!m) return '';
  const body = m[2].trim().split(/\s+/).join('\n');
  return `${m[1]}\n${body}\n${m[3]}\n`;
}

function git(args, opts = {}) {
  Debug(`git ${args.join(' ')}`);
  const res = spawnSync('git', args, { encoding: 'utf8', ...opts });
  if (res.error) throw res.error;
  if (res.status !== 0) {
    throw new globalThis.Error(`git ${args[0]} failed: ${(res.stderr || res.stdout || '').trim()}`);
  }
  return (res.stdout || '').trim();
}

function carbonGitSync() {
  Debug('-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=');
  Debug('Inside of /sections/carbon_git_sync.js');

  // The environment is passed on to the game server, so plugins must not inherit the key
  const rawKey = process.env.CARBON_GIT_KEY || '';
  delete process.env.CARBON_GIT_KEY;

  const url = (process.env.CARBON_GIT_URL || '').trim();
  if (!url) {
    Success('No Carbon git repository set. Skipping this part...');
    return;
  }
  if (!/carbon/i.test(process.env.FRAMEWORK || '')) {
    Warn('CARBON_GIT_URL is set but the framework is not Carbon. Skipping git sync.');
    return;
  }

  const root = process.env.MODDING_ROOT || '';
  if (!/^[A-Za-z0-9._-]+$/.test(root) || root === '.' || root === '..') {
    Error(`MODDING_ROOT '${root}' must be a single folder name to use git sync. Skipping git sync.`);
    return;
  }

  const branch = (process.env.CARBON_GIT_BRANCH || '').trim();
  const target = `/home/container/${root}`;
  Info(`Syncing ${root} folder from git...`);

  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0' };
  const sshOpts = [
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    '-o', `UserKnownHostsFile=${KNOWN_HOSTS}`,
  ];

  try {
    fs.mkdirSync(path.dirname(KNOWN_HOSTS), { recursive: true, mode: 0o700 });

    if (rawKey.trim()) {
      const key = normalizeKey(rawKey);
      if (!key) {
        Error('CARBON_GIT_KEY is set but could not be parsed as a private key. Skipping git sync.');
        return;
      }
      fs.writeFileSync(KEY_PATH, key, { mode: 0o600 });
      fs.chmodSync(KEY_PATH, 0o600);
      sshOpts.unshift('-i', KEY_PATH, '-o', 'IdentitiesOnly=yes');
    }
    env.GIT_SSH_COMMAND = `ssh ${sshOpts.join(' ')}`;

    const run = (args) => git(args, { cwd: target, env });

    if (fs.existsSync(path.join(target, '.git'))) {
      run(['remote', 'set-url', 'origin', url]);

      let ref = branch;
      if (!ref) {
        // Resolve the remote's default branch
        const head = run(['ls-remote', '--symref', 'origin', 'HEAD']);
        const m = head.match(/^ref:\s+refs\/heads\/(\S+)\s+HEAD/m);
        ref = m ? m[1] : 'main';
      }
      Debug(`Using branch '${ref}'`);

      run(['fetch', '--depth', '1', 'origin', ref]);
      run(['checkout', '-q', '-f', '-B', ref, 'FETCH_HEAD']);
      run(['reset', '-q', '--hard', 'FETCH_HEAD']);
    } else {
      let entries = [];
      try { entries = fs.readdirSync(target); } catch {}
      if (entries.length > 0) {
        // Never wipe a folder that was not installed from git; only a reinstall does that
        Error(`${root} already has files but is not a git clone. Reinstall the server to replace it with the repository. Skipping git sync.`);
        return;
      }
      const args = ['clone', '-q', '--depth', '1'];
      if (branch) args.push('--branch', branch);
      git([...args, url, target], { cwd: '/home/container', env });
    }

    const ref = run(['rev-parse', '--abbrev-ref', 'HEAD']);
    const rev = run(['rev-parse', '--short', 'HEAD']);
    Success(`${root} folder synced from git (${ref} @ ${rev})`);
  } catch (e) {
    Error(`Failed to sync ${root} folder from git: ${e?.message || e}`);
    Warn(`Continuing startup with the existing ${root} folder.`);
  } finally {
    try { fs.rmSync(KEY_PATH, { force: true }); } catch {}
  }

  if (process.env.FRAMEWORK_UPDATE !== '1' && !fs.existsSync(`${target}/managed/Carbon.Preloader.dll`)) {
    Warn(`${root}/managed has no Carbon files and the framework update is off. Turn on the Framework Update variable so Carbon can be installed.`);
  }
}

module.exports = { carbonGitSync };
