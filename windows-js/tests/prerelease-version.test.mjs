import test from 'node:test';import assert from 'node:assert/strict';
import {compareVersions,selectRelease,versionParts} from '../src/core/update-network.mjs';
test('beta versions follow SemVer precedence and can transition to the matching stable version',()=>{
 const order=['1.4.0-alpha','1.4.0-alpha.1','1.4.0-alpha.beta','1.4.0-beta','1.4.0-beta.2','1.4.0-beta.11','1.4.0-rc.1','1.4.0'];
 for(let n=1;n<order.length;n++){assert.equal(compareVersions(order[n-1],order[n]),-1);assert.equal(compareVersions(order[n],order[n-1]),1);}
 assert.equal(compareVersions('v1.4.0-beta.1','1.3.6'),1);assert.equal(compareVersions('1.4.0-beta.1+build.3','1.4.0-beta.1+other'),0);
 for(const version of ['1.4.0-beta.01','01.4.0','1.4.0-','1.4.0-a..b','1.4.0+','1.4.0-beta/1'])assert.throws(()=>compareVersions(version,'1.3.6'));
});
test('stable channel excludes beta assets while beta installations can receive a future stable release',()=>{
 assert.equal(versionParts('v1.4.0-beta.1'),null);
 assert.equal(selectRelease({tag_name:'v1.4.0-beta.1',prerelease:true,assets:[]},'1.3.6'),null);
 const release=version=>({tag_name:'v'+version,prerelease:false,assets:[`gpt-niang-usage-widget-v${version}-windows-js.zip`,'SHA256SUMS.txt'].map(name=>({name,browser_download_url:`https://github.com/T7moris/GPT-Niang/releases/download/v${version}/${name}`}))});
 assert.equal(selectRelease(release('1.3.6'),'1.4.0-beta.1'),null);assert.equal(selectRelease(release('1.4.0'),'1.4.0-beta.1').version,'1.4.0');
});
