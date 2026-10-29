-- GenBI in ACTION - Presensi QR | Jalankan sekali di Supabase > SQL Editor
create table if not exists sessions(id text primary key, n text not null, d text, j text, o bigint default 0, x bigint default 0, c bigint, kd text default 'hadir');
create table if not exists people(id text primary key, e text unique not null, n text not null, s text default '', k text default '', g text default '');
create table if not exists att(id text primary key, sid text not null references sessions(id) on delete cascade, pid text not null references people(id) on delete cascade, t bigint not null, sg text, unique(sid,pid));
create table if not exists cfg(id text primary key, lock boolean default false);

-- Additional columns for people
alter table people add column if not exists jk text default '';
alter table people add column if not exists hp text default '';
alter table people add column if not exists lt text default '';
alter table people add column if not exists gd text default '';
alter table people add column if not exists np text default '';
alter table people add column if not exists rv bigint default null;
alter table people add column if not exists tes boolean default false;
alter table people alter column id set default gen_random_uuid()::text;

-- Additional columns for sessions, cfg, and att
alter table sessions add column if not exists kd text default 'hadir';
alter table cfg add column if not exists fb boolean default false;
alter table cfg add column if not exists fbt bigint default 0;
alter table cfg add column if not exists rd text default '';
alter table cfg add column if not exists loc text default '';
alter table att add column if not exists dv text;
alter table att add column if not exists ua text;

create table if not exists fbk(id text primary key, pid text unique not null references people(id) on delete cascade, t bigint not null, kesan text default '', pesan text default '');
insert into cfg(id,lock) values('main',false) on conflict do nothing;

-- High-performance indexes for Free Tier scaling (537+ concurrent participants)
create index if not exists att_sid_idx on att(sid);
create index if not exists att_pid_idx on att(pid);
create index if not exists att_dv_idx on att(dv);
create index if not exists people_k_idx on people(k);
create index if not exists people_g_idx on people(g);
create index if not exists people_hp_idx on people(hp);

alter table sessions enable row level security;
alter table people enable row level security;
alter table att enable row level security;
alter table cfg enable row level security;
alter table fbk enable row level security;
revoke all on sessions,people,att,cfg,fbk from anon;

-- Hanya EO (user login) yang boleh membaca/menulis tabel langsung
do $$ declare t text; begin
 foreach t in array array['sessions','people','att','cfg','fbk'] loop
  execute format('drop policy if exists eo_all on %I',t);
  execute format('create policy eo_all on %I for all to authenticated using (true) with check (true)',t);
 end loop; end $$;

-- Peserta: login dengan email atau nomor HP (satu panggilan, semua data sekaligus)
create or replace function peserta_login(p_email text) returns json language plpgsql security definer set search_path=public as $$
declare me people;
begin
 select * into me from people 
 where e = lower(trim(p_email)) or (hp <> '' and hp = trim(p_email))
 limit 1;

 if not found then return json_build_object('ok',false); end if;

 return json_build_object('ok',true,
  'me',json_build_object('n',me.n,'e',me.e,'hp',me.hp,'s',me.s,'k',me.k,'g',me.g,'np',me.np,'jk',me.jk,'lt',me.lt,'gd',me.gd,'rv',me.rv,'tes',coalesce(me.tes,false)),
  'rm',coalesce((select json_agg(n order by n) from people where k=me.k and k<>'' and id<>me.id),'[]'::json),
  'gm',coalesce((select json_agg(n order by n) from people where g=me.g and g<>'' and id<>me.id),'[]'::json),
  'ss',coalesce((select json_agg(row_to_json(q) order by q.d,q.c) from (select id,n,d,j,o,x,c,kd from sessions) q),'[]'::json),
  'at',coalesce((select json_agg(json_build_object('sid',sid,'t',t)) from att where pid=me.id),'[]'::json),
  'lock',coalesce((select lock from cfg where id='main'),false),
  'rd',coalesce((select rd from cfg where id='main'),''),
  'loc',coalesce((select loc from cfg where id='main'),''),
  'fb',json_build_object('manual',coalesce((select fb from cfg where id='main'),false),'at',coalesce((select fbt from cfg where id='main'),0),'mine',(select json_build_object('kesan',kesan,'pesan',pesan) from fbk where pid=me.id)),
  'now',(extract(epoch from now())*1000)::bigint);
end $$;

drop function if exists peserta_absen(text,text,text);
drop function if exists peserta_absen(text,text,text,text,text);
-- Peserta: kirim absen (jam dicek memakai waktu SERVER, 1x per sesi dijamin unique)
create or replace function peserta_absen(p_email text, p_sid text, p_sig text, p_dev text default null, p_ua text default null) returns json language plpgsql security definer set search_path=public as $$
declare 
 me people; 
 s sessions; 
 nowms bigint := (extract(epoch from now())*1000)::bigint; 
 lk boolean; 
 n int;
 rk_name text;
 rk_time bigint;
