-- 合宿アプリ（年始合宿 2027-01-08〜09・ゲーム版）Supabase スキーマ
-- Supabase ダッシュボードの SQL Editor に全文を貼り付けて実行する。何度実行しても壊れない。
-- このファイルは公開リポジトリに置かれる前提で、パスワードや社員の情報を一切含めない。
--
-- 守り方（詳しくは 02_設計/セキュリティ確認.md）
-- 1. 表はすべて直接読めない。読み書きは関数だけを通す。
-- 2. 参加者は、運営が承認した端末（端末ごとの合鍵）でしか中身を読めない。URL を知っているだけでは何も見えない。
-- 3. 運営の操作は運営パスコードが必要。初期パスコードは SQL Editor でしか設定できない。
-- 4. 表彰の受賞者・重大発表の中身・クイズの正解は、出す時刻になるまで誰にも返さない。
-- 5. 画面のリアルタイム更新は「変わった」という合図（中身なし）だけを配る。

create extension if not exists pgcrypto with schema extensions;

-- ===== 表 =====
create table if not exists admin_config (
  id int primary key default 1 check (id = 1),
  passcode_hash text not null
);

create table if not exists settings (
  id int primary key default 1 check (id = 1),
  title text not null default '合宿あそび',
  show_profile boolean not null default false  -- 班と部屋を参加者に見せるか
);
alter table settings add column if not exists show_profile boolean not null default false;
alter table settings drop column if exists period_text;
alter table settings drop column if exists venue;
alter table settings drop column if exists message;
insert into settings (id) values (1) on conflict (id) do nothing;

-- ゲーム版では使わない表（しおり・日程・お知らせは Teams で共有する）
drop table if exists schedule_items, guide_pages, notices cascade;

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  name text not null,              -- 呼び名（ひらがなの下の名前かニックネーム）
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
  points int not null default 0,
  answered_at timestamptz not null default now(),
  unique (member_id, question_order)
);
alter table quiz_answers add column if not exists points int not null default 0;

-- いまの場面。scene: idle / award / reveal / quiz / buzz / bingo
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

-- 点の記録（総合ランキングのもと）。クイズ・早押し・ビンゴの点をここに積む
create table if not exists score_events (
  id bigserial primary key,
  member_id uuid not null references members(id) on delete cascade,
  game text not null,          -- quiz / buzz / bingo
  points int not null,
  note text default '',        -- Q1、早押し第2問 など
  created_at timestamptz not null default now()
);

-- 当日の台本（運営は「次へ」を押すだけで、上から順に進む）
create table if not exists program_steps (
  id uuid primary key default gen_random_uuid(),
  sort int not null default 0,
  kind text not null check (kind in ('idle','quiz','buzz','bingo','ranking','award','reveal')),
  label text not null default '',
  ref uuid,                    -- 表彰・重大発表のときは、その行の id
  done boolean not null default false
);

-- 合図。中身は持たない（どの種類が何回変わったかと、リアクションの絵文字の種類だけ）
create table if not exists pulse (
  topic text primary key,
  ver bigint not null default 0,
  info jsonb not null default '{}',
  at timestamptz not null default now()
);
insert into pulse (topic) values ('content'), ('live'), ('quiz'), ('buzz'), ('react'), ('score'), ('admin') on conflict do nothing;

-- ===== 権限：pulse 以外は直接読めない・書けない =====
do $$
declare t text;
begin
  foreach t in array array['admin_config','settings','members','devices','awards','reveals',
                           'quiz_questions','quiz_answers','live_state','reactions','buzzes','pulse','score_events','program_steps'] loop
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
    ('settings','content'), ('members','content'), ('devices','content'),
    ('live_state','live'), ('quiz_answers','quiz'), ('buzzes','buzz'), ('reactions','react'),
    ('score_events','score'), ('program_steps','admin')) v(tbl, topic) loop
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
  -- 名簿の呼び名と空白を除いて一致すれば候補として結びつけておく（承認は運営が行う）
  select min(id::text)::uuid, count(*) into m, n from members
   where replace(replace(name, ' ', ''), '　', '') = replace(replace(trim(p_name), ' ', ''), '　', '');
  insert into devices (key_hash, typed_name, line_user_id, line_name, member_id)
  values (_key_hash(p_key), trim(p_name), '', left(coalesce(p_line_name, ''), 40), case when n = 1 then m end)
  on conflict (key_hash) do update set typed_name = excluded.typed_name, member_id = excluded.member_id,
    line_name = excluded.line_name;
  return 'pending';
