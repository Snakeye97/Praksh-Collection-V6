-- PRAKSH COLLECTION REWARDS V6 UPGRADE
-- Run AFTER the existing supabase-setup.sql.
-- Adds customer profile fields, lucky draws, promotions, WhatsApp logs,
-- and upgrades the owner/customer dashboard RPCs.

begin;

alter table public.customers add column if not exists birthday date;
alter table public.customers add column if not exists anniversary date;
alter table public.customers add column if not exists gender text check (gender is null or gender in ('male','female','other','prefer_not_to_say'));
alter table public.customers add column if not exists marketing_consent boolean not null default false;
alter table public.customers add column if not exists notes text;

create table if not exists public.lucky_draws(
 id uuid primary key default gen_random_uuid(),
 title text not null,
 prize text not null,
 min_purchase numeric(12,2) not null check(min_purchase > 0),
 start_date date not null,
 end_date date not null,
 status text not null default 'active' check(status in ('active','closed')),
 created_at timestamptz not null default now(),
 created_by uuid,
 check(end_date >= start_date)
);

create table if not exists public.lucky_draw_entries(
 id uuid primary key default gen_random_uuid(),
 draw_id uuid not null references public.lucky_draws(id) on delete cascade,
 customer_id uuid not null references public.customers(id) on delete cascade,
 bill_id uuid not null references public.bills(id) on delete cascade,
 entries integer not null check(entries > 0),
 created_at timestamptz not null default now(),
 unique(draw_id,bill_id)
);

create table if not exists public.lucky_draw_winners(
 id uuid primary key default gen_random_uuid(),
 draw_id uuid not null unique references public.lucky_draws(id) on delete cascade,
 customer_id uuid not null references public.customers(id) on delete cascade,
 bill_id uuid references public.bills(id) on delete set null,
 entries integer not null,
 picked_at timestamptz not null default now(),
 picked_by uuid
);

create table if not exists public.promotions(
 id uuid primary key default gen_random_uuid(),
 name text not null,
 audience text not null default 'all' check(audience in ('all','points','vip')),
 template_name text not null,
 language_code text not null default 'en',
 message_preview text,
 status text not null default 'draft' check(status in ('draft','sending','sent','partial','failed')),
 sent_count integer not null default 0,
 failed_count integer not null default 0,
 created_at timestamptz not null default now(),
 sent_at timestamptz,
 created_by uuid
);

create table if not exists public.whatsapp_messages(
 id uuid primary key default gen_random_uuid(),
 customer_id uuid references public.customers(id) on delete set null,
 direction text not null check(direction in ('inbound','outbound')),
 phone text not null,
 message_type text not null default 'text',
 body text,
 meta_message_id text,
 status text,
 created_at timestamptz not null default now()
);

create index if not exists lucky_draw_entries_draw_idx on public.lucky_draw_entries(draw_id);
create index if not exists lucky_draw_entries_customer_idx on public.lucky_draw_entries(customer_id);
create index if not exists promotions_created_idx on public.promotions(created_at desc);
create index if not exists whatsapp_messages_phone_idx on public.whatsapp_messages(phone,created_at desc);

alter table public.lucky_draws enable row level security;
alter table public.lucky_draw_entries enable row level security;
alter table public.lucky_draw_winners enable row level security;
alter table public.promotions enable row level security;
alter table public.whatsapp_messages enable row level security;

revoke all on public.lucky_draws from anon, authenticated;
revoke all on public.lucky_draw_entries from anon, authenticated;
revoke all on public.lucky_draw_winners from anon, authenticated;
revoke all on public.promotions from anon, authenticated;
revoke all on public.whatsapp_messages from anon, authenticated;

