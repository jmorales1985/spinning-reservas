-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Adds: roster with names/emails for admins, list/add/remove admins. All restricted to admins.

create or replace function public.spin_roster()
returns table(class_id uuid, bike int, user_id uuid, display_name text, email text)
language sql stable security definer set search_path = public, auth as $$
  select r.class_id, r.bike, r.user_id, p.display_name, u.email::text
  from public.spin_reservations r
  join public.spin_classes c on c.id = r.class_id
  left join public.spin_profiles p on p.user_id = r.user_id
  left join auth.users u on u.id = r.user_id
  where public.spin_is_admin() and c.starts_at >= now() - interval '2 hours'
  order by r.class_id, r.bike;
$$;

create or replace function public.spin_list_admins()
returns table(user_id uuid, display_name text, email text)
language sql stable security definer set search_path = public, auth as $$
  select a.user_id, p.display_name, u.email::text
  from public.spin_admins a
  left join public.spin_profiles p on p.user_id = a.user_id
  left join auth.users u on u.id = a.user_id
  where public.spin_is_admin()
  order by u.email;
$$;

-- Promote an existing, email-confirmed account to admin. Returns 'ok' or 'not_found'.
create or replace function public.spin_add_admin(p_email text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare uid uuid;
begin
  if not public.spin_is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select id into uid from auth.users
   where lower(email) = lower(trim(p_email)) and email_confirmed_at is not null;
  if uid is null then return 'not_found'; end if;
  insert into public.spin_admins(user_id) values (uid) on conflict do nothing;
  return 'ok';
end $$;

-- Remove an admin (never yourself, so there is always at least one). Returns 'ok' or 'self'.
create or replace function public.spin_remove_admin(p_user uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.spin_is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_user = auth.uid() then return 'self'; end if;
  delete from public.spin_admins where user_id = p_user;
  return 'ok';
end $$;

revoke all on function public.spin_roster() from public, anon;
revoke all on function public.spin_list_admins() from public, anon;
revoke all on function public.spin_add_admin(text) from public, anon;
revoke all on function public.spin_remove_admin(uuid) from public, anon;
grant execute on function public.spin_roster() to authenticated;
grant execute on function public.spin_list_admins() to authenticated;
grant execute on function public.spin_add_admin(text) to authenticated;
grant execute on function public.spin_remove_admin(uuid) to authenticated;
