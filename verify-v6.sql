-- Read-only V6 installation check. Safe to run in Supabase SQL Editor.
select
 to_regclass('public.lucky_draws') as lucky_draws,
 to_regclass('public.lucky_draw_entries') as lucky_draw_entries,
 to_regclass('public.lucky_draw_winners') as lucky_draw_winners,
 to_regclass('public.promotions') as promotions,
 to_regclass('public.whatsapp_messages') as whatsapp_messages,
 to_regprocedure('public.owner_create_draw(text,text,numeric,date,date)') as owner_create_draw,
 to_regprocedure('public.owner_pick_draw_winner(uuid)') as owner_pick_draw_winner,
 to_regprocedure('public.owner_create_promotion(text,text,text,text,text)') as owner_create_promotion,
 to_regprocedure('public.customer_profile_update_secure(uuid,date,date,text,boolean)') as customer_profile_update;
