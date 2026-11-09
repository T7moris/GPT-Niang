import test from 'node:test';import assert from 'node:assert/strict';import fs from 'node:fs';
import {keepTestWindowHidden,hiddenSurfaceState} from '../src/core/hidden-surface.mjs';
test('hidden candidates intercept every revealing API including restore without calling native methods',()=>{
 const nativeCalls=[],window={};for(const name of ['show','showInactive','focus','flashFrame','moveTop','minimize','restore','maximize','unmaximize','setFullScreen','setKiosk'])window[name]=()=>nativeCalls.push(name);
 keepTestWindowHidden(window);
 window.show();window.showInactive();window.focus();window.flashFrame(true);window.moveTop();window.minimize();assert.equal(window.isMinimized(),true);
 window.restore();assert.equal(window.isMinimized(),false);window.maximize();assert.equal(window.isMaximized(),true);window.unmaximize();assert.equal(window.isMaximized(),false);
 window.setFullScreen(true);assert.equal(window.isFullScreen(),true);window.setKiosk(true);
 assert.deepEqual(nativeCalls,[]);assert.equal(hiddenSurfaceState(window).blocked,11);assert.equal(keepTestWindowHidden(window),window);
});
test('all candidate windows are created through the guarded factory',()=>{
 const source=fs.readFileSync(new URL('../src/main.mjs',import.meta.url),'utf8');
 assert.equal((source.match(/new BrowserWindow\(/g)||[]).length,1);
 assert.equal((source.match(/= createWindow\(/g)||[]).length,5);
 assert.match(source,/return hiddenTest\?keepTestWindowHidden\(window\):window/);
});
