-- ONE-TIME RESET: remove customer activity while keeping customer and owner accounts.
-- V6 also clears draw entries/winners and WhatsApp message logs.
-- Run manually in the Supabase SQL Editor only when you intentionally want a reset.

begin;

delete from public.whatsapp_messages;
delete from public.lucky_draw_winners;
delete from public.lucky_draw_entries;
delete from public.redemptions;
delete from public.bills;

commit;
