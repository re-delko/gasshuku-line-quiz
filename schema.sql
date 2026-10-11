-- 年始合宿アプリ（2027-01-08〜09）Supabase スキーマ
-- Supabase ダッシュボードの SQL Editor に全文を貼り付けて実行する。何度実行しても壊れない。
-- このファイルは公開リポジトリに置かれる前提で、パスワードや社員の情報を一切含めない。
--
-- 守り方（詳しくは 02_設計/セキュリティ確認.md）
-- 1. 表はすべて直接読めない。読み書きは関数だけを通す。
-- 2. 参加者は、運営が承認した端末（端末ごとの合鍵）でしか中身を読めない。URL を知っているだけでは何も見えない。
-- 3. 運営の操作は運営パスコードが必要。初期パスコードは SQL Editor でしか設定できない。
-- 4. 表彰の受賞者・重大発表の中身は、発表の時刻になるまで誰にも返さない。
-- 5. 画面のリアルタイム更新は「変わった」という合図（中身なし）だけを配る。

create extension if not exists pgcrypto with schema extensions;

-- ===== 表 =====
create table if not exists admin_config (
  id int primary key default 1 check (id = 1),
  passcode_hash text not null
);

create table if not exists settings (
  id int primary key default 1 check (id = 1),
  title text not null default 'FY27 Q1合宿',
  period_text text default '2027年1月8日（金）〜9日（土）',
  venue text default '（会場は決まり次第お知らせします）',
  message text default ''
);
insert into settings (id) values (1) on conflict (id) do nothing;

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  team text default '',
  room text default '',
  sort int default 0
);