begin
 select * into me from people 
 where e = lower(trim(p_email)) or (hp <> '' and hp = trim(p_email))
 limit 1;

 if not found then return json_build_object('ok',false,'err','Peserta tidak terdaftar'); end if;

 select * into s from sessions where id=p_sid;
 if not found then return json_build_object('ok',false,'err','Sesi tidak ditemukan'); end if;

 select coalesce(lock,false) into lk from cfg where id='main';
 if coalesce(lk,false) then
  if s.o>0 and nowms<s.o then return json_build_object('ok',false,'err','Absensi belum dibuka. Silakan hubungi panitia.'); end if;
  if s.x>0 and nowms>s.x then return json_build_object('ok',false,'err','Absensi sudah ditutup. Silakan hubungi panitia.'); end if;
 end if;

 -- Jika sesi kunci kamar, pastikan hanya 1 kunci diambil per kamar
 if s.kd = 'kunci' and me.k <> '' then
  select p.n, a.t into rk_name, rk_time 
  from att a join people p on a.pid=p.id 
  where a.sid=p_sid and p.k=me.k and p.id<>me.id 
  limit 1;

  if rk_name is not null then
   return json_build_object('ok',false,'err','Kunci kamar sudah diambil oleh '||rk_name,'by',rk_name,'t',rk_time);
  end if;
 end if;

 if length(coalesce(p_sig,''))<200 or length(p_sig)>80000 then return json_build_object('ok',false,'err','Tanda tangan tidak valid'); end if;

 insert into att(id,sid,pid,t,sg,dv,ua) 
 values(p_sid||'_'||me.id,p_sid,me.id,nowms,p_sig,left(p_dev,32),left(p_ua,120)) 
 on conflict do nothing;

 get diagnostics n=row_count;
 return json_build_object('ok',true,'dup',n=0,'t',coalesce((select t from att where sid=p_sid and pid=me.id),nowms));
end $$;

-- Peserta: undian kelompok (atomic server-side update)
create or replace function peserta_undi(p_email text, p_sid text) returns json language plpgsql security definer set search_path=public as $$
declare
 me people;
 s sessions;
 nowms bigint := (extract(epoch from now())*1000)::bigint;
 lk boolean;
 is_tester boolean;
begin
 select * into me from people 
 where e = lower(trim(p_email)) or (hp <> '' and hp = trim(p_email))
 limit 1;

 if not found then return json_build_object('ok',false,'err','Peserta tidak terdaftar'); end if;

 select * into s from sessions where id=p_sid;
 if not found then return json_build_object('ok',false,'err','Sesi tidak ditemukan'); end if;

 select coalesce(lock,false) into lk from cfg where id='main';
 if coalesce(lk,false) then
  if s.o>0 and nowms<s.o then return json_build_object('ok',false,'err','Undian belum dibuka. Silakan hubungi panitia.'); end if;
  if s.x>0 and nowms>s.x then return json_build_object('ok',false,'err','Undian sudah ditutup. Silakan hubungi panitia.'); end if;
 end if;

 is_tester := coalesce(me.tes, false);

 if me.rv is not null and me.rv > 0 and not is_tester then
  return json_build_object('ok',true,'first',false,'g',me.g,'rv',me.rv);
 end if;

 update people set rv = nowms where id = me.id;

 -- Catat juga kehadiran sesi undian jika belum
 insert into att(id,sid,pid,t,sg) values(p_sid||'_'||me.id,p_sid,me.id,nowms,'undian') on conflict do nothing;

 return json_build_object('ok',true,'first',true,'g',me.g,'rv',nowms);
end $$;

-- Peserta: kirim kesan & pesan (hanya saat dibuka EO / waktu otomatis, dicek di server)
create or replace function peserta_kesan(p_email text, p_kesan text, p_pesan text) returns json language plpgsql security definer set search_path=public as $$
declare me people; c cfg; nowms bigint:=(extract(epoch from now())*1000)::bigint;
begin
 select * into me from people 
 where e = lower(trim(p_email)) or (hp <> '' and hp = trim(p_email))
 limit 1;

 if not found then return json_build_object('ok',false,'err','Email tidak terdaftar'); end if;
 select * into c from cfg where id='main';
 if not (coalesce(c.fb,false) or (coalesce(c.fbt,0)>0 and nowms>=c.fbt)) then return json_build_object('ok',false,'err','Kesan dan pesan belum dibuka'); end if;
 if length(coalesce(p_kesan,''))>2000 or length(coalesce(p_pesan,''))>2000 then return json_build_object('ok',false,'err','Terlalu panjang (maks 2000 karakter)'); end if;
 insert into fbk(id,pid,t,kesan,pesan) values(me.id,me.id,nowms,coalesce(p_kesan,''),coalesce(p_pesan,'')) on conflict (pid) do update set t=excluded.t,kesan=excluded.kesan,pesan=excluded.pesan;
 return json_build_object('ok',true);
end $$;

revoke all on function peserta_login(text), peserta_absen(text,text,text,text,text), peserta_undi(text,text), peserta_kesan(text,text,text) from public;
grant execute on function peserta_login(text), peserta_absen(text,text,text,text,text), peserta_undi(text,text), peserta_kesan(text,text,text) to anon, authenticated;