create or replace function public.customer_profile_update_secure(
 p_customer_id uuid,
 p_birthday date,
 p_anniversary date,
 p_gender text,
 p_marketing_consent boolean
)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.customers where id=p_customer_id) then
   return jsonb_build_object('ok',false,'error','Customer not found.');
 end if;
 if p_gender is not null and p_gender not in ('male','female','other','prefer_not_to_say') then
   return jsonb_build_object('ok',false,'error','Invalid gender selection.');
 end if;
 update public.customers
 set birthday=p_birthday,
     anniversary=p_anniversary,
     gender=p_gender,
     marketing_consent=coalesce(p_marketing_consent,false)
 where id=p_customer_id;
 return jsonb_build_object('ok',true,'message','Profile updated.');
end $$;

create or replace function public.customer_data_secure(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare c public.customers; earned int; redeemed int; pending int; available int; bills jsonb; draws jsonb;
begin
 select * into c from public.customers where id=p_customer_id;
 if c.id is null then return jsonb_build_object('ok',false,'error','Customer not found.'); end if;
 select coalesce(sum(points) filter(where status='approved'),0)::int into earned from public.bills where customer_id=c.id;
 select coalesce(sum(points),0)::int into redeemed from public.redemptions where customer_id=c.id;
 select count(*)::int into pending from public.bills where customer_id=c.id and status='pending';
 available:=earned-redeemed;
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'date',b.purchase_date,'bill',b.bill_number,'amount',b.amount,'points',b.points,'status',b.status,'reason',b.reason) order by b.created_at desc),'[]'::jsonb)
 into bills from public.bills b where b.customer_id=c.id;
 select coalesce(jsonb_agg(jsonb_build_object(
   'id',d.id,
   'title',d.title,
   'prize',d.prize,
   'min_purchase',d.min_purchase,
   'start_date',d.start_date,
   'end_date',d.end_date,
   'status',d.status,
   'entries',coalesce((select sum(e.entries)::int from public.lucky_draw_entries e where e.draw_id=d.id and e.customer_id=c.id),0),
   'winner',exists(select 1 from public.lucky_draw_winners w where w.draw_id=d.id and w.customer_id=c.id)
 ) order by d.created_at desc),'[]'::jsonb)
 into draws
 from public.lucky_draws d
 where d.status='active' or exists(select 1 from public.lucky_draw_entries e where e.draw_id=d.id and e.customer_id=c.id);
 return jsonb_build_object('ok',true,'customer',jsonb_build_object(
   'id',c.id,'name',c.name,'phone',c.phone,
   'birthday',c.birthday,'anniversary',c.anniversary,'gender',c.gender,'marketing_consent',c.marketing_consent,
   'earned',earned,'redeemed',redeemed,'pending',pending,'available',available,'bills',bills,'draws',draws
 ));
end $$;

create or replace function public.owner_create_draw(
 p_title text,
 p_prize text,
 p_min_purchase numeric,
 p_start_date date,
 p_end_date date
)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare d_id uuid;
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 if length(trim(coalesce(p_title,'')))<2 then return jsonb_build_object('ok',false,'error','Enter a draw title.'); end if;
 if length(trim(coalesce(p_prize,'')))<2 then return jsonb_build_object('ok',false,'error','Enter a prize.'); end if;
 if p_min_purchase is null or p_min_purchase<=0 then return jsonb_build_object('ok',false,'error','Minimum purchase must be above zero.'); end if;
 if p_start_date is null or p_end_date is null or p_end_date<p_start_date then return jsonb_build_object('ok',false,'error','Invalid draw dates.'); end if;
 insert into public.lucky_draws(title,prize,min_purchase,start_date,end_date,created_by)
 values(trim(p_title),trim(p_prize),p_min_purchase,p_start_date,p_end_date,auth.uid()) returning id into d_id;
 insert into public.lucky_draw_entries(draw_id,customer_id,bill_id,entries)
 select d_id,b.customer_id,b.id,greatest(1,floor(b.amount/p_min_purchase)::int)
 from public.bills b
 where b.status='approved' and b.amount>=p_min_purchase and b.purchase_date between p_start_date and p_end_date
 on conflict(draw_id,bill_id) do nothing;
 return jsonb_build_object('ok',true,'draw_id',d_id,'message','Lucky draw created.');
end $$;