-- 参加者の端末。合鍵（端末で作る乱数）の指紋だけを持つ
create table if not exists devices (
  id uuid primary key default gen_random_uuid(),
  key_hash text unique not null,
  typed_name text not null,
  line_name text default '',
  line_user_id text default '',
  member_id uuid references members(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved')),
  created_at timestamptz not null default now()
);

create table if not exists schedule_items (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  start_time time not null,
  end_time time,
  title text not null,
  place text default '',
  note text default ''
);

create table if not exists guide_pages (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text default '',
  sort int default 0
);

create table if not exists notices (
  id uuid primary key default gen_random_uuid(),
  body text not null,
  created_at timestamptz not null default now()
);

create table if not exists awards (
  id uuid primary key default gen_random_uuid(),
  category text not null,
  winner text default '',
  comment text default '',
  sort int default 0,
  revealed boolean not null default false
);

create table if not exists reveals (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text default '',
  sort int default 0,
  revealed boolean not null default false
);

create table if not exists quiz_questions (
  order_no int primary key,
  question_text text not null,
  choices jsonb not null default '[]',
  correct_index int not null default 0
);

create table if not exists quiz_answers (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members(id) on delete cascade,
  question_order int not null,
  choice_index int not null,
  answered_at timestamptz not null default now(),
  unique (member_id, question_order)
);

-- いまの場面。scene: idle / work / award / reveal / quiz / buzz / bingo
create table if not exists live_state (
  id int primary key default 1 check (id = 1),
  scene text not null default 'idle',
  payload jsonb not null default '{}',
  updated_at timestamptz not null default now()
);
insert into live_state (id) values (1) on conflict (id) do nothing;

create table if not exists reactions (
  id bigserial primary key,
  member_id uuid references members(id) on delete cascade,
  kind text not null,
  created_at timestamptz not null default now()
);

create table if not exists buzzes (
  id bigserial primary key,
  round int not null,
  member_id uuid not null references members(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (round, member_id)
);

-- 合図。中身は持たない（どの種類が何回変わったかと、リアクションの絵文字の種類だけ）
create table if not exists pulse (
  topic text primary key,
  ver bigint not null default 0,
  info jsonb not null default '{}',
  at timestamptz not null default now()
);
insert into pulse (topic) values ('content'), ('live'), ('quiz'), ('buzz'), ('react') on conflict do nothing;

-- ===== 権限：pulse 以外は直接読めない・書けない =====
do $$
declare t text;
begin
  foreach t in array array['admin_config','settings','members','devices','schedule_items','guide_pages','notices','awards','reveals',
                           'quiz_questions','quiz_answers','live_state','reactions','buzzes','pulse'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
  if not exists (select 1 from pg_policies where tablename = 'pulse' and policyname = 'pulse_read') then
    create policy pulse_read on pulse for select using (true);
  end if;
  begin
    alter publication supabase_realtime add table pulse;
  exception when duplicate_object then null;
  end;
end $$;

-- ===== 合図を出す仕掛け =====
create or replace function _bump() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update pulse set ver = ver + 1, at = now(),
    info = case when tg_table_name = 'reactions' and tg_op = 'INSERT' then jsonb_build_object('kind', to_jsonb(new)->>'kind') else '{}'::jsonb end
   where topic = tg_argv[0];
  return null;
end $$;

do $$
declare r record;
begin
  for r in select * from (values
    ('settings','content'), ('members','content'), ('devices','content'), ('schedule_items','content'),
    ('guide_pages','content'), ('notices','content'), ('live_state','live'), ('quiz_answers','quiz'),
    ('buzzes','buzz'), ('reactions','react')) v(tbl, topic) loop
    execute format('drop trigger if exists bump_%s on %I', r.tbl, r.tbl);
    execute format('create trigger bump_%s after insert or update or delete on %I for each row execute function _bump(%L)', r.tbl, r.tbl, r.topic);
  end loop;
end $$;

-- ===== 本人確認 =====
create or replace function is_admin(code text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from admin_config where length(coalesce(code, '')) >= 12 and passcode_hash = extensions.crypt(code, passcode_hash));
$$;

create or replace function _key_hash(p_key text) returns text
language sql immutable as $$ select encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex') $$;

-- 承認済み端末の持ち主（名簿の id）。承認されていなければ null
create or replace function _member(p_key text) returns uuid
language sql stable security definer set search_path = public as $$
  select member_id from devices where key_hash = _key_hash(p_key) and status = 'approved' and length(coalesce(p_key, '')) >= 32;
$$;

-- 見てよい人か（承認済みの参加者か運営）。見てはいけなければ止める
create or replace function _check_view(p_key text) returns uuid
language plpgsql stable security definer set search_path = public as $$
declare m uuid;
begin
  m := _member(p_key);
  if m is not null then return m; end if;
  if is_admin(p_key) then return null; end if;
  raise exception '参加の承認がまだです' using errcode = '42501';
end $$;

-- 初期パスコード。SQL Editor でだけ実行できる（画面からは呼べない）。設定済みなら何もしない
create or replace function set_initial_passcode(new_code text) returns text
language plpgsql security definer set search_path = public, extensions as $$
begin
  if length(coalesce(new_code, '')) < 12 then raise exception 'パスコードは12文字以上にしてください'; end if;
  if exists (select 1 from admin_config) then return '既に設定済みです（変えるときは運営パネルの設定タブから）'; end if;
  insert into admin_config (id, passcode_hash) values (1, extensions.crypt(new_code, extensions.gen_salt('bf', 10)));
  return '設定しました';
end $$;

-- ===== 参加者：参加の申請 =====
create or replace function join_request(p_key text, p_name text, p_line_user_id text, p_line_name text) returns text
language plpgsql security definer set search_path = public as $$
declare d devices; m uuid; n int;
begin
  if length(coalesce(p_key, '')) < 32 then raise exception '端末の合鍵が不正です'; end if;
  if length(trim(coalesce(p_name, ''))) = 0 or length(p_name) > 40 then raise exception '名前を入れてください'; end if;
  select * into d from devices where key_hash = _key_hash(p_key);
  if d.status = 'approved' then return 'approved'; end if;
  if d.id is null and (select count(*) from devices where status = 'pending') >= 200 then raise exception '申請が多すぎます。運営に声をかけてください'; end if;
  -- 名簿の名前と空白を除いて一致すれば候補として結びつけておく（承認は運営が行う）
  select min(id::text)::uuid, count(*) into m, n from members
   where replace(replace(name, ' ', ''), '　', '') = replace(replace(trim(p_name), ' ', ''), '　', '');
  insert into devices (key_hash, typed_name, line_user_id, line_name, member_id)
  values (_key_hash(p_key), trim(p_name), left(coalesce(p_line_user_id, ''), 64), left(coalesce(p_line_name, ''), 40), case when n = 1 then m end)
  on conflict (key_hash) do update set typed_name = excluded.typed_name, member_id = excluded.member_id,
    line_user_id = excluded.line_user_id, line_name = excluded.line_name;
  return 'pending';
end $$;

create or replace function my_status(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select status from devices where key_hash = _key_hash(p_key)), 'none');
$$;

-- ===== 参加者・スクリーン：読む =====
-- いまの場面（発表の時刻前は、受賞者と発表の中身を外して返す）
create or replace function live_view(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid; s live_state; p jsonb; res jsonb; joined int; q quiz_questions; mine int; answered int;
begin
  me := _check_view(p_key);
  select * into s from live_state where id = 1;
  p := s.payload;
  if s.scene in ('award', 'reveal') and now() < (p->>'show_at')::timestamptz then
    p := p - 'winner' - 'comment' - 'title' - 'body';
  end if;
  select count(distinct member_id) into joined from devices where status = 'approved';
  res := jsonb_build_object('scene', s.scene, 'payload', p, 'joined', joined, 'server_now', now());

  if s.scene = 'quiz' then
    select * into q from quiz_questions where order_no = (p->>'q')::int;
    select choice_index into mine from quiz_answers where member_id = me and question_order = q.order_no;
    select count(*) into answered from quiz_answers where question_order = q.order_no;
    res := res || jsonb_build_object('quiz', jsonb_build_object(
      'question_text', q.question_text, 'choices', q.choices, 'my_choice', mine, 'answered', answered,
      -- 正解は、自分が答えたあとか、全問終わってからだけ返す
      'correct_index', case when mine is not null or p->>'phase' = 'finished' then q.correct_index end,
      'ranking', case when p->>'phase' = 'finished' then (
        select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'score', r.score) order by r.score desc, r.last), '[]')
        from (select mb.id, mb.name,
                count(*) filter (where a.choice_index = qq.correct_index) as score,
                coalesce(max(a.answered_at), 'infinity') as last
              from members mb
              left join quiz_answers a on a.member_id = mb.id
              left join quiz_questions qq on qq.order_no = a.question_order
              where mb.id in (select member_id from devices where status = 'approved')
              group by mb.id, mb.name) r) end));
  elsif s.scene = 'buzz' then
    res := res || jsonb_build_object('buzz', (
      select coalesce(jsonb_agg(jsonb_build_object('id', mb.id, 'name', mb.name) order by b.created_at, b.id), '[]')
      from buzzes b join members mb on mb.id = b.member_id where b.round = (p->>'round')::int));
  elsif s.scene = 'bingo' then
    res := res || jsonb_build_object('bingo_winners', (
      select coalesce(jsonb_agg(distinct mb.name), '[]') from reactions r join members mb on mb.id = r.member_id
      where r.kind = 'bingo' and r.created_at >= coalesce((p->>'started_at')::timestamptz, '-infinity')));
  end if;
  return res;
