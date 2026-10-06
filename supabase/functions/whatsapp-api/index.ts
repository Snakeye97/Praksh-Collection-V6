import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.116.0'

const cors={
 'Access-Control-Allow-Origin':'*',
 'Access-Control-Allow-Headers':'authorization, apikey, content-type, x-client-info',
 'Access-Control-Allow-Methods':'GET, POST, OPTIONS'
}
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}})
const admin=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
const graphVersion=Deno.env.get('WHATSAPP_GRAPH_VERSION')||'v26.0'
const phoneNumberId=Deno.env.get('WHATSAPP_PHONE_NUMBER_ID')||''
const accessToken=Deno.env.get('WHATSAPP_ACCESS_TOKEN')||''
const verifyToken=Deno.env.get('WHATSAPP_VERIFY_TOKEN')||''
const appSecret=Deno.env.get('WHATSAPP_APP_SECRET')||''
const countryCode=(Deno.env.get('WHATSAPP_DEFAULT_COUNTRY_CODE')||'91').replace(/\D/g,'')

function bearer(req:Request){const h=req.headers.get('authorization')||'';return h.startsWith('Bearer ')?h.slice(7):''}
function normalizePhone(v:string){const digits=v.replace(/\D/g,'');return digits.length===10?countryCode+digits:digits}
function localPhone(v:string){const digits=v.replace(/\D/g,'');return digits.slice(-10)}

async function verifySignature(raw:string,signature:string){
 if(!appSecret||!signature.startsWith('sha256='))return false
 const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(appSecret),{name:'HMAC',hash:'SHA-256'},false,['sign'])
 const signed=await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(raw))
 const expected='sha256='+Array.from(new Uint8Array(signed)).map(x=>x.toString(16).padStart(2,'0')).join('')
 if(expected.length!==signature.length)return false
 let diff=0;for(let i=0;i<expected.length;i++)diff|=expected.charCodeAt(i)^signature.charCodeAt(i)
 return diff===0
}

async function requireOwner(req:Request){
 const token=bearer(req);if(!token)throw new Error('Owner login required.')
 const {data,error}=await admin.auth.getUser(token);if(error||!data.user)throw new Error('Owner session expired.')
 const {data:owner,error:ownerError}=await admin.from('owner_users').select('user_id').eq('user_id',data.user.id).maybeSingle()
 if(ownerError||!owner)throw new Error('Owner access required.')
 return data.user
}