end $$;

create or replace function my_status(p_key text) returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select status from devices where key_hash = _key_hash(p_key)), 'none');
$$;

-- ===== クイズの点数と進行 =====
-- 正解なら 500 点 + 早さの点（出題から 20 秒で 0 点まで下がる、最大 500 点）
create or replace function _quiz_ranking(p_limit int) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'score', r.score, 'correct', r.correct) order by r.score desc, r.name), '[]')
  from (select mb.id, mb.name, coalesce(sum(a.points), 0) as score,
               count(*) filter (where a.points > 0) as correct
          from members mb left join quiz_answers a on a.member_id = mb.id
         where mb.id in (select member_id from devices where status = 'approved')
         group by mb.id, mb.name
         order by score desc, mb.name
         limit p_limit) r;
$$;

-- 総合ランキング（点の記録の合計）
create or replace function _total_ranking(p_limit int) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'name', r.name, 'score', r.score) order by r.score desc, r.name), '[]')
  from (select mb.id, mb.name, coalesce(sum(e.points), 0) as score
          from members mb left join score_events e on e.member_id = mb.id
         where mb.id in (select member_id from devices where status = 'approved')
         group by mb.id, mb.name
         order by score desc, mb.name
         limit p_limit) r;
$$;

-- 自分の総合点と順位（同点は同じ順位）
create or replace function _my_score(p_member uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with t as (select mb.id, coalesce(sum(e.points), 0) as score
               from members mb left join score_events e on e.member_id = mb.id
              where mb.id in (select member_id from devices where status = 'approved')
              group by mb.id)
  select jsonb_build_object('score', (select score from t where id = p_member),
    'rank', (select count(*) + 1 from t where score > (select score from t where id = p_member)),
    'total', (select count(*) from t))
  where p_member is not null;
$$;

-- 次の問題へ（answering → reveal → 次の問題の answering … → finished）
create or replace function _quiz_step(p_force boolean) returns void
language plpgsql security definer set search_path = public as $$
declare s live_state; q int; n int; total int; answered int;
begin
  select * into s from live_state where id = 1 for update;
  if s.scene <> 'quiz' then return; end if;
  q := (s.payload->>'q')::int;
  select count(*) into n from quiz_questions;
  if s.payload->>'phase' = 'answering' then
    select count(distinct member_id) into total from devices where status = 'approved';
    select count(*) into answered from quiz_answers where question_order = q;
    if p_force or (total > 0 and answered >= total) then
      -- 正解発表。7 秒見せたら次へ進んでよい
      update live_state set updated_at = now(), payload = s.payload || jsonb_build_object('phase', 'reveal',
        'next_at', to_char((now() + interval '7 seconds') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) where id = 1;
    end if;
  elsif s.payload->>'phase' = 'reveal' then
    if not p_force and now() < (s.payload->>'next_at')::timestamptz then return; end if;
    if q >= n then
      update live_state set updated_at = now(), payload = jsonb_build_object('q', q, 'phase', 'finished', 'total', n) where id = 1;
    else
      update live_state set updated_at = now(), payload = jsonb_build_object('q', q + 1, 'phase', 'answering', 'total', n,
        'started_at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) where id = 1;
    end if;
  end if;
end $$;

-- ===== 参加者・スクリーン：読む =====
create or replace function live_view(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid; s live_state; p jsonb; res jsonb; joined int; q quiz_questions; mine quiz_answers; answered int; ph text;
begin
  me := _check_view(p_key);
  -- 正解発表の時間が過ぎていたら次の問題へ進める（誰かが見に来たときに進む）
  perform _quiz_step(false) where (select scene = 'quiz' and payload->>'phase' = 'reveal' from live_state where id = 1);
  select * into s from live_state where id = 1;
  p := s.payload;
  if s.scene in ('award', 'reveal') and now() < (p->>'show_at')::timestamptz then
    p := p - 'winner' - 'comment' - 'title' - 'body';
  end if;
  select count(distinct member_id) into joined from devices where status = 'approved';
  res := jsonb_build_object('scene', s.scene, 'payload', p, 'joined', joined, 'server_now', now(), 'me_score', _my_score(me));

  if s.scene = 'idle' then
    res := res || jsonb_build_object('names', (
      select coalesce(jsonb_agg(m.name order by d.created_at desc), '[]') from devices d join members m on m.id = d.member_id where d.status = 'approved'),
      'leaders', _total_ranking(5));
  elsif s.scene = 'ranking' then
    -- 発表の時刻までは順位を返さない
    if now() >= (p->>'show_at')::timestamptz then res := res || jsonb_build_object('leaders', _total_ranking(10)); end if;
  elsif s.scene = 'quiz' then
    ph := p->>'phase';
    select * into q from quiz_questions where order_no = (p->>'q')::int;
    select * into mine from quiz_answers where member_id = me and question_order = q.order_no;
    select count(*) into answered from quiz_answers where question_order = q.order_no;
    res := res || jsonb_build_object('quiz', jsonb_build_object(
      'question_text', q.question_text, 'choices', q.choices, 'answered', answered,
      'my_choice', mine.choice_index, 'my_points', case when ph <> 'answering' then mine.points end,
      -- 正解・答えの分布・順位は、正解発表のあとにだけ返す
      'correct_index', case when ph <> 'answering' then q.correct_index end,
      'dist', case when ph <> 'answering' then (
        select jsonb_agg(coalesce((select count(*) from quiz_answers a where a.question_order = q.order_no and a.choice_index = i), 0) order by i)
        from generate_series(0, greatest(jsonb_array_length(q.choices) - 1, 0)) i) end,
      'ranking', case when ph <> 'answering' then _quiz_ranking(1000) end));
  elsif s.scene = 'buzz' then
    res := res || jsonb_build_object('buzz', (
      select coalesce(jsonb_agg(jsonb_build_object('id', mb.id, 'name', mb.name) order by b.created_at, b.id), '[]')
      from buzzes b join members mb on mb.id = b.member_id where b.round = (p->>'round')::int));
  elsif s.scene = 'bingo' then
    res := res || jsonb_build_object('bingo_winners', (
      select coalesce(jsonb_agg(x.name order by x.at), '[]') from (
        select mb.name, min(r.created_at) as at from reactions r join members mb on mb.id = r.member_id
         where r.kind = 'bingo' and r.created_at >= coalesce((p->>'started_at')::timestamptz, '-infinity')
         group by mb.name) x),
      'reach', (select count(distinct member_id) from reactions
         where kind = 'reach' and created_at >= coalesce((p->>'started_at')::timestamptz, '-infinity')));
  end if;
  return res;
end $$;

-- 起動時に要るもの（自分の呼び名と、公開されていれば班・部屋）
create or replace function view_all(p_key text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me uuid; st settings;
begin
  me := _check_view(p_key);
  select * into st from settings where id = 1;
  return jsonb_build_object(
    'me', (select jsonb_build_object('id', m.id, 'name', m.name,
             'team', case when st.show_profile then m.team end, 'room', case when st.show_profile then m.room end)
           from members m where m.id = me),
    'title', st.title,
    'live', live_view(p_key));
end $$;

-- ===== 参加者：書く =====
create or replace function quiz_answer(p_key text, p_q int, p_choice int) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid; s live_state; q quiz_questions; elapsed numeric; pts int;
begin
  me := _member(p_key);
  if me is null then raise exception '参加の承認がまだです'; end if;
  select * into s from live_state where id = 1;
  if s.scene <> 'quiz' or s.payload->>'phase' <> 'answering' or (s.payload->>'q')::int <> p_q then raise exception 'この問題の受付は終わりました'; end if;
  select * into q from quiz_questions where order_no = p_q;
  elapsed := extract(epoch from now() - coalesce((s.payload->>'started_at')::timestamptz, now()));
  pts := case when p_choice = q.correct_index then 500 + greatest(0, round(500 * (1 - elapsed / 20)))::int else 0 end;
  insert into quiz_answers (member_id, question_order, choice_index, points) values (me, p_q, p_choice, pts) on conflict do nothing;
  if found and pts > 0 then insert into score_events (member_id, game, points, note) values (me, 'quiz', pts, 'Q' || p_q); end if;
  perform _quiz_step(false);
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
declare me uuid; since timestamptz; nth int;
begin
  me := _member(p_key);
  if me is null then raise exception '参加の承認がまだです'; end if;
  if p_kind not in ('clap', 'party', 'laugh', 'heart', 'bingo', 'reach') then raise exception '種類が違います'; end if;
  if p_kind in ('bingo', 'reach') and (select scene from live_state where id = 1) <> 'bingo' then raise exception 'ビンゴの最中ではありません'; end if;
  -- 連打で画面が埋まらないよう、1人1秒に1回まで（ビンゴ・リーチの宣言は除く）
  if p_kind not in ('bingo', 'reach') and exists (select 1 from reactions where member_id = me and created_at > now() - interval '1 second') then return; end if;
  if p_kind = 'bingo' then
    select coalesce((payload->>'started_at')::timestamptz, '-infinity') into since from live_state where id = 1;
    -- 同じ回で2回目の宣言は数えない。宣言した順に 500 / 300 / 200 / 以降 100 点
    if exists (select 1 from reactions where member_id = me and kind = 'bingo' and created_at >= since) then return; end if;
    select count(distinct member_id) into nth from reactions where kind = 'bingo' and created_at >= since;
    insert into score_events (member_id, game, points, note) values (me, 'bingo',
      case nth when 0 then 500 when 1 then 300 when 2 then 200 else 100 end, 'ビンゴ ' || (nth + 1) || '番目');
  end if;
  insert into reactions (member_id, kind) values (me, p_kind);
end $$;

-- ===== 運営 =====
create or replace function admin_check(code text) returns boolean
language sql stable security definer set search_path = public as $$ select is_admin(code) $$;

create or replace function _admin_guard(code text, tbl text) returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if tbl not in ('settings','members','awards','reveals','quiz_questions','program_steps') then
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
declare pk text; cols text; sets text; r jsonb; found_row boolean;
begin
  pk := _admin_guard(code, tbl);
  row_data := row_data - 'revealed' - 'created_at';
  if tbl <> 'quiz_questions' and (row_data->>pk) is null then row_data := row_data - pk; end if;
  -- 既にある行は、渡した項目だけを書き換える（済みの印だけ付ける、など）
  if (row_data->>pk) is not null then
    execute format('select exists (select 1 from %I where %I::text = $1)', tbl, pk) into found_row using row_data->>pk;
    if found_row then
      select string_agg(format('%I = r.%I', k, k), ',') into sets from jsonb_object_keys(row_data) k where k <> pk;
      if sets is null then return null; end if;
      execute format('update %I as t set %s from jsonb_populate_record(null::%I, $1) as r where t.%I::text = $1->>%L returning to_jsonb(t)',
        tbl, sets, tbl, pk, pk) into r using row_data;
      return r;
    end if;
  end if;
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
  update devices set member_id = p_member_id, status = 'approved', line_name = '', line_user_id = '' where id = p_device_id;
end $$;

create or replace function admin_approve_matched(code text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  update devices set status = 'approved', line_name = '', line_user_id = '' where status = 'pending' and member_id is not null;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function admin_remove_device(code text, p_device_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  delete from devices where id = p_device_id;
end $$;

-- 場面を切り替える（クイズは admin_quiz、ビンゴは admin_bingo、表彰・重大発表は admin_present で出す）
create or replace function admin_set_live(code text, p_scene text, p_payload jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if p_scene not in ('idle','buzz') then raise exception '切り替えられない場面です: %', p_scene; end if;
  update live_state set scene = p_scene, payload = coalesce(p_payload, '{}'), updated_at = now() where id = 1;
end $$;

-- 早押しで正解した人に点を付ける（同じ問題で同じ人には1回だけ）
create or replace function admin_buzz_correct(code text, p_member_id uuid, p_points int default 300) returns void
language plpgsql security definer set search_path = public as $$
declare s live_state; v_note text;
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  select * into s from live_state where id = 1;
  if s.scene <> 'buzz' then raise exception '早押しの最中ではありません'; end if;
  v_note := '早押し第' || (s.payload->>'round') || '問';
  if exists (select 1 from score_events where member_id = p_member_id and game = 'buzz' and score_events.note = v_note) then
    raise exception 'この人には既に点を付けています';
  end if;
  insert into score_events (member_id, game, points, note) values (p_member_id, 'buzz', p_points, v_note);
end $$;

-- 総合ランキングを発表する（5秒溜めてから順位が出る）
create or replace function admin_show_ranking(code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  update live_state set scene = 'ranking', updated_at = now(), payload = jsonb_build_object(
    'show_at', to_char((now() + interval '5 seconds') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) where id = 1;
end $$;

-- ビンゴの操作（start: 新しいカードで始める / draw: まだ出ていない番号を1つ引く）
-- 番号はサーバーで引いて足す。運営が素早く続けて押しても、引いた番号が消えない
create or replace function admin_bingo(code text, p_action text) returns int
language plpgsql security definer set search_path = public as $$
declare s live_state; nums jsonb; pick int;
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if p_action = 'start' then
    update live_state set scene = 'bingo', updated_at = now(), payload = jsonb_build_object('seed', (extract(epoch from now()) * 1000)::bigint,
      'numbers', '[]'::jsonb, 'started_at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) where id = 1;
    return null;
  elsif p_action = 'draw' then
    select * into s from live_state where id = 1 for update;
    if s.scene <> 'bingo' then raise exception 'ビンゴの最中ではありません'; end if;
    nums := coalesce(s.payload->'numbers', '[]'::jsonb);
    select n into pick from generate_series(1, 75) n where not nums @> to_jsonb(n) order by random() limit 1;
    if pick is null then raise exception 'すべての番号が出ました'; end if;
    update live_state set updated_at = now(), payload = s.payload || jsonb_build_object('numbers', nums || to_jsonb(pick)) where id = 1;
    return pick;
  end if;
  raise exception '操作が違います: %', p_action;
end $$;

-- クイズの操作（start: 回答を消して1問目から / next: 次の段階へ進める / finish: 結果発表へ）
create or replace function admin_quiz(code text, p_action text) returns void
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  select count(*) into n from quiz_questions;
  if p_action = 'start' then
    if n = 0 then raise exception 'クイズの問題がありません'; end if;
    delete from quiz_answers where true;
    update live_state set scene = 'quiz', updated_at = now(), payload = jsonb_build_object('q', (select min(order_no) from quiz_questions),
      'phase', 'answering', 'total', n, 'started_at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')) where id = 1;
  elsif p_action = 'next' then
    perform _quiz_step(true);
  elsif p_action = 'finish' then
    update live_state set updated_at = now(), payload = payload || jsonb_build_object('phase', 'finished') where id = 1 and scene = 'quiz';
  else
    raise exception '操作が違います: %', p_action;
  end if;
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
  elsif what = 'score' then delete from score_events where true;
  elsif what = 'program' then update program_steps set done = false where true;
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
  delete from score_events where true; update program_steps set done = false where true;
  delete from devices where true; delete from members where true;
  delete from awards where true; delete from reveals where true;
  update live_state set scene = 'idle', payload = '{}', updated_at = now() where id = 1;
end $$;

create or replace function admin_change_passcode(code text, new_code text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  if length(coalesce(new_code, '')) < 12 then raise exception 'パスコードは12文字以上にしてください'; end if;
  update admin_config set passcode_hash = extensions.crypt(new_code, extensions.gen_salt('bf', 10)) where id = 1;
end $$;

-- 開発用：データの中身をまとめて返す（dev/data-viewer.html が使う。運営パスコードが必要）
-- 端末の合鍵の指紋と LINE のユーザー ID は返さない
create or replace function admin_snapshot(code text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin(code) then raise exception 'パスコードが違います'; end if;
  return jsonb_build_object(
    'settings', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from settings t),
    'members', (select coalesce(jsonb_agg(to_jsonb(t) order by t.sort, t.name), '[]') from members t),
    'devices', (select coalesce(jsonb_agg(to_jsonb(t) - 'key_hash' - 'line_user_id' order by t.created_at), '[]') from devices t),
    'awards', (select coalesce(jsonb_agg(to_jsonb(t) order by t.sort), '[]') from awards t),
    'reveals', (select coalesce(jsonb_agg(to_jsonb(t) order by t.sort), '[]') from reveals t),
    'quiz_questions', (select coalesce(jsonb_agg(to_jsonb(t) order by t.order_no), '[]') from quiz_questions t),
    'quiz_answers', (select coalesce(jsonb_agg(to_jsonb(t) order by t.answered_at desc), '[]') from (select * from quiz_answers order by answered_at desc limit 100) t),
    'live_state', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from live_state t),
    'reactions', (select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]') from (select * from reactions order by id desc limit 50) t),
    'buzzes', (select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]') from (select * from buzzes order by id desc limit 50) t),
    'pulse', (select coalesce(jsonb_agg(to_jsonb(t) order by t.topic), '[]') from pulse t),
    'score_events', (select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]') from (select * from score_events order by id desc limit 100) t),
    'program_steps', (select coalesce(jsonb_agg(to_jsonb(t) order by t.sort), '[]') from program_steps t),
    'counts', jsonb_build_object(
      'settings', (select count(*) from settings), 'members', (select count(*) from members), 'devices', (select count(*) from devices),
      'awards', (select count(*) from awards), 'reveals', (select count(*) from reveals), 'quiz_questions', (select count(*) from quiz_questions),
      'quiz_answers', (select count(*) from quiz_answers), 'live_state', (select count(*) from live_state), 'reactions', (select count(*) from reactions),
      'buzzes', (select count(*) from buzzes), 'pulse', (select count(*) from pulse), 'admin_config', (select count(*) from admin_config),
      'score_events', (select count(*) from score_events), 'program_steps', (select count(*) from program_steps)),
    'server_now', now());
end $$;

-- 古い版の関数を片付ける
drop function if exists _quiz_try_advance(int);

-- 内部用の関数は画面から呼べないようにする
revoke execute on function is_admin(text), _key_hash(text), _member(text), _check_view(text), _admin_guard(text, text),
  _quiz_ranking(int), _quiz_step(boolean), _total_ranking(int), _my_score(uuid), set_initial_passcode(text), _bump() from public, anon, authenticated;

-- 承認済みの端末に残っていた LINE の表示名・ユーザー ID を消す（呼び名だけにする方針に合わせる）
update devices set line_name = '', line_user_id = '' where status = 'approved' and (line_name <> '' or line_user_id <> '');
update devices set line_user_id = '' where line_user_id <> '';

-- ===== 仮の中身（運営パネルからいつでも書き換えられる。社員の情報は入れない） =====
insert into quiz_questions (order_no, question_text, choices, correct_index) values
(1, 'サンプル問題1（差し替え予定）', '["選択肢A","選択肢B","選択肢C","選択肢D"]', 0),
(2, 'サンプル問題2（差し替え予定）', '["選択肢A","選択肢B","選択肢C","選択肢D"]', 1),
(3, 'サンプル問題3（差し替え予定）', '["選択肢A","選択肢B","選択肢C","選択肢D"]', 2)
on conflict (order_no) do nothing;
