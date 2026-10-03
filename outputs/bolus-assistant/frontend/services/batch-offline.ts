export function canQueue(path:string,payload:any){
 if(['/glucose','/insulin','/meals'].includes(path))return true;
 return path==='/diary/batch'&&!payload.activity&&!payload.cycle&&!payload.note;
}
