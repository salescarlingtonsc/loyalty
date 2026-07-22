'use strict';

const COMMIT_SHA=/^[0-9a-f]{40}$/i;
const VERCEL_ENVIRONMENTS=new Set(['production','preview','development']);

function safeBuildIdentity(environment=process.env){
  const rawSha=String(environment.VERCEL_GIT_COMMIT_SHA||'').trim();
  const deploymentEnvironment=String(environment.VERCEL_ENV||'').trim();
  if(!COMMIT_SHA.test(rawSha)||!VERCEL_ENVIRONMENTS.has(deploymentEnvironment)){
    return Object.freeze({schemaVersion:1,service:'loyalty',available:false});
  }
  const commitSha=rawSha.toLowerCase();
  return Object.freeze({
    schemaVersion:1,
    service:'loyalty',
    available:true,
    environment:deploymentEnvironment,
    commitSha,
    shortSha:commitSha.slice(0,12)
  });
}

function buildIdentityHandler(request,response){
  if(!['GET','HEAD'].includes(request.method||'GET')){
    response.statusCode=405;
    response.setHeader('Allow','GET, HEAD');
    response.setHeader('Content-Type','application/json; charset=utf-8');
    response.end(JSON.stringify({error:'method_not_allowed'}));
    return;
  }
  const payload=safeBuildIdentity();
  response.statusCode=payload.available?200:503;
  response.setHeader('Cache-Control','public, max-age=0, must-revalidate');
  response.setHeader('Content-Type','application/json; charset=utf-8');
  response.setHeader('X-Content-Type-Options','nosniff');
  response.end(request.method==='HEAD'?'':JSON.stringify(payload));
}

module.exports=buildIdentityHandler;
module.exports.safeBuildIdentity=safeBuildIdentity;
