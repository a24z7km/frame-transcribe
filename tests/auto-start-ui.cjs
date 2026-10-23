const fs = require('fs'), vm = require('vm'), assert = require('assert');
const nodes = new Map(), uploads = [];
let speech = {state:'idle'}, translation = {state:'idle'}, holdUpload = true, releaseUpload;
const get = id => {
  if (!nodes.has(id)) nodes.set(id, {value:'',textContent:'',style:{},events:{},classList:{toggle(){},add(){},remove(){}},addEventListener(event,fn){this.events[event]=fn;}});
  return nodes.get(id);
};
const response = value => ({ok:true,json:async()=>value});
const context = vm.createContext({setTimeout,clearTimeout,document:{getElementById:get},window:{addEventListener(){}},fetch:async(url, options)=>{
  if(url==='/api/session') return response({token:'session-token'});
  if(url==='/api/status') return response(speech);
  if(url==='/api/translation') return response(translation);
  if(url==='/api/transcribe') {
    uploads.push(options);
    if(holdUpload) await new Promise(resolve=>{releaseUpload=resolve;});
    speech={state:'done',running:false,text:'The meeting starts at nine.',segments:[]};
    translation={state:'done',running:false,source:speech.text,text:'会議は9時に始まります。'};
    return response({ok:true});
  }
  throw new Error('Unexpected request: '+url);
}});
vm.runInContext(fs.readFileSync('dist/app.js','utf8'),context);
(async()=>{
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(uploads.length,0,'opening the page does not submit a recording');
  const file={name:'meeting.mp3',size:1000};
  const pending=get('file').events.change({target:{files:[file]}});
  assert.equal(uploads.length,1,'selection starts without a button click');
  assert.strictEqual(uploads[0].body,file);
  assert.equal(uploads[0].headers['X-App-Token'],'session-token');
  assert.equal(get('file').disabled,true);
  get('drop').events.drop({preventDefault(){},dataTransfer:{files:[file]}});
  assert.equal(uploads.length,1,'another drop while uploading cannot start a duplicate');
  releaseUpload(); await pending;
  assert.equal(get('result').value,speech.text);
  assert.equal(get('japanese').value,translation.text,'automatic translation appears without another action');
  assert.equal(get('file').disabled,false);
  assert.equal(get('file').value,'','the same file can be selected again');
  holdUpload=false;
  await get('drop').events.drop({preventDefault(){},dataTransfer:{files:[{name:'meeting.mp4',size:2000}]}});
  assert.equal(uploads.length,2,'drag and drop also starts automatically');
  await get('file').events.change({target:{files:[{name:'notes.pdf',size:1000}]}});
  assert.equal(uploads.length,2,'invalid files do not start a job');
  assert.equal(get('result').value,speech.text,'invalid selection preserves the previous result');
  console.log('PASS: file selection and drop auto-start, duplicate upload blocked, Japanese result displayed');
})().catch(error=>{console.error(error);process.exitCode=1;});
