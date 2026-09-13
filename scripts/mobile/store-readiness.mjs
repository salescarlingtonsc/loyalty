#!/usr/bin/env node

import {mkdir,readFile,writeFile} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname,join,resolve} from 'node:path';

const root=fileURLToPath(new URL('../../',import.meta.url));
const args=process.argv.slice(2);
const wantsGenerate=args.includes('--generate');
const outputIndex=args.indexOf('--output');
const output=outputIndex>=0?resolve(args[outputIndex+1]||''):null;
const packageName='asia.peekaa.app';
const teamId=String(process.env.APPLE_TEAM_ID||'').trim();
const fingerprint=String(process.env.ANDROID_SHA256_CERT_FINGERPRINT||'').trim().toUpperCase();
const fingerprintPattern=/^(?:[0-9A-F]{2}:){31}[0-9A-F]{2}$/;

function refuse(message){
  process.stderr.write(`Store readiness refused: ${message}\n`);
  process.exitCode=1;
}

const capacitor=await readFile(join(root,'capacitor.config.ts'),'utf8');
if(!new RegExp(`appId:\\s*['\"]${packageName.replaceAll('.','\\.')}['\"]`).test(capacitor)){
  refuse(`Capacitor appId must remain ${packageName}.`);
}

const icon=await readFile(join(root,'ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png'));
const pngChunkTypes=bytes=>{
  const types=[];let offset=8;
  while(offset+12<=bytes.length){const length=bytes.readUInt32BE(offset),type=bytes.subarray(offset+4,offset+8).toString('ascii');types.push(type);offset+=12+length;if(type==='IEND')break}
  return types;
};
if(icon.subarray(1,4).toString()!=='PNG'||icon.readUInt32BE(16)!==1024||icon.readUInt32BE(20)!==1024){
  refuse('the iOS marketing icon must be a 1024 × 1024 PNG.');
}else if([4,6].includes(icon[25])||pngChunkTypes(icon).includes('tRNS')){
  refuse('the iOS marketing icon contains an alpha channel.');
}

/* Android / Play. The same fail-closed spirit as the iOS block above: each of these is a thing
   Play rejects a bundle for, and each is cheap to check locally. targetSdk is the one with a
   moving deadline — Play has required API 35 for new submissions since 31 August 2025 — so it is
   asserted as a floor, not an equality. */
const gradle=await readFile(join(root,'android/app/build.gradle'),'utf8');
const manifest=await readFile(join(root,'android/app/src/main/AndroidManifest.xml'),'utf8');
const strings=await readFile(join(root,'android/app/src/main/res/values/strings.xml'),'utf8');
const variables=await readFile(join(root,'android/variables.gradle'),'utf8');
const pbxproj=await readFile(join(root,'ios/App/App.xcodeproj/project.pbxproj'),'utf8');

if(!new RegExp(`applicationId\\s+["']${packageName.replaceAll('.','\\.')}["']`).test(gradle)){
  refuse(`the Android applicationId must remain ${packageName}.`);
}
const marketingVersions=[...pbxproj.matchAll(/MARKETING_VERSION = ([^;]+);/g)].map(match=>match[1].trim());
const iosVersion=marketingVersions[0];
const androidVersionName=(gradle.match(/versionName\s+"([^"]+)"/)||[])[1];
if(!iosVersion||marketingVersions.some(version=>version!==iosVersion)){
  refuse('the iOS MARKETING_VERSION must be one single value across build configurations.');
}else if(androidVersionName!==iosVersion){
  refuse(`versionName ${androidVersionName} must match the iOS MARKETING_VERSION ${iosVersion}.`);
}
const versionCode=Number((gradle.match(/versionCode\s+(\d+)/)||[])[1]);
if(!Number.isInteger(versionCode)||versionCode<1)refuse('versionCode must be a positive integer.');
const targetSdk=Number((variables.match(/targetSdkVersion\s*=\s*(\d+)/)||[])[1]);
if(!(targetSdk>=35))refuse(`targetSdkVersion ${targetSdk} is below the API 35 floor Play requires.`);
if(!/android:usesCleartextTraffic="false"/.test(manifest))refuse('the Android manifest must keep cleartext traffic disabled.');
if(!/<string name="app_name">Peekaa<\/string>/.test(strings))refuse('the Android launcher label must remain Peekaa.');
for(const density of ['mdpi','hdpi','xhdpi','xxhdpi','xxxhdpi']){
  const launcher=join(root,`android/app/src/main/res/mipmap-${density}/ic_launcher.png`);
  if(!existsSync(launcher))refuse(`missing Android launcher icon: mipmap-${density}/ic_launcher.png`);
}
const playIcon=await readFile(join(root,'app/icons/peekaa-512.png'));
if(playIcon.subarray(1,4).toString()!=='PNG'||playIcon.readUInt32BE(16)!==512||playIcon.readUInt32BE(20)!==512){
  refuse("Play's hi-res listing icon (app/icons/peekaa-512.png) must be a 512 × 512 PNG.");
}

const privacyManifests=[
  'node_modules/@capacitor/ios/Capacitor/Capacitor/PrivacyInfo.xcprivacy',
  'node_modules/@capacitor/ios/CapacitorCordova/CapacitorCordova/PrivacyInfo.xcprivacy'
];
for(const path of privacyManifests){if(!existsSync(join(root,path)))refuse(`missing dependency privacy manifest: ${path}`)}

if(wantsGenerate){
  if(!/^[A-Z0-9]{10}$/.test(teamId))refuse('APPLE_TEAM_ID must be the real 10-character Apple Team ID.');
  if(!fingerprintPattern.test(fingerprint))refuse('ANDROID_SHA256_CERT_FINGERPRINT must be the real 32-byte Play signing SHA-256 fingerprint.');
  if(!output)refuse('--output must name an explicit directory outside app/.');
  if(process.exitCode)process.exit();
  if(output===root||output.startsWith(join(root,'app')))refuse('association output must not overwrite the repository or app/ directly.');
  if(process.exitCode)process.exit();
  await mkdir(output,{recursive:true});
  const aasa={applinks:{apps:[],details:[{appID:`${teamId}.${packageName}`,paths:['/business*','/join.html*','/customer*']}]}};
  const assetlinks=[{relation:['delegate_permission/common.handle_all_urls'],target:{namespace:'android_app',package_name:packageName,sha256_cert_fingerprints:[fingerprint]}}];
  await writeFile(join(output,'apple-app-site-association'),`${JSON.stringify(aasa,null,2)}\n`,{flag:'w'});
  await writeFile(join(output,'assetlinks.json'),`${JSON.stringify(assetlinks,null,2)}\n`,{flag:'w'});
  process.stdout.write(`Generated reviewed association payloads in ${output}\n`);
}else if(!process.exitCode){
  process.stdout.write('Local iOS/Android store configuration checks passed. Signing and live association identifiers remain external release inputs.\n');
}
