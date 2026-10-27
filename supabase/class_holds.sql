-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Lets an admin reserve a bike for a specific person in chosen classes ("por clase").
-- Returns: ok | not_found | past | blocked | has_booking | taken | bad_bike
create or replace function public.spin_reserve_for(p_class uuid, p_bike int, p_email text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare uid uuid; cls public.spin_classes;
begin
  if not public.spin_is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select id into uid from auth.users
   where lower(email) = lower(trim(p_email)) and email_confirmed_at is not null limit 1;
  if uid is null then return 'not_found'; end if;
  select * into cls from public.spin_classes where id = p_class;
  if not found or cls.starts_at <= now() then return 'past'; end if;
  if p_bike < 1 or p_bike > cls.capacity then return 'bad_bike'; end if;
  if public.spin_bike_blocked(p_class, p_bike) then return 'blocked'; end if;
  if exists (select 1 from public.spin_reservations where class_id = p_class and user_id = uid) then return 'has_booking'; end if;
  if exists (select 1 from public.spin_reservations where class_id = p_class and bike = p_bike) then return 'taken'; end if;
  insert into public.spin_reservations(class_id, bike, user_id) values (p_class, p_bike, uid);
  return 'ok';
end $$;
revoke all on function public.spin_reserve_for(uuid, int, text) from public, anon;
grant execute on function public.spin_reserve_for(uuid, int, text) to authenticated;
