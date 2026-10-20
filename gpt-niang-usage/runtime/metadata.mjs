import fs from 'node:fs';

// Runtime and installer report the version registered in the plugin manifest.
const manifest = JSON.parse(fs.readFileSync(new URL('../.codex-plugin/plugin.json', import.meta.url), 'utf8').replace(/^\uFEFF/, ''));
export const pluginVersion = manifest.version;