async function sendMeta(payload:Record<string,unknown>){
 if(!phoneNumberId||!accessToken)throw new Error('WhatsApp API secrets are not configured.')
 const r=await fetch(`https://graph.facebook.com/${graphVersion}/${phoneNumberId}/messages`,{
  method:'POST',headers:{'Authorization':`Bearer ${accessToken}`,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',...payload})
 })
 const data=await r.json().catch(()=>({}))
 if(!r.ok)throw new Error((data as any)?.error?.message||`WhatsApp API error ${r.status}`)
 return data as any
}

async function sendText(to:string,body:string,customerId:string|null=null){
 const normalized=normalizePhone(to)
 const data=await sendMeta({to:normalized,type:'text',text:{body}})
 await admin.from('whatsapp_messages').insert({customer_id:customerId,direction:'outbound',phone:normalized,message_type:'text',body,meta_message_id:data?.messages?.[0]?.id||null,status:'sent'})
 return data
}

async function sendTemplate(to:string,templateName:string,languageCode:string,customerId:string|null=null){
 const normalized=normalizePhone(to)
 const data=await sendMeta({to:normalized,type:'template',template:{name:templateName,language:{code:languageCode}}})
 await admin.from('whatsapp_messages').insert({customer_id:customerId,direction:'outbound',phone:normalized,message_type:'template',body:templateName,meta_message_id:data?.messages?.[0]?.id||null,status:'sent'})
 return data
}

async function campaignRecipients(audience:string){
 const {data:customers,error}=await admin.from('customers').select('id,name,phone,marketing_consent').eq('marketing_consent',true)
 if(error)throw error
 if(audience==='all')return customers||[]
 const ids=(customers||[]).map(x=>x.id);if(!ids.length)return []
 const [{data:bills,error:billError},{data:redemptions,error:redError}]=await Promise.all([
  admin.from('bills').select('customer_id,amount,points,status').in('customer_id',ids).eq('status','approved'),
  admin.from('redemptions').select('customer_id,points').in('customer_id',ids)
 ])
 if(billError)throw billError;if(redError)throw redError
 const earned=new Map<string,number>(),used=new Map<string,number>(),spent=new Map<string,number>()
 for(const b of bills||[]){earned.set(b.customer_id,(earned.get(b.customer_id)||0)+Number(b.points||0));spent.set(b.customer_id,(spent.get(b.customer_id)||0)+Number(b.amount||0))}
 for(const r of redemptions||[])used.set(r.customer_id,(used.get(r.customer_id)||0)+Number(r.points||0))
 return (customers||[]).filter(c=>audience==='points'?((earned.get(c.id)||0)-(used.get(c.id)||0)>0):(spent.get(c.id)||0)>=5000)
}

async function ownerAction(req:Request,body:any){
 await requireOwner(req)
 if(body.action!=='send_promotion')return json({ok:false,error:'Unknown owner action.'},400)
 const promotionId=String(body.promotion_id||'')
 const {data:promotion,error}=await admin.from('promotions').select('*').eq('id',promotionId).maybeSingle()
 if(error)throw error;if(!promotion)return json({ok:false,error:'Promotion not found.'},404)
 if(promotion.status==='sending')return json({ok:false,error:'Promotion is already sending.'},409)
 await admin.from('promotions').update({status:'sending',sent_count:0,failed_count:0}).eq('id',promotion.id)
 const recipients=await campaignRecipients(promotion.audience)
 const batch=recipients.slice(0,100)
 let sent=0,failed=0
 for(const customer of batch){
  try{await sendTemplate(customer.phone,promotion.template_name,promotion.language_code,customer.id);sent++}
  catch(e){failed++;await admin.from('whatsapp_messages').insert({customer_id:customer.id,direction:'outbound',phone:normalizePhone(customer.phone),message_type:'template',body:promotion.template_name,status:'failed'})}
 }
 const partial=recipients.length>batch.length
 const status=failed===0&&!partial?'sent':sent>0?'partial':'failed'
 await admin.from('promotions').update({status,sent_count:sent,failed_count:failed+(recipients.length-batch.length),sent_at:new Date().toISOString()}).eq('id',promotion.id)
 return json({ok:true,sent,failed,remaining:Math.max(0,recipients.length-batch.length),status})
}

async function handleIncoming(payload:any){
 const value=payload?.entry?.[0]?.changes?.[0]?.value
 const messages=value?.messages||[]
 for(const m of messages){
  const from=String(m?.from||'');const text=String(m?.text?.body||'').trim();if(!from||!text)continue
  const phone=localPhone(from)
  const {data:customer}=await admin.from('customers').select('id,name,phone').eq('phone',phone).maybeSingle()
  await admin.from('whatsapp_messages').insert({customer_id:customer?.id||null,direction:'inbound',phone:from,message_type:m?.type||'text',body:text,meta_message_id:m?.id||null,status:'received'})
  const cmd=text.toUpperCase().trim()
  if(!customer){await sendText(from,'Welcome to PRAKSH COLLECTION. Please create your loyalty account on our customer rewards page first.');continue}
  if(cmd==='POINTS'||cmd==='BALANCE'){
   const {data}=await admin.rpc('customer_data_secure',{p_customer_id:customer.id})
   const c=data?.customer;await sendText(from,c?`Hi ${c.name}! You have ${c.available} available points. Earned: ${c.earned}, redeemed: ${c.redeemed}.`: 'Unable to load your points right now.',customer.id);continue
  }
  if(cmd==='DRAW'||cmd==='LUCKY DRAW'){
   const {data:entries}=await admin.from('lucky_draw_entries').select('draw_id,entries').eq('customer_id',customer.id)
   const drawIds=[...new Set((entries||[]).map((x:any)=>x.draw_id))]
   if(!drawIds.length){await sendText(from,'You do not have any lucky draw entries yet.',customer.id);continue}
   const {data:draws}=await admin.from('lucky_draws').select('id,title,status,end_date').in('id',drawIds)
   const counts=new Map<string,number>();for(const e of entries||[])counts.set(e.draw_id,(counts.get(e.draw_id)||0)+Number(e.entries||0))
   const lines=(draws||[]).map((d:any)=>`${d.title}: ${counts.get(d.id)||0} entries (${d.status})`)
   await sendText(from,`Your lucky draw entries:\n${lines.join('\n')}`,customer.id);continue
  }
  if(['HI','HELLO','START','MENU','HELP'].includes(cmd)){
   await sendText(from,`Hi ${customer.name}! PRAKSH COLLECTION Rewards\n\nReply:\nPOINTS - check loyalty balance\nDRAW - check lucky draw entries\nHELP - show this menu`,customer.id);continue
  }
  await sendText(from,'Reply POINTS to check your rewards or DRAW to check lucky draw entries.',customer.id)
 }
}

Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response('ok',{headers:cors})
 if(req.method==='GET'){
  const u=new URL(req.url);const mode=u.searchParams.get('hub.mode');const token=u.searchParams.get('hub.verify_token');const challenge=u.searchParams.get('hub.challenge')||''
  if(mode==='subscribe'&&token&&token===verifyToken)return new Response(challenge,{status:200,headers:{'Content-Type':'text/plain'}})
  return new Response('Forbidden',{status:403})
 }
 if(req.method!=='POST')return json({ok:false,error:'Method not allowed.'},405)
 try{
  const raw=await req.text();const signature=req.headers.get('x-hub-signature-256')||''
  if(signature){
   if(!(await verifySignature(raw,signature)))return new Response('Invalid signature',{status:401})
   const payload=JSON.parse(raw||'{}');await handleIncoming(payload);return json({ok:true})
  }
  const body=JSON.parse(raw||'{}');return await ownerAction(req,body)
 }catch(e){console.error(e);return json({ok:false,error:e instanceof Error?e.message:'Request failed.'},400)}
})
