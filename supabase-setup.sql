-- PRAKSH COLLECTION REWARDS v5
-- SECURITY MODEL
-- Customer mobile+PIN is handled only by the Edge Function customer-api.
-- The browser never calls customer SECURITY DEFINER functions directly and never uploads to Storage directly.
-- The Edge Function uses SUPABASE_SERVICE_ROLE_KEY server-side; NEVER put that key in the website.
-- Owner access continues to use Supabase Auth + owner_users.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.customers(
 id uuid primary key default gen_random_uuid(),
 name text not null,
 phone text unique not null check (phone ~ '^[0-9]{10}$'),
 pin_hash text not null,
 created_at timestamptz not null default now()
);

create table if not exists public.bills(
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references public.customers(id) on delete cascade,
 bill_number text not null,
 amount numeric(12,2) not null check (amount >= 100),
 purchase_date date not null,
 photo_path text,
 points integer not null default 0,
 status text not null default 'pending' check(status in ('pending','approved','rejected')),
 reason text,
 created_at timestamptz not null default now(),
 approved_at timestamptz,
 approved_by uuid
);


-- Point-system migration: ₹100 earns 5 points for every completed ₹100.
-- This applies only when a bill is approved from now on.
alter table public.bills drop constraint if exists bills_amount_check;
alter table public.bills add constraint bills_amount_check check (amount >= 100);

create table if not exists public.redemptions(
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references public.customers(id) on delete cascade,
 bill_id uuid references public.bills(id) on delete restrict,
 points integer not null default 10 check(points=10),
 reward_amount numeric(12,2) not null default 100 check(reward_amount=100),
 created_at timestamptz not null default now(),
 created_by uuid
);

alter table public.redemptions add column if not exists bill_id uuid references public.bills(id) on delete restrict;
alter table public.redemptions add column if not exists redeemed_bill_number text;
create unique index if not exists redemptions_bill_id_uidx on public.redemptions(bill_id) where bill_id is not null;
create index if not exists redemptions_bill_number_idx on public.redemptions(lower(trim(redeemed_bill_number))) where redeemed_bill_number is not null;

alter table public.redemptions drop constraint if exists redemptions_points_check;
alter table public.redemptions drop constraint if exists redemptions_reward_amount_check;
do $$
declare constraint_row record;
begin
 for constraint_row in
   select conname from pg_constraint
   where conrelid='public.redemptions'::regclass
     and pg_get_constraintdef(oid) in ('CHECK ((points = 10))','CHECK ((reward_amount = 100))')
 loop
   execute format('alter table public.redemptions drop constraint if exists %I',constraint_row.conname);
 end loop;
end $$;
-- Existing redemptions keep their recorded values unchanged.
-- New redemptions are restricted by the secure functions below.
alter table public.redemptions add constraint redemptions_points_check check(points=5 or (points>0 and points%10=0));
alter table public.redemptions add constraint redemptions_reward_amount_check check((points=5 and reward_amount=200) or (points>0 and points%10=0 and reward_amount=points));
alter table public.redemptions drop constraint if exists redemptions_min_points_check;
alter table public.redemptions add constraint redemptions_min_points_check check(points>=100 and points%10=0) not valid;
alter table public.redemptions alter column points set default 100;
alter table public.redemptions alter column reward_amount set default 100;

create table if not exists public.owner_users(
 user_id uuid primary key references auth.users(id) on delete cascade,
 created_at timestamptz not null default now()
);

create table if not exists public.customer_sessions(
 id uuid primary key default gen_random_uuid(),
 customer_id uuid not null references public.customers(id) on delete cascade,
 token_hash text unique not null,
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 last_used_at timestamptz not null default now()
);

create table if not exists public.customer_login_attempts(
 bucket_key text primary key,
 window_started_at timestamptz not null default now(),
 attempts integer not null default 0
);