create or replace function public.owner_close_draw(p_draw_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 update public.lucky_draws set status='closed' where id=p_draw_id;
 if not found then return jsonb_build_object('ok',false,'error','Draw not found.'); end if;
 return jsonb_build_object('ok',true,'message','Draw closed.');
end $$;

create or replace function public.owner_pick_draw_winner(p_draw_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare total_entries int; target int; picked record; d public.lucky_draws;
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 select * into d from public.lucky_draws where id=p_draw_id for update;
 if d.id is null then return jsonb_build_object('ok',false,'error','Draw not found.'); end if;
 if exists(select 1 from public.lucky_draw_winners where draw_id=p_draw_id) then return jsonb_build_object('ok',false,'error','A winner has already been selected.'); end if;
 select coalesce(sum(entries),0)::int into total_entries from public.lucky_draw_entries where draw_id=p_draw_id;
 if total_entries<=0 then return jsonb_build_object('ok',false,'error','This draw has no entries.'); end if;
 target:=floor(random()*total_entries)::int+1;
 select q.customer_id,q.bill_id,q.entries into picked
 from (
   select e.*,sum(e.entries) over(order by e.created_at,e.id) running_total
   from public.lucky_draw_entries e where e.draw_id=p_draw_id
 ) q
 where q.running_total>=target
 order by q.running_total
 limit 1;
 insert into public.lucky_draw_winners(draw_id,customer_id,bill_id,entries,picked_by)
 values(p_draw_id,picked.customer_id,picked.bill_id,picked.entries,auth.uid());
 update public.lucky_draws set status='closed' where id=p_draw_id;
 return jsonb_build_object('ok',true,'message','Winner selected.','customer_id',picked.customer_id);
end $$;

create or replace function public.owner_create_promotion(
 p_name text,
 p_audience text,
 p_template_name text,
 p_language_code text,
 p_message_preview text
)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare p_id uuid;
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 if length(trim(coalesce(p_name,'')))<2 then return jsonb_build_object('ok',false,'error','Enter a promotion name.'); end if;
 if p_audience not in ('all','points','vip') then return jsonb_build_object('ok',false,'error','Invalid audience.'); end if;
 if length(trim(coalesce(p_template_name,'')))<1 then return jsonb_build_object('ok',false,'error','Enter the approved WhatsApp template name.'); end if;
 insert into public.promotions(name,audience,template_name,language_code,message_preview,created_by)
 values(trim(p_name),p_audience,trim(p_template_name),coalesce(nullif(trim(p_language_code),''),'en'),left(p_message_preview,1000),auth.uid())
 returning id into p_id;
 return jsonb_build_object('ok',true,'promotion_id',p_id,'message','Promotion saved.');
end $$;

create or replace function public.owner_dashboard()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare pending jsonb; customers jsonb; redemptions jsonb; draws jsonb; winners jsonb; promotions jsonb; pc int; issued int; red int;
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',c.name,'phone',c.phone,'bill',b.bill_number,'amount',b.amount,'date',b.purchase_date,'photo_path',b.photo_path) order by b.created_at),'[]'::jsonb) into pending from public.bills b join public.customers c on c.id=b.customer_id where b.status='pending';
 select count(*)::int into pc from public.customers;
 select coalesce(sum(points),0)::int into issued from public.bills where status='approved';
 select coalesce(sum(points),0)::int into red from public.redemptions;
 select coalesce(jsonb_agg(jsonb_build_object('date',r.created_at,'name',c.name,'phone',c.phone,'bill',coalesce(b.bill_number,r.redeemed_bill_number),'points',r.points,'reward',r.reward_amount) order by r.created_at desc),'[]'::jsonb)
 into redemptions from public.redemptions r join public.customers c on c.id=r.customer_id left join public.bills b on b.id=r.bill_id;
 select coalesce(jsonb_agg(x order by x->>'name'),'[]'::jsonb) into customers from (
  select jsonb_build_object(
   'id',c.id,'name',c.name,'phone',c.phone,'birthday',c.birthday,'anniversary',c.anniversary,'gender',c.gender,'marketing_consent',c.marketing_consent,
   'bills',(select count(*) from public.bills b where b.customer_id=c.id),
   'earned',(select coalesce(sum(points),0) from public.bills b where b.customer_id=c.id and b.status='approved'),
   'redeemed',(select coalesce(sum(points),0) from public.redemptions r where r.customer_id=c.id),
   'available',(select coalesce(sum(points),0) from public.bills b where b.customer_id=c.id and b.status='approved')-(select coalesce(sum(points),0) from public.redemptions r where r.customer_id=c.id)
  ) x from public.customers c) q;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',d.id,'title',d.title,'prize',d.prize,'min_purchase',d.min_purchase,'start_date',d.start_date,'end_date',d.end_date,'status',d.status,
  'entries',coalesce((select sum(e.entries)::int from public.lucky_draw_entries e where e.draw_id=d.id),0),
  'customers',coalesce((select count(distinct e.customer_id)::int from public.lucky_draw_entries e where e.draw_id=d.id),0)
 ) order by d.created_at desc),'[]'::jsonb) into draws from public.lucky_draws d;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',w.id,'draw_id',w.draw_id,'draw',d.title,'prize',d.prize,'name',c.name,'phone',c.phone,'bill',b.bill_number,'picked_at',w.picked_at
 ) order by w.picked_at desc),'[]'::jsonb)
 into winners from public.lucky_draw_winners w join public.lucky_draws d on d.id=w.draw_id join public.customers c on c.id=w.customer_id left join public.bills b on b.id=w.bill_id;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',p.id,'name',p.name,'audience',p.audience,'template_name',p.template_name,'language_code',p.language_code,'message_preview',p.message_preview,
  'status',p.status,'sent_count',p.sent_count,'failed_count',p.failed_count,'created_at',p.created_at,'sent_at',p.sent_at
 ) order by p.created_at desc),'[]'::jsonb) into promotions from public.promotions p;
 return jsonb_build_object('ok',true,
  'stats',jsonb_build_object('customers',pc,'pendingBills',jsonb_array_length(pending),'issued',issued,'redeemed',red),
  'pending',pending,'customers',customers,'redemptions',redemptions,'draws',draws,'winners',winners,'promotions',promotions);