end $$;

-- ホームとしおりに要るものをまとめて返す
create or replace function view_all(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare me uuid;
begin
  me := _check_view(p_key);
  return jsonb_build_object(
    'me', (select to_jsonb(m) from members m where m.id = me),
    'settings', (select to_jsonb(s) from settings s where id = 1),
    'schedule', (select coalesce(jsonb_agg(to_jsonb(x) order by x.date, x.start_time), '[]') from schedule_items x),
    'guide', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort), '[]') from guide_pages x),
    'notices', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]') from (select * from notices order by created_at desc limit 10) x),
    'live', live_view(p_key));
end $$;

-- ===== 参加者：書く =====
create or replace function _quiz_try_advance(p_q int) returns void
language plpgsql security definer set search_path = public as $$
declare s live_state; total int; answered int; n int;
begin
  select * into s from live_state where id = 1 for update;
  if s.scene <> 'quiz' or s.payload->>'phase' <> 'answering' or (s.payload->>'q')::int <> p_q then return; end if;
  select count(distinct member_id) into total from devices where status = 'approved';
  select count(*) into answered from quiz_answers where question_order = p_q;
  if total = 0 or answered < total then return; end if;
  select count(*) into n from quiz_questions;
  update live_state set updated_at = now(), payload = case when p_q >= n
      then jsonb_build_object('q', p_q, 'phase', 'finished', 'total', n)
      else jsonb_build_object('q', p_q + 1, 'phase', 'answering', 'total', n) end
   where id = 1;
end $$;

create or replace function quiz_answer(p_key text, p_q int, p_choice int) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid; s live_state;
begin
  me := _member(p_key);
  if me is null then raise exception '参加の承認がまだです'; end if;
  select * into s from live_state where id = 1;
  if s.scene <> 'quiz' or s.payload->>'phase' <> 'answering' or (s.payload->>'q')::int <> p_q then raise exception 'この問題の受付は終わりました'; end if;
  insert into quiz_answers (member_id, question_order, choice_index) values (me, p_q, p_choice) on conflict do nothing;
  perform _quiz_try_advance(p_q);
