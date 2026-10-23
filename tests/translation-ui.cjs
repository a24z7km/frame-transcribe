const fs = require('fs'), vm = require('vm'), assert = require('assert');
const nodes = new Map(), calls = [], files = [];
let job = {state:'idle',running:false,text:''};
const get = id => {
  if (!nodes.has(id)) nodes.set(id, {value:'',textContent:'',style:{},events:{},classList:{toggle(){},add(){},remove(){}},addEventListener(event,fn){this.events[event]=fn;}});
  return nodes.get(id);
};
const context = vm.createContext({Blob,URL:{createObjectURL(blob){files.push(blob);return 'blob:test'},revokeObjectURL(){}},setTimeout,clearTimeout,confirm:()=>true,document:{getElementById:get,createElement(){return {click(){}}}},window:{addEventListener(){}},fetch:async(url, options)=>{
  if(url==='/api/session') return {ok:true,json:async()=>({token:'test-token'})};
  if(url==='/api/status') return {ok:true,json:async()=>({state:'idle'})};
  if(url==='/api/translation') return {ok:true,json:async()=>job};
  calls.push({url,payload:JSON.parse(options.body)});
  job={state:'done',running:false,text:'会議は明日の朝９時に始まります。',source:JSON.parse(options.body).text,message:'日本語への翻訳が完了しました。'};
  return {ok:true,json:async()=>({ok:true})};
}});
vm.runInContext(fs.readFileSync('dist/app.js','utf8'),context);
(async()=>{
 await new Promise(resolve=>setImmediate(resolve));
 const source='The meeting starts tomorrow morning. '.repeat(1000);
 get('result').value=source;get('result').events.input();
 assert.equal(get('translate').disabled,false);
 await get('translate').events.click();
 assert.equal(calls.length,1,'whole transcript submitted once; no manual or browser-side splitting');
 assert.equal(calls[0].payload.text,source.trim());
 assert.equal(get('result').value,source);
 assert.equal(get('japanese').value,'会議は明日の朝９時に始まります。');
 assert.equal(get('txt-ja').disabled,false);
 get('japanese').value='編集した日本語訳';get('txt-ja').events.click();
 assert.equal(await files[0].text(),'編集した日本語訳');
 job={state:'done',running:false,prepareOnly:true,text:'',message:'準備完了'};
 await vm.runInContext('pollTranslation()',context);
 assert.equal(get('japanese').value,'編集した日本語訳','model preparation preserves existing translation');
 console.log('PASS: 30k+ English text in one click, original preserved, Japanese export, prepare preserves translation');
})().catch(error=>{console.error(error);process.exitCode=1});
