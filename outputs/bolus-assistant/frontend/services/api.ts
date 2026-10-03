export class ApiError extends Error {status:number;constructor(message:string,status:number){super(message);this.status=status;}}
export function csrf(){return decodeURIComponent(document.cookie.split('; ').find(x=>x.startsWith('csrf='))?.slice(5)||'');}
export async function api<T=any>(path:string,options:RequestInit={}):Promise<T>{
 const headers=new Headers(options.headers);if(!(options.body instanceof FormData))headers.set('Content-Type','application/json');
 if(options.method && options.method!=='GET')headers.set('X-CSRF-Token',csrf());
 let res:Response;try{res=await fetch('/api'+path,{...options,headers,credentials:'same-origin',cache:'no-store'});}catch{throw new ApiError('Нет связи с сервером. Проверьте подключение.',0);}
 if(!res.ok){const body=await res.json().catch(()=>({detail:'Сервис временно недоступен'}));throw new ApiError(typeof body.detail==='string'?body.detail:Array.isArray(body.detail)?body.detail.map((e:any)=>e.msg.replace('Value error, ','')).join('; '):'Не удалось выполнить действие',res.status);}
 return res.json();
}
export const post=(path:string,data:any={})=>api(path,{method:'POST',body:JSON.stringify(data)});
export function newId():string{
 if(typeof crypto.randomUUID==='function')return crypto.randomUUID();
 const bytes=crypto.getRandomValues(new Uint8Array(16));bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;
 const hex=Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join('');
 return `${hex.slice(0,8)}-${hex.slice(8,12)}-${hex.slice(12,16)}-${hex.slice(16,20)}-${hex.slice(20)}`;
}
export function localDate(d=new Date(),timezone='Europe/Moscow'){return new Intl.DateTimeFormat('sv-SE',{timeZone:timezone}).format(d);}
export function decimal(value:number|null|undefined,precision=2){return value===null||value===undefined?'—':value.toLocaleString('ru-RU',{maximumFractionDigits:precision});}