end $$;

create or replace function buzz_press(p_key text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid; s live_state;
begin
  me := _member(p_key);
  if me is null then raise exception '参加の承認がまだです'; end if;
  select * into s from live_state where id = 1;
  if s.scene <> 'buzz' or not coalesce((s.payload->>'open')::boolean, false) then raise exception '受付は締め切りました'; end if;
  insert into buzzes (round, member_id) values ((s.payload->>'round')::int, me) on conflict do nothing;
end $$;

create or replace function react(p_key text, p_kind text) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid;
begin
  me := _member(p_key);
  if me is null then raise exception '参加の承認がまだです'; end if;
  if p_kind not in ('clap', 'party', 'laugh', 'heart', 'bingo') then raise exception '種類が違います'; end if;
  if p_kind = 'bingo' and (select scene from live_state where id = 1) <> 'bingo' then raise exception 'ビンゴの最中ではありません'; end if;
  -- 連打で画面が埋まらないよう、1人1秒に1回まで
  if exists (select 1 from reactions where member_id = me and created_at > now() - interval '1 second') then return; end if;
  insert into reactions (member_id, kind) values (me, p_kind);
end $$;

-- ===== 運営 =====
create or replace function admin_check(code text) returns boolean
language sql stable security definer set search_path = public as $$ select is_admin(code) $$;

create or replace function _admin_guard(code text, tbl text) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if tbl not in ('settings','members','schedule_items','guide_pages','notices','awards','reveals','quiz_questions') then
    raise exception '編集できない表です: %', tbl;
  end if;
  return case tbl when 'quiz_questions' then 'order_no' else 'id' end;
end $$;

create or replace function admin_list(code text, tbl text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  perform _admin_guard(code, tbl);
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from %I t', tbl) into r;
  return r;
end $$;

create or replace function admin_save(code text, tbl text, row_data jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pk text; cols text; sets text; r jsonb;
begin
  pk := _admin_guard(code, tbl);
  row_data := row_data - 'revealed' - 'created_at';
  if tbl <> 'quiz_questions' and (row_data->>pk) is null then row_data := row_data - pk; end if;
  select string_agg(format('%I', k), ','), string_agg(format('%I = excluded.%I', k, k), ',') filter (where k <> pk)
    into cols, sets from jsonb_object_keys(row_data) k;
  execute format(
    'insert into %I as t (%s) select %s from jsonb_populate_record(null::%I, $1) on conflict (%I) do %s returning to_jsonb(t)',
    tbl, cols, cols, tbl, pk, case when sets is null then 'nothing' else 'update set ' || sets end
  ) into r using row_data;
  return r;
end $$;

create or replace function admin_delete(code text, tbl text, row_id text) returns void
language plpgsql security definer set search_path = public as $$
declare pk text;
begin
  pk := _admin_guard(code, tbl);
  if tbl = 'settings' then raise exception '基本情報は削除できません'; end if;
  execute format('delete from %I where %I::text = $1', tbl, pk) using row_id;
end $$;

-- 参加申請の一覧・承認・取り消し
create or replace function admin_devices(code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'typed_name', d.typed_name, 'line_name', d.line_name,
      'member_id', d.member_id, 'member_name', m.name, 'status', d.status, 'created_at', d.created_at) order by d.status desc, d.created_at), '[]')
    from devices d left join members m on m.id = d.member_id);
end $$;

