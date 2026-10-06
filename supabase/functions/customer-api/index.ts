import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.116.0'

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)

function tokenFrom(req: Request) { const h=req.headers.get('authorization')||''; return h.startsWith('Bearer ')?h.slice(7):'' }
async function sha256(value:string){const b=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(value));return Array.from(new Uint8Array(b)).map(x=>x.toString(16).padStart(2,'0')).join('')}

async function authenticate(req: Request){
 const token=tokenFrom(req); if(!token) throw new Error('Customer session required.')
 const hash=await sha256(token)
 const {data,error}=await admin.rpc('customer_session_lookup',{p_token_hash:hash})
 if(error||!data?.ok) throw new Error('Customer session expired. Please log in again.')
 return data.customer_id as string
}

Deno.serve(async req=>{
 if(req.method==='OPTIONS') return new Response('ok',{headers:cors})
 if(req.method!=='POST') return json({ok:false,error:'Method not allowed.'},405)
 try{
  const ct=req.headers.get('content-type')||''
  let action:string, body:any={}
  if(ct.includes('multipart/form-data')){const form=await req.formData();action=String(form.get('action')||'');body={bill_number:String(form.get('bill_number')||''),amount:Number(form.get('amount')),purchase_date:String(form.get('purchase_date')||''),photo:form.get('photo')}}
  else {body=await req.json();action=String(body.action||'')}

  if(action==='login'){
  const phone=String(body.phone||'').replace(/\D/g,''); const name=String(body.name||'').trim()
  if(!/^\d{10}$/.test(phone)||name.length<2) return json({ok:false,error:'Invalid name or mobile number.'},400)
   if(name.length>100) return json({ok:false,error:'Name is too long.'},400)
  const clientIp=(req.headers.get('x-forwarded-for')||req.headers.get('cf-connecting-ip')||'unknown').split(',')[0].trim(); const {data,error}=await admin.rpc('customer_login_secure',{p_phone:phone,p_pin:'',p_name:name,p_ip:clientIp})
    if(error){console.error('customer_login_secure failed',error);return json({ok:false,error:'Login service unavailable.'},500)}
   if(!data?.ok) return json(data,401)
   return json(data)
  }

  const customerId=await authenticate(req)
  if(action==='data'){
   const {data,error}=await admin.rpc('customer_data_secure',{p_customer_id:customerId}); if(error) throw error; return json(data)
  }
  if(action==='redeem'){
    const points=Number(body.points); if(!Number.isInteger(points)||points<100||points%10!==0) return json({ok:false,error:'Redeem a minimum of 100 points in multiples of 10.'},400)
    const billNumber=String(body.bill_number||'').trim(); if(!billNumber) return json({ok:false,error:'Enter the redemption bill number.'},400)
    const {data,error}=await admin.rpc('redeem_reward_secure',{p_customer_id:customerId,p_points:points,p_bill_number:billNumber}); if(error) throw error; return json(data)
  }
  if(action==='profile'){
    const birthday=body.birthday?String(body.birthday):null
    const anniversary=body.anniversary?String(body.anniversary):null
    const gender=body.gender?String(body.gender):null
    const marketingConsent=body.marketing_consent===true
    for(const d of [birthday,anniversary]) if(d&&!/^\d{4}-\d{2}-\d{2}$/.test(d)) return json({ok:false,error:'Invalid profile date.'},400)
    const {data,error}=await admin.rpc('customer_profile_update_secure',{p_customer_id:customerId,p_birthday:birthday,p_anniversary:anniversary,p_gender:gender,p_marketing_consent:marketingConsent}); if(error) throw error; return json(data)
  }
  if(action==='submit_bill'){
   const bill=body.bill_number.trim(); const amount=Number(body.amount); const date=body.purchase_date; const file=body.photo as File
   if(!bill||bill.length>80||!Number.isFinite(amount)||amount<100||amount>100000000) return json({ok:false,error:'Invalid bill details.'},400)
   if(!/^\d{4}-\d{2}-\d{2}$/.test(date)) return json({ok:false,error:'Invalid purchase date.'},400)
   // PostgreSQL performs the authoritative current-date validation in submit_bill_secure.
   // Avoid a UTC/browser-server timezone mismatch here.
   if(!(file instanceof File)||file.size===0||file.size>10*1024*1024||!['image/jpeg','image/png','image/webp'].includes(file.type)) return json({ok:false,error:'Use a JPG, PNG or WebP image under 10 MB.'},400)
   const ext=file.type==='image/png'?'png':file.type==='image/webp'?'webp':'jpg'; const path=`${customerId}/${crypto.randomUUID()}.${ext}`
   const upload=await admin.storage.from('bill-photos').upload(path,file,{contentType:file.type,upsert:false}); if(upload.error) throw upload.error
   const {data,error}=await admin.rpc('submit_bill_secure',{p_customer_id:customerId,p_bill_number:bill,p_amount:amount,p_purchase_date:date,p_photo_path:path})
   if(error||!data?.ok){await admin.storage.from('bill-photos').remove([path]);if(error)throw error;return json(data,400)}
   return json(data)
  }
  return json({ok:false,error:'Unknown action.'},400)
 }catch(e){console.error(e);const errorObject=e&&typeof e==='object'?e as Record<string,unknown>:{};const code=String(errorObject.code||'');const message=code==='23514'?'Redemption settings are outdated. Run the latest supabase-setup.sql first.':e instanceof Error?e.message:String(errorObject.message||errorObject.details||errorObject.hint||errorObject.code||'Request failed.');return json({ok:false,error:message},400)}
})