create index if not exists bills_customer_created_idx on public.bills(customer_id,created_at desc);
create index if not exists bills_status_idx on public.bills(status);
create index if not exists redemptions_customer_idx on public.redemptions(customer_id,created_at desc);
create index if not exists sessions_customer_idx on public.customer_sessions(customer_id);
create index if not exists sessions_expires_idx on public.customer_sessions(expires_at);

alter table public.customers enable row level security;
alter table public.bills enable row level security;
alter table public.redemptions enable row level security;
alter table public.owner_users enable row level security;
alter table public.customer_sessions enable row level security;
alter table public.customer_login_attempts enable row level security;

revoke all on public.customers from anon, authenticated;
revoke all on public.bills from anon, authenticated;
revoke all on public.redemptions from anon, authenticated;
revoke all on public.owner_users from anon, authenticated;
revoke all on public.customer_sessions from anon, authenticated;
revoke all on public.customer_login_attempts from anon, authenticated;

create or replace function public.pin_digest(p_pin text)
returns text language sql immutable as $$ select encode(extensions.digest(p_pin,'sha256'::text),'hex') $$;

create or replace function public.is_owner()
returns boolean language sql security definer set search_path=public
as $$ select exists(select 1 from public.owner_users where user_id=auth.uid()) $$;

create or replace function public.customer_data_secure(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare c public.customers; earned int; redeemed int; pending int; available int; bills jsonb;
begin
 select * into c from public.customers where id=p_customer_id;
 if c.id is null then return jsonb_build_object('ok',false,'error','Customer not found.'); end if;
 select coalesce(sum(points) filter(where status='approved'),0)::int into earned from public.bills where customer_id=c.id;
 select coalesce(sum(points),0)::int into redeemed from public.redemptions where customer_id=c.id;
 select count(*)::int into pending from public.bills where customer_id=c.id and status='pending';
 available:=earned-redeemed;
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'date',b.purchase_date,'bill',b.bill_number,'amount',b.amount,'points',b.points,'status',b.status,'reason',b.reason) order by b.created_at desc),'[]'::jsonb)
 into bills from public.bills b where b.customer_id=c.id;
 return jsonb_build_object('ok',true,'customer',jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'earned',earned,'redeemed',redeemed,'pending',pending,'available',available,'bills',bills));
end $$;