create or replace function admin_approve(code text, p_device_id uuid, p_member_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if p_member_id is null then raise exception '名簿の誰かを選んでください'; end if;
  update devices set member_id = p_member_id, status = 'approved' where id = p_device_id;
end $$;

-- 名前が名簿と1人だけ一致した申請をまとめて承認する
create or replace function admin_approve_matched(code text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  update devices set status = 'approved' where status = 'pending' and member_id is not null;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function admin_remove_device(code text, p_device_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  delete from devices where id = p_device_id;
end $$;

create or replace function admin_set_live(code text, p_scene text, p_payload jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if p_scene not in ('idle','work','quiz','buzz','bingo') then raise exception '切り替えられない場面です: %', p_scene; end if;
  update live_state set scene = p_scene, payload = coalesce(p_payload, '{}'), updated_at = now() where id = 1;
end $$;

create or replace function admin_present(code text, p_kind text, p_id uuid, p_delay_sec int default 5) returns void
language plpgsql security definer set search_path = public as $$
declare a awards; v reveals; show_at text;
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  show_at := to_char((now() + make_interval(secs => greatest(p_delay_sec, 0))) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  if p_kind = 'award' then
    update awards set revealed = true where id = p_id returning * into a;
    if a.id is null then raise exception '表彰が見つかりません'; end if;
    update live_state set scene = 'award', updated_at = now(),
      payload = jsonb_build_object('id', a.id, 'category', a.category, 'winner', a.winner, 'comment', a.comment, 'show_at', show_at) where id = 1;
  elsif p_kind = 'reveal' then
    update reveals set revealed = true where id = p_id returning * into v;
    if v.id is null then raise exception '重大発表が見つかりません'; end if;
    update live_state set scene = 'reveal', updated_at = now(),
      payload = jsonb_build_object('id', v.id, 'title', v.title, 'body', v.body, 'show_at', show_at) where id = 1;
  else
    raise exception '種類が違います: %', p_kind;
  end if;
end $$;

create or replace function admin_reset(code text, what text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if what = 'quiz' then delete from quiz_answers where true;
  elsif what = 'buzz' then delete from buzzes where true;
  elsif what = 'reactions' then delete from reactions where true;
  elsif what = 'present' then update awards set revealed = false where true; update reveals set revealed = false where true;
  else raise exception '種類が違います: %', what;
  end if;
end $$;

-- 合宿が終わったら、社員の情報と伏せていた中身をすべて消す
create or replace function admin_wipe_all(code text, confirm_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if confirm_text <> 'すべて消す' then raise exception '確認の文字が違います'; end if;
  delete from quiz_answers where true; delete from buzzes where true; delete from reactions where true;
  delete from devices where true; delete from members where true;
  delete from awards where true; delete from reveals where true; delete from notices where true;
  update live_state set scene = 'idle', payload = '{}', updated_at = now() where id = 1;
end $$;

create or replace function admin_change_passcode(code text, new_code text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if length(coalesce(new_code, '')) < 12 then raise exception 'パスコードは12文字以上にしてください'; end if;
  update admin_config set passcode_hash = extensions.crypt(new_code, extensions.gen_salt('bf', 10)) where id = 1;
end $$;

-- 内部用の関数は画面から呼べないようにする
revoke execute on function is_admin(text), _key_hash(text), _member(text), _check_view(text), _admin_guard(text, text),
  _quiz_try_advance(int), set_initial_passcode(text), _bump() from public, anon, authenticated;

-- ===== 仮の中身（運営パネルからいつでも書き換えられる。社員の情報は入れない） =====
insert into guide_pages (title, body, sort)
select * from (values
  ('持ち物', E'・ノートPC と充電器\n・筆記用具\n・着替え（1泊分）\n・常備薬\n（会場が決まったら更新します）', 1),
  ('合宿のルール', E'・時間を守る\n・スマホはクイズやゲームで使うので、充電しておく\n（運営が書き換えます）', 2)
) v(title, body, sort)
where not exists (select 1 from guide_pages);

insert into schedule_items (date, start_time, end_time, title)
select * from (values
  ('2027-01-08'::date, '09:00'::time, '09:30'::time, '集合・オープニング（仮）'),
  ('2027-01-08'::date, '09:30'::time, '12:00'::time, 'ワーク（仮）'),
  ('2027-01-08'::date, '18:00'::time, '19:00'::time, '懇親会（仮）'),
  ('2027-01-09'::date, '09:00'::time, '12:00'::time, 'ワーク（仮）'),
  ('2027-01-09'::date, '17:00'::time, '19:00'::time, '表彰・クロージング（仮）')
) v(date, start_time, end_time, title)
where not exists (select 1 from schedule_items);

insert into quiz_questions (order_no, question_text, choices, correct_index) values
(1, 'サンプル問題1（差し替え予定）', '["選択肢A","選択肢B","選択肢C","選択肢D"]', 0),
(2, 'サンプル問題2（差し替え予定）', '["選択肢A","選択肢B","選択肢C","選択肢D"]', 1),
(3, 'サンプル問題3（差し替え予定）', '["選択肢A","選択肢B","選択肢C","選択肢D"]', 2)
on conflict (order_no) do nothing;
