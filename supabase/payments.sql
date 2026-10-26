-- Run once in the Supabase SQL Editor of project "spinning-reservas".
-- Adds: payment choice per reservation (SIMPE proof or pay at the studio), private proof storage,
-- admin "paid" flag, and an atomic "change bike" function that keeps the payment attached.

create table if not exists public.spin_payments (
  reservation_id uuid primary key references public.spin_reservations(id) on delete cascade,
  user_id uuid not null,
  method text not null check (method in ('simpe','local')),
  proof_path text,
  paid boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.spin_payments enable row level security;
drop policy if exists "read own or admin payments" on public.spin_payments;
create policy "read own or admin payments" on public.spin_payments
  for select to authenticated using (user_id = auth.uid() or public.spin_is_admin());
-- no insert/update/delete policies: all writes go through the functions below

-- the owner sets how they will pay (cannot change it once an admin marked it paid)
create or replace function public.spin_set_payment(p_res uuid, p_method text, p_proof text)
returns void language plpgsql security definer set search_path = public as $$
declare r public.spin_reservations; old public.spin_payments;
begin
  if p_method not in ('simpe','local') then raise exception 'bad method' using errcode = '22023'; end if;
  select * into r from public.spin_reservations where id = p_res and user_id = auth.uid();
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_method = 'simpe' and (p_proof is null or split_part(p_proof, '/', 1) <> auth.uid()::text) then
    raise exception 'proof required' using errcode = '22023';
  end if;
  select * into old from public.spin_payments where reservation_id = p_res;
  if found and old.paid then raise exception 'already paid' using errcode = '42501'; end if;
  insert into public.spin_payments(reservation_id, user_id, method, proof_path)
  values (p_res, auth.uid(), p_method, case when p_method = 'simpe' then p_proof end)
  on conflict (reservation_id) do update
    set method = excluded.method, proof_path = excluded.proof_path, updated_at = now();
end $$;
revoke all on function public.spin_set_payment(uuid, text, text) from public, anon;
grant execute on function public.spin_set_payment(uuid, text, text) to authenticated;

-- admin marks a reservation as paid / not paid
create or replace function public.spin_set_paid(p_res uuid, p_paid boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r public.spin_reservations;
begin
  if not public.spin_is_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into r from public.spin_reservations where id = p_res;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  insert into public.spin_payments(reservation_id, user_id, method, paid)
  values (p_res, r.user_id, 'local', p_paid)
  on conflict (reservation_id) do update set paid = p_paid, updated_at = now();
end $$;
revoke all on function public.spin_set_paid(uuid, boolean) from public, anon;
grant execute on function public.spin_set_paid(uuid, boolean) to authenticated;

-- move my reservation to another bike (keeps the payment; unique(class_id, bike) rejects taken bikes)
create or replace function public.spin_change_bike(p_class uuid, p_bike int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.spin_classes c
                 where c.id = p_class and c.starts_at > now() and p_bike between 1 and c.capacity
                   and (public.spin_is_admin() or c.starts_at < public.spin_booking_limit())) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if public.spin_bike_blocked(p_class, p_bike) then raise exception 'blocked' using errcode = '42501'; end if;
  update public.spin_reservations set bike = p_bike, hold_id = null
   where class_id = p_class and user_id = auth.uid();
  if not found then raise exception 'no reservation' using errcode = 'P0002'; end if;
end $$;
revoke all on function public.spin_change_bike(uuid, int) from public, anon;
grant execute on function public.spin_change_bike(uuid, int) to authenticated;

-- private bucket for SIMPE proofs: each user writes only inside their own folder; admins read all
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('spin-proofs', 'spin-proofs', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "spin proofs upload own" on storage.objects;
create policy "spin proofs upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'spin-proofs' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "spin proofs read own or admin" on storage.objects;
create policy "spin proofs read own or admin" on storage.objects for select to authenticated
  using (bucket_id = 'spin-proofs' and ((storage.foldername(name))[1] = auth.uid()::text or public.spin_is_admin()));
drop policy if exists "spin proofs delete own or admin" on storage.objects;
create policy "spin proofs delete own or admin" on storage.objects for delete to authenticated
  using (bucket_id = 'spin-proofs' and ((storage.foldername(name))[1] = auth.uid()::text or public.spin_is_admin()));