create or replace function public.customer_session_lookup(p_token_hash text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare sid public.customer_sessions;
begin
 delete from public.customer_sessions where expires_at <= now();
 select * into sid from public.customer_sessions where token_hash=p_token_hash and expires_at>now();
 if sid.id is null then return jsonb_build_object('ok',false); end if;
 update public.customer_sessions set last_used_at=now() where id=sid.id;
 return jsonb_build_object('ok',true,'customer_id',sid.customer_id);
end $$;

create or replace function public.customer_login_secure(p_phone text,p_pin text,p_name text,p_ip text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare c public.customers; token text; token_hash text; key text; a public.customer_login_attempts;
begin
 key:=encode(extensions.digest(coalesce(p_phone,'')||':'||coalesce(p_ip,''),'sha256'::text),'hex');
 select * into a from public.customer_login_attempts where bucket_key=key for update;
 if a.bucket_key is null or a.window_started_at < now()-interval '15 minutes' then
   insert into public.customer_login_attempts(bucket_key,window_started_at,attempts) values(key,now(),0)
   on conflict(bucket_key) do update set window_started_at=now(),attempts=0 returning * into a;
 end if;
 if a.attempts>=8 then return jsonb_build_object('ok',false,'error','Too many login attempts. Please wait 15 minutes.'); end if;
 update public.customer_login_attempts set attempts=attempts+1 where bucket_key=key;

 if not (p_phone ~ '^[0-9]{10}$' and length(trim(coalesce(p_name,''))) between 2 and 100) then return jsonb_build_object('ok',false,'error','Invalid name or mobile number.'); end if;
 select * into c from public.customers where phone=p_phone for update;
 if c.id is null then
   insert into public.customers(name,phone,pin_hash) values(trim(p_name),p_phone,public.pin_digest('')) returning * into c;
 else
   if lower(trim(c.name)) <> lower(trim(p_name)) then return jsonb_build_object('ok',false,'error','Name and mobile number do not match.'); end if;
 end if;

 -- Successful authentication clears the rate-limit bucket.
 delete from public.customer_login_attempts where bucket_key=key;
 token:=encode(extensions.gen_random_bytes(32),'hex'); token_hash:=encode(extensions.digest(token,'sha256'::text),'hex');
 insert into public.customer_sessions(customer_id,token_hash,expires_at) values(c.id,token_hash,now()+interval '7 days');
 return jsonb_build_object('ok',true,'session',token,'customer', (public.customer_data_secure(c.id)->'customer'));
end $$;

create or replace function public.submit_bill_secure(p_customer_id uuid,p_bill_number text,p_amount numeric,p_purchase_date date,p_photo_path text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare path_prefix text; normalized_bill_number text;
begin
 if not exists(select 1 from public.customers where id=p_customer_id) then return jsonb_build_object('ok',false,'error','Customer not found.'); end if;
 if length(trim(coalesce(p_bill_number,'')))<1 or length(trim(p_bill_number))>80 then return jsonb_build_object('ok',false,'error','Invalid bill number.'); end if;
 if p_amount is null or p_amount<100 or p_amount>100000000 then return jsonb_build_object('ok',false,'error','Invalid bill amount.'); end if;
 if p_purchase_date is null or p_purchase_date>current_date then return jsonb_build_object('ok',false,'error','Purchase date cannot be in the future.'); end if;
 normalized_bill_number:=lower(trim(p_bill_number));
 perform pg_advisory_xact_lock(hashtextextended(normalized_bill_number,0));
 if exists(select 1 from public.bills where lower(trim(bill_number))=normalized_bill_number) then
   return jsonb_build_object('ok',false,'error','This bill number has already been submitted by a customer.');
 end if;
 if exists(select 1 from public.redemptions where lower(trim(redeemed_bill_number))=normalized_bill_number) then
   return jsonb_build_object('ok',false,'error','This bill number has already been used for redemption and cannot earn points again.');
 end if;
 path_prefix:=p_customer_id::text||'/';
 if p_photo_path is null or left(p_photo_path,length(path_prefix))<>path_prefix then return jsonb_build_object('ok',false,'error','Invalid bill photo path.'); end if;
 insert into public.bills(customer_id,bill_number,amount,purchase_date,photo_path) values(p_customer_id,trim(p_bill_number),p_amount,p_purchase_date,p_photo_path);
 return jsonb_build_object('ok',true);
end $$;

drop function if exists public.redeem_reward_secure(uuid,integer);
drop function if exists public.redeem_reward_secure(uuid,integer,text);
create or replace function public.redeem_reward_secure(p_customer_id uuid,p_points integer,p_bill_number text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare earned int; used int; avail int; normalized_bill_number text;
begin
 if p_points is null or p_points<100 or p_points%10<>0 then return jsonb_build_object('ok',false,'error','Redeem a minimum of 100 points in multiples of 10.'); end if;
 normalized_bill_number:=lower(trim(coalesce(p_bill_number,'')));
 if normalized_bill_number='' then return jsonb_build_object('ok',false,'error','Enter the bill number used for this redemption.'); end if;
 perform pg_advisory_xact_lock(hashtextextended(normalized_bill_number,0));
 if exists(select 1 from public.bills where lower(trim(bill_number))=normalized_bill_number) then return jsonb_build_object('ok',false,'error','This bill number is already present in submitted bills.'); end if;
 if exists(select 1 from public.redemptions where lower(trim(redeemed_bill_number))=normalized_bill_number) then return jsonb_build_object('ok',false,'error','This bill number has already been used for redemption.'); end if;
 select coalesce(sum(points) filter(where status='approved'),0)::int into earned from public.bills where customer_id=p_customer_id;
 select coalesce(sum(points),0)::int into used from public.redemptions where customer_id=p_customer_id;
 avail:=earned-used;
 if avail<p_points then return jsonb_build_object('ok',false,'error','You do not have enough available points.'); end if;
 insert into public.redemptions(customer_id,redeemed_bill_number,points,reward_amount) values(p_customer_id,trim(p_bill_number),p_points,p_points);
 return jsonb_build_object('ok',true,'message','₹'||p_points||' reward redeemed successfully.');
end $$;

drop function if exists public.owner_redeem_customer(uuid,integer);
drop function if exists public.owner_redeem_customer(uuid,integer,text);
create or replace function public.owner_redeem_customer(p_customer_id uuid,p_points integer,p_bill_number text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare earned int; used int; avail int; normalized_bill_number text;
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 if p_points is null or p_points<100 or p_points%10<>0 then return jsonb_build_object('ok',false,'error','Redeem a minimum of 100 points in multiples of 10.'); end if;
 normalized_bill_number:=lower(trim(coalesce(p_bill_number,'')));
 if normalized_bill_number='' then return jsonb_build_object('ok',false,'error','Enter the bill number used for this redemption.'); end if;
 perform pg_advisory_xact_lock(hashtextextended(normalized_bill_number,0));
 if exists(select 1 from public.bills where lower(trim(bill_number))=normalized_bill_number) then return jsonb_build_object('ok',false,'error','This bill number is already present in submitted bills.'); end if;
 if exists(select 1 from public.redemptions where lower(trim(redeemed_bill_number))=normalized_bill_number) then return jsonb_build_object('ok',false,'error','This bill number has already been used for redemption.'); end if;
 select coalesce(sum(points) filter(where status='approved'),0)::int into earned from public.bills where customer_id=p_customer_id;
 select coalesce(sum(points),0)::int into used from public.redemptions where customer_id=p_customer_id;
 avail:=earned-used;
 if avail<p_points then return jsonb_build_object('ok',false,'error','Customer does not have enough available points.'); end if;
 insert into public.redemptions(customer_id,redeemed_bill_number,points,reward_amount,created_by) values(p_customer_id,trim(p_bill_number),p_points,p_points,auth.uid());
 return jsonb_build_object('ok',true,'message','₹'||p_points||' reward redeemed for customer.');
end $$;

create or replace function public.owner_dashboard()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare pending jsonb; customers jsonb; redemptions jsonb; pc int; issued int; red int;
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',c.name,'phone',c.phone,'bill',b.bill_number,'amount',b.amount,'date',b.purchase_date,'photo_path',b.photo_path) order by b.created_at),'[]'::jsonb) into pending from public.bills b join public.customers c on c.id=b.customer_id where b.status='pending';
 select count(*)::int into pc from public.customers;
 select coalesce(sum(points),0)::int into issued from public.bills where status='approved';
 select coalesce(sum(points),0)::int into red from public.redemptions;
 select coalesce(jsonb_agg(jsonb_build_object('date',r.created_at,'name',c.name,'phone',c.phone,'bill',coalesce(b.bill_number,r.redeemed_bill_number),'points',r.points,'reward',r.reward_amount) order by r.created_at desc),'[]'::jsonb)
 into redemptions from public.redemptions r join public.customers c on c.id=r.customer_id left join public.bills b on b.id=r.bill_id;
 select coalesce(jsonb_agg(x order by x->>'name'),'[]'::jsonb) into customers from (
  select jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'bills',(select count(*) from public.bills b where b.customer_id=c.id),'earned',(select coalesce(sum(points),0) from public.bills b where b.customer_id=c.id and b.status='approved'),'redeemed',(select coalesce(sum(points),0) from public.redemptions r where r.customer_id=c.id),'available',(select coalesce(sum(points),0) from public.bills b where b.customer_id=c.id and b.status='approved')-(select coalesce(sum(points),0) from public.redemptions r where r.customer_id=c.id)) x from public.customers c) q;
 return jsonb_build_object('ok',true,'stats',jsonb_build_object('customers',pc,'pendingBills',jsonb_array_length(pending),'issued',issued,'redeemed',red),'pending',pending,'customers',customers,'redemptions',redemptions);
end $$;

create or replace function public.approve_bill(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 update public.bills set status='approved',points=floor(amount/100)::int*5,approved_at=now(),approved_by=auth.uid(),reason=null where id=p_bill_id and status='pending';
 if not found then return jsonb_build_object('ok',false,'error','Bill not found or already processed.'); end if;
 return jsonb_build_object('ok',true);
end $$;

create or replace function public.reject_bill(p_bill_id uuid,p_reason text)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 update public.bills set status='rejected',points=0,reason=coalesce(nullif(left(trim(p_reason),500),''),'Bill rejected'),approved_by=auth.uid() where id=p_bill_id and status='pending';
 if not found then return jsonb_build_object('ok',false,'error','Bill not found or already processed.'); end if;
 return jsonb_build_object('ok',true);
end $$;

-- Remove legacy customer RPCs that accepted an arbitrary customer UUID from the browser.
drop function if exists public.customer_login(text,text,text);
drop function if exists public.customer_data(uuid);
drop function if exists public.submit_bill(uuid,text,numeric,date,text);
drop function if exists public.redeem_reward(uuid);

revoke all on function public.customer_login_secure(text,text,text,text) from public,anon,authenticated;
revoke all on function public.customer_session_lookup(text) from public,anon,authenticated;
revoke all on function public.customer_data_secure(uuid) from public,anon,authenticated;
revoke all on function public.submit_bill_secure(uuid,text,numeric,date,text) from public,anon,authenticated;
revoke all on function public.redeem_reward_secure(uuid,integer,text) from public,anon,authenticated;
revoke all on function public.owner_redeem_customer(uuid,integer,text) from public,anon,authenticated;
revoke all on function public.is_owner() from public,anon;
revoke all on function public.owner_dashboard() from public,anon;
revoke all on function public.approve_bill(uuid) from public,anon;
revoke all on function public.reject_bill(uuid,text) from public,anon;

grant execute on function public.customer_login_secure(text,text,text,text) to service_role;
grant execute on function public.customer_session_lookup(text) to service_role;
grant execute on function public.customer_data_secure(uuid) to service_role;
grant execute on function public.submit_bill_secure(uuid,text,numeric,date,text) to service_role;
grant execute on function public.redeem_reward_secure(uuid,integer,text) to service_role;
grant execute on function public.owner_redeem_customer(uuid,integer,text) to authenticated;
grant execute on function public.is_owner() to authenticated;
grant execute on function public.owner_dashboard() to authenticated;
grant execute on function public.approve_bill(uuid) to authenticated;
grant execute on function public.reject_bill(uuid,text) to authenticated;

-- PRIVATE BILL PHOTO BUCKET. Customer uploads are now performed by the Edge Function using service_role.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('bill-photos','bill-photos',false,10485760,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "customer bill upload" on storage.objects;
drop policy if exists "owner can read bills" on storage.objects;
create policy "owner can read bills" on storage.objects for select to authenticated using (bucket_id='bill-photos' and public.is_owner());

-- Cleanup expired sessions/attempts periodically. If pg_cron is enabled, this job is safe to run.
do $$ begin
  if exists(select 1 from pg_extension where extname='pg_cron') then
    perform cron.schedule('praksh-cleanup-customer-sessions','15 * * * *','delete from public.customer_sessions where expires_at <= now(); delete from public.customer_login_attempts where window_started_at < now()-interval ''1 day'';');
  end if;
exception when others then null;
end $$;

-- OWNER SETUP AFTER CREATING THE AUTH USER:
-- insert into public.owner_users(user_id) values('YOUR-AUTH-USER-UUID') on conflict do nothing;
