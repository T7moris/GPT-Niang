import fs from 'node:fs';
import path from 'node:path';

// The installed app can be updated after the migration baseline was frozen.
// Only use a current config if it still identifies the same installation.
export function currentInstalledConfig(frozen) {
  if (typeof frozen?.appDir !== 'string') return frozen;
  let current;
  try {
    current = JSON.parse(fs.readFileSync(path.join(frozen.appDir, 'installation.json'), 'utf8').replace(/^\uFEFF/, ''));
  } catch { return frozen; }
  const normalize = value => path.resolve(value).toLowerCase();
  if (current?.candidate === true || typeof current?.appDir !== 'string' || normalize(current.appDir) !== normalize(frozen.appDir)) return frozen;
  const usable = (value, directory) => {
    if (typeof value !== 'string' || !value) return false;
    try { const stat = fs.statSync(value); return directory ? stat.isDirectory() : stat.isFile(); }
    catch { return false; }
  };
  return { ...frozen,
    dataDir: usable(current.dataDir, true) ? current.dataDir : frozen.dataDir,
    nodePath: usable(current.nodePath, false) ? current.nodePath : frozen.nodePath,
    codexPath: usable(current.codexPath, false) ? current.codexPath : frozen.codexPath };
}

export function copyConfigurationFiles(sourceDir, destinationDir) {
  for (const name of [
    'settings.json', 'quotes.json', 'quote-sources.json', 'audio-preferences.json',
    'update-preferences.json', 'characters.json', 'color-triggers.json'
  ]) for (const filename of [name, name + '.bak']) {
    const source = path.join(sourceDir, filename);
    if (fs.existsSync(source) && fs.lstatSync(source).isFile())
      fs.copyFileSync(source, path.join(destinationDir, filename), fs.constants.COPYFILE_EXCL);
  }
}
