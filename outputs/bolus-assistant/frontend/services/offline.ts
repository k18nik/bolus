import {post,ApiError} from './api';
import {canQueue} from './batch-offline';
type Pending={id:string;userId:string;path:string;payload:any;queuedAt:string;error?:string};
function db():Promise<IDBDatabase>{return new Promise((resolve,reject)=>{const req=indexedDB.open('bolus-offline',1);req.onupgradeneeded=()=>req.result.createObjectStore('queue',{keyPath:'id'});req.onsuccess=()=>resolve(req.result);req.onerror=()=>reject(req.error);});}
async function store(mode:IDBTransactionMode,action:(s:IDBObjectStore)=>IDBRequest){const database=await db();return new Promise<any>((resolve,reject)=>{const tx=database.transaction('queue',mode);const r=action(tx.objectStore('queue'));let result:any;r.onsuccess=()=>{result=r.result;};tx.oncomplete=()=>{database.close();resolve(result);};tx.onerror=()=>{database.close();reject(tx.error);};});}
export async function pending(userId:string):Promise<Pending[]>{return (await store('readonly',s=>s.getAll())).filter((r:Pending)=>r.userId===userId);}
export async function clearQueue(userId:string){for(const r of await pending(userId))await store('readwrite',s=>s.delete(r.id));}
export async function saveOrQueue(userId:string,path:string,payload:any){try{return await post(path,payload);}catch(e){if(!(e instanceof ApiError)||e.status!==0||!canQueue(path,payload))throw e;await store('readwrite',s=>s.put({id:payload.client_id,userId,path,payload,queuedAt:new Date().toISOString()}));return {queued:true};}}
let syncing=false;
export async function syncQueue(userId:string){if(syncing)return;syncing=true;try{for(const r of await pending(userId)){try{await post(r.path,r.payload);await store('readwrite',s=>s.delete(r.id));}catch(e){if(e instanceof ApiError&&e.status===0)break;await store('readwrite',s=>s.put({...r,error:e instanceof Error?e.message:'Ошибка синхронизации'}));}}}finally{syncing=false;}}
