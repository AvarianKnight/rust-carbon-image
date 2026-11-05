const { Info, Debug } = require('./messages');
const { getServerBranch } = require('./framework');
const { spawnStreaming } = require('../utils/proc');
const fs = require('fs');

function deleteSteamApps() {
  Debug('Deleting SteamApps Folder as a precaution...');
  try { fs.rmSync('/home/container/steamapps', { recursive: true, force: true }); } catch {}
}

function frameworkFlag() {
  // Prefer VERSION when provided; fall back to legacy FRAMEWORK detection
  const branch = getServerBranch();
  return `-beta ${branch}`;
}

function requireSteamCmd() {
  if (!fs.existsSync('/home/container/steamcmd/steamcmd.sh')) {
    throw new Error('steamcmd/steamcmd.sh is missing, so the server install did not complete. Check the install log and reinstall the server.');
  }
}

async function SteamCMD_Validate() {
  Debug('Inside Function: SteamCMD_Validate()');
  requireSteamCmd();
  deleteSteamApps();
  const flag = frameworkFlag();
  const label = flag ? `${flag.replace('-beta ', 'Aux').toUpperCase()} Files` : 'Default Files';
  Info(`Downloading ${label} - Validation On!`);
  await spawnStreaming('./steamcmd/steamcmd.sh', ['+force_install_dir', '/home/container', '+login', 'anonymous', '+app_update', '258550', ...flag.split(' ').filter(Boolean), 'validate', '+quit'], { cwd: '/home/container' });
}

async function SteamCMD_No_Validation() {
  Debug('Inside Function: SteamCMD_No_Validation()');
  requireSteamCmd();
  const flag = frameworkFlag();
  const label = flag ? `${flag.replace('-beta ', 'Aux').toUpperCase()} Files` : 'Default Files';
  Info(`Downloading ${label} - Validation Off!`);
  await spawnStreaming('./steamcmd/steamcmd.sh', ['+force_install_dir', '/home/container', '+login', 'anonymous', '+app_update', '258550', ...flag.split(' ').filter(Boolean), '+quit'], { cwd: '/home/container' });
}

module.exports = { SteamCMD_Validate, SteamCMD_No_Validation };