end $$;

create or replace function public.approve_bill(p_bill_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare b public.bills;
begin
 if not public.is_owner() then return jsonb_build_object('ok',false,'error','Owner access required.'); end if;
 update public.bills set status='approved',points=floor(amount/100)::int*5,approved_at=now(),approved_by=auth.uid(),reason=null
 where id=p_bill_id and status='pending' returning * into b;
 if b.id is null then return jsonb_build_object('ok',false,'error','Bill not found or already processed.'); end if;
 insert into public.lucky_draw_entries(draw_id,customer_id,bill_id,entries)
 select d.id,b.customer_id,b.id,greatest(1,floor(b.amount/d.min_purchase)::int)
 from public.lucky_draws d
 where d.status='active' and b.amount>=d.min_purchase and b.purchase_date between d.start_date and d.end_date
 on conflict(draw_id,bill_id) do nothing;
 return jsonb_build_object('ok',true);
end $$;

revoke all on function public.customer_profile_update_secure(uuid,date,date,text,boolean) from public,anon,authenticated;
revoke all on function public.owner_create_draw(text,text,numeric,date,date) from public,anon;
revoke all on function public.owner_close_draw(uuid) from public,anon;
revoke all on function public.owner_pick_draw_winner(uuid) from public,anon;
revoke all on function public.owner_create_promotion(text,text,text,text,text) from public,anon;

grant execute on function public.customer_profile_update_secure(uuid,date,date,text,boolean) to service_role;
grant execute on function public.owner_create_draw(text,text,numeric,date,date) to authenticated;
grant execute on function public.owner_close_draw(uuid) to authenticated;
grant execute on function public.owner_pick_draw_winner(uuid) to authenticated;
grant execute on function public.owner_create_promotion(text,text,text,text,text) to authenticated;

commit;
