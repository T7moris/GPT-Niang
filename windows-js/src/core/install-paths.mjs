import path from 'node:path';

export function stableInstallPaths(env=process.env) {
  // MSIX can redirect LOCALAPPDATA differently for the desktop, Explorer and
  // Task Scheduler. USERPROFILE identifies the same physical per-user root.
  const profile=env.USERPROFILE||env.HOME;
  if(typeof profile!=='string'||!path.isAbsolute(profile)||/[\x00-\x1f]/.test(profile))throw Error('无法确认用户资料目录，请指定安装及个人数据目录。');
  const base=path.join(profile,'.gpt-niang');
  return {target:path.join(base,'app'),dataDir:path.join(base,'state')};
}
