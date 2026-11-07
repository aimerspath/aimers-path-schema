-- 0006 — platform hardening + reusable content taxonomy
-- Adds the reusable exam architecture the master brief requires:
--   books / book chapters, topics, exam patterns, test scheduling, question
--   lifecycle + versions, bookmarks, question reports, student question
--   history, attempt events, audit logs.
-- Also makes attempts resumable and submission idempotent, with a
-- server-authoritative timer and a per-attempt configuration snapshot.

create extension if not exists pgcrypto;

-- ── question lifecycle ───────────────────────────────────────────
alter table questions add column if not exists topic_id text;
alter table questions add column if not exists status text not null default 'published';
alter table questions add column if not exists source text;
alter table questions add column if not exists source_ref text;
alter table questions add column if not exists created_by uuid references auth.users(id) on delete set null;
alter table questions add column if not exists updated_by uuid references auth.users(id) on delete set null;
alter table questions add column if not exists updated_at timestamptz not null default now();
alter table questions add column if not exists version int not null default 1;

-- ── test scheduling / configuration ──────────────────────────────
alter table tests add column if not exists book_id text;
alter table tests add column if not exists topic_id text;
alter table tests add column if not exists status text not null default 'published';
alter table tests add column if not exists available_from timestamptz;
alter table tests add column if not exists available_to timestamptz;
alter table tests add column if not exists settings jsonb not null default '{}'::jsonb;
alter table tests add column if not exists updated_at timestamptz not null default now();

-- ── attempt lifecycle ────────────────────────────────────────────
alter table attempt_sessions add column if not exists ends_at timestamptz;
alter table attempt_sessions add column if not exists last_saved_at timestamptz;
alter table attempt_sessions add column if not exists status text not null default 'in_progress';
alter table attempt_sessions add column if not exists snapshot jsonb not null default '{}'::jsonb;
alter table attempt_sessions add column if not exists submitted_result_id uuid;

-- ── result provenance ────────────────────────────────────────────
alter table test_results add column if not exists attempt_id uuid;
alter table test_results add column if not exists per_q jsonb not null default '{}'::jsonb;
alter table test_results add column if not exists marks_per_correct numeric(6,2);
alter table test_results add column if not exists negative_marking numeric(6,2);
alter table test_results add column if not exists total_questions int;
create unique index if not exists results_attempt_uidx on test_results (attempt_id) where attempt_id is not null;

-- ── reusable taxonomy ────────────────────────────────────────────
create table if not exists books (
  id             text primary key,
  exam_id        text not null references exams(id) on delete cascade,
  subject_id     text references subjects(id) on delete set null,
  name_en        text not null,
  name_hi        text,
  author         text,
  publisher      text,
  description_en text,
  description_hi text,
  cover_url      text,
  sort_order     int not null default 0,
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists book_chapters (
  id          text primary key,
  book_id     text not null references books(id) on delete cascade,
  parent_id   text references book_chapters(id) on delete cascade,
  chapter_no  text,
  name_en     text not null,
  name_hi     text,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists topics (
  id          text primary key,
  exam_id     text not null references exams(id) on delete cascade,
  subject_id  text references subjects(id) on delete set null,
  parent_id   text references topics(id) on delete cascade,
  name_en     text not null,
  name_hi     text,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

alter table questions drop constraint if exists questions_topic_fk;
alter table questions add constraint questions_topic_fk
  foreign key (topic_id) references topics(id) on delete set null;
alter table tests drop constraint if exists tests_book_fk;
alter table tests add constraint tests_book_fk
  foreign key (book_id) references books(id) on delete set null;
alter table tests drop constraint if exists tests_topic_fk;
alter table tests add constraint tests_topic_fk
  foreign key (topic_id) references topics(id) on delete set null;

create table if not exists book_chapter_tests (
  test_id    text primary key references tests(id) on delete cascade,
  chapter_id text not null references book_chapters(id) on delete cascade
);

create table if not exists test_sections (
  id             text primary key,
  test_id        text not null references tests(id) on delete cascade,
  name_en        text not null,
  name_hi        text,
  question_count int,
  sort_order     int not null default 0
);

create table if not exists exam_patterns (
  id               uuid primary key default gen_random_uuid(),
  exam_id          text not null references exams(id) on delete cascade,
  version          int not null default 1,
  effective_from   date not null default current_date,
  duration_minutes int not null,
  total_questions  int not null,
  options_count    int not null default 4,
  marks_per_correct numeric(6,2) not null default 1,
  negative_marking numeric(6,2) not null default 0,
  sections         jsonb not null default '[]'::jsonb,
  is_current       boolean not null default false,
  created_at       timestamptz not null default now(),
  unique (exam_id, version)
);

-- ── student data ─────────────────────────────────────────────────
create table if not exists bookmarks (
  user_id     uuid not null references auth.users(id) on delete cascade,
  question_id text not null references questions(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, question_id)
);

create table if not exists student_question_history (
  user_id     uuid not null references auth.users(id) on delete cascade,
  question_id text not null references questions(id) on delete cascade,
  seen        int not null default 0,
  correct     int not null default 0,
  wrong       int not null default 0,
  last_answer text,
  last_result text,
  last_seen_at timestamptz not null default now(),
  primary key (user_id, question_id)
);

create table if not exists question_reports (
  id              uuid primary key default gen_random_uuid(),
  question_id     text not null references questions(id) on delete cascade,
  user_id         uuid references auth.users(id) on delete set null,
  report_type     text not null default 'answer_wrong',
  message         text,
  status          text not null default 'open',
  resolution_note text,
  reviewed_by     uuid references auth.users(id) on delete set null,
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz
);

create table if not exists question_versions (
  id           uuid primary key default gen_random_uuid(),
  question_id  text not null references questions(id) on delete cascade,
  version      int not null,
  snapshot     jsonb not null,
  changed_by   uuid references auth.users(id) on delete set null,
  change_reason text,
  created_at   timestamptz not null default now(),
  unique (question_id, version)
);

create table if not exists attempt_events (
  id         bigint generated always as identity primary key,
  attempt_id uuid references attempt_sessions(id) on delete cascade,
  user_id    uuid references auth.users(id) on delete cascade,
  event      text not null,
  payload    jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists audit_logs (
  id          bigint generated always as identity primary key,
  actor       uuid references auth.users(id) on delete set null,
  action      text not null,
  table_name  text,
  record_id   text,
  before_data jsonb,
  after_data  jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists questions_topic_idx on questions (topic_id);
create index if not exists questions_status_idx on questions (status);
create index if not exists tests_book_idx on tests (book_id);
create index if not exists tests_topic_idx on tests (topic_id);
create index if not exists attempts_user_test_idx on attempt_sessions (user_id, test_id, started_at desc);
create index if not exists attempt_events_idx on attempt_events (attempt_id, created_at);
create index if not exists history_user_idx on student_question_history (user_id, last_seen_at desc);
create index if not exists reports_status_idx on question_reports (status, created_at);

-- ── role helpers ─────────────────────────────────────────────────
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('admin','super_admin') from profiles where id = auth.uid()), false);
$$;

create or replace function public.can_edit_content()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('admin','super_admin','content_manager','question_editor') from profiles where id = auth.uid()), false);
$$;

-- ── updated_at + question versioning + audit ─────────────────────
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists books_touch on books;
create trigger books_touch before update on books for each row execute function public.touch_updated_at();
drop trigger if exists tests_touch on tests;
create trigger tests_touch before update on tests for each row execute function public.touch_updated_at();

create or replace function public.questions_before_update()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into question_versions (question_id, version, snapshot, changed_by)
  values (old.id, coalesce(old.version, 1), to_jsonb(old), auth.uid())
  on conflict (question_id, version) do nothing;
  new.version := coalesce(old.version, 1) + 1;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end;
$$;

drop trigger if exists questions_version_trg on questions;
create trigger questions_version_trg before update on questions
for each row execute function public.questions_before_update();

create or replace function public.audit_row()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_id text;
begin
  v_id := coalesce((case when tg_op = 'DELETE' then old.id else new.id end)::text, null);
  insert into audit_logs (actor, action, table_name, record_id, before_data, after_data)
  values (auth.uid(), tg_op, tg_table_name, v_id,
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end);
  return coalesce(new, old);
end;
$$;

drop trigger if exists questions_audit on questions;
create trigger questions_audit after insert or update or delete on questions
for each row execute function public.audit_row();
drop trigger if exists tests_audit on tests;
create trigger tests_audit after insert or update or delete on tests
for each row execute function public.audit_row();
drop trigger if exists books_audit on books;
create trigger books_audit after insert or update or delete on books
for each row execute function public.audit_row();

-- ── public catalogue view: only published questions ──────────────
create or replace view public.public_questions as
select q.id, q.exam_id, q.subject_id, q.chapter_id,
       q.question_en, q.question_hi,
       q.option_a_en, q.option_a_hi, q.option_b_en, q.option_b_hi,
       q.option_c_en, q.option_c_hi, q.option_d_en, q.option_d_hi,
       q.option_e_en, q.option_e_hi,
       q.difficulty, q.is_pyq, q.pyq_exam_name, q.pyq_year, q.topic, q.sort_order
from questions q
where q.status = 'published';

-- ── RLS for the new tables ───────────────────────────────────────
alter table books                     enable row level security;
alter table book_chapters             enable row level security;
alter table topics                    enable row level security;
alter table book_chapter_tests        enable row level security;
alter table test_sections             enable row level security;
alter table exam_patterns             enable row level security;
alter table bookmarks                 enable row level security;
alter table student_question_history  enable row level security;
alter table question_reports          enable row level security;
alter table question_versions         enable row level security;
alter table attempt_events            enable row level security;
alter table audit_logs                enable row level security;

drop policy if exists catalogue_read on books;
create policy catalogue_read on books for select using (true);
drop policy if exists content_write on books;
create policy content_write on books for all using (public.can_edit_content()) with check (public.can_edit_content());

drop policy if exists catalogue_read on book_chapters;
create policy catalogue_read on book_chapters for select using (true);
drop policy if exists content_write on book_chapters;
create policy content_write on book_chapters for all using (public.can_edit_content()) with check (public.can_edit_content());

drop policy if exists catalogue_read on topics;
create policy catalogue_read on topics for select using (true);
drop policy if exists content_write on topics;
create policy content_write on topics for all using (public.can_edit_content()) with check (public.can_edit_content());

drop policy if exists catalogue_read on book_chapter_tests;
create policy catalogue_read on book_chapter_tests for select using (true);
drop policy if exists content_write on book_chapter_tests;
create policy content_write on book_chapter_tests for all using (public.can_edit_content()) with check (public.can_edit_content());

drop policy if exists catalogue_read on test_sections;
create policy catalogue_read on test_sections for select using (true);
drop policy if exists content_write on test_sections;
create policy content_write on test_sections for all using (public.can_edit_content()) with check (public.can_edit_content());

drop policy if exists catalogue_read on exam_patterns;
create policy catalogue_read on exam_patterns for select using (true);
drop policy if exists content_write on exam_patterns;
create policy content_write on exam_patterns for all using (public.can_edit_content()) with check (public.can_edit_content());

drop policy if exists own_bookmarks on bookmarks;
create policy own_bookmarks on bookmarks for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists own_history on student_question_history;
create policy own_history on student_question_history for select using (user_id = auth.uid());

drop policy if exists own_reports on question_reports;
create policy own_reports on question_reports for select using (user_id = auth.uid() or public.can_edit_content());
drop policy if exists insert_reports on question_reports;
create policy insert_reports on question_reports for insert with check (user_id = auth.uid());
drop policy if exists review_reports on question_reports;
create policy review_reports on question_reports for update using (public.can_edit_content()) with check (public.can_edit_content());

drop policy if exists read_versions on question_versions;
create policy read_versions on question_versions for select using (public.can_edit_content());

drop policy if exists own_events on attempt_events;
create policy own_events on attempt_events for select using (user_id = auth.uid() or public.is_admin());

drop policy if exists admin_audit on audit_logs;
create policy admin_audit on audit_logs for select using (public.is_admin());

-- Content editors may edit the question bank even if they are not full admins.
drop policy if exists content_editor_write on questions;
create policy content_editor_write on questions for all
  using (public.can_edit_content()) with check (public.can_edit_content());

grant select on books, book_chapters, topics, book_chapter_tests, test_sections, exam_patterns
  to anon, authenticated;

-- ── resumable, server-timed attempts ─────────────────────────────
create or replace function public.start_test_attempt(p_test_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_test   tests%rowtype;
  v_ids    text[];
  v_attempt attempt_sessions%rowtype;
  v_ends   timestamptz;
  v_snap   jsonb;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  select * into v_test from tests where id = p_test_id and is_active;
  if not found then raise exception 'test not found'; end if;
  if v_test.status in ('draft','archived') then raise exception 'test not available'; end if;
  if v_test.available_from is not null and now() < v_test.available_from then
    raise exception 'test has not started';
  end if;
  if v_test.available_to is not null and now() > v_test.available_to then
    raise exception 'test window is closed';
  end if;
  if not v_test.is_free and not public.has_active_subscription() then
    raise exception 'subscription required';
  end if;

  -- Resume an unfinished attempt; the server is the source of truth.
  select * into v_attempt
  from attempt_sessions
  where user_id = auth.uid() and test_id = p_test_id
    and finished_at is null and status = 'in_progress'
    and coalesce(ends_at, expires_at) > now()
  order by started_at desc
  limit 1;

  if found then
    insert into attempt_events (attempt_id, user_id, event)
    values (v_attempt.id, auth.uid(), 'resumed');
    return jsonb_build_object(
      'attemptId', v_attempt.id,
      'resumed', true,
      'answers', v_attempt.answers,
      'endsAt', coalesce(v_attempt.ends_at, v_attempt.expires_at),
      'serverNow', now(),
      'test', to_jsonb(v_test) - 'created_at',
      'questions', (
        select coalesce(jsonb_agg(row_to_json(pq) order by x.idx), '[]'::jsonb)
        from unnest(v_attempt.question_ids) with ordinality as x(qid, idx)
        join public_questions pq on pq.id = x.qid
      )
    );
  end if;

  select array_agg(x.qid order by x.idx) into v_ids from (
    select tq.question_id as qid, tq.sort_order as idx
    from test_questions tq where tq.test_id = p_test_id
  ) x;

  if v_ids is null then
    select array_agg(q.id order by random()) into v_ids from (
      select id from questions
      where exam_id = v_test.exam_id
        and status = 'published'
        and (v_test.subject_id is null or subject_id = v_test.subject_id)
        and (v_test.chapter_id is null or chapter_id = v_test.chapter_id)
        and (v_test.type <> 'pyq' or is_pyq)
      limit least(v_test.total_questions, 500)
    ) q;
  end if;

  if v_ids is null then raise exception 'no questions available'; end if;

  v_ends := now() + make_interval(mins => v_test.duration_minutes);
  v_snap := jsonb_build_object(
    'title', v_test.title,
    'durationMinutes', v_test.duration_minutes,
    'totalMarks', v_test.total_marks,
    'totalQuestions', v_test.total_questions,
    'marksPerCorrect', coalesce(v_test.marks_per_correct, 1),
    'negativeMarking', coalesce(v_test.negative_marking, 0)
  );

  insert into attempt_sessions (user_id, test_id, question_ids, answers,
                                expires_at, ends_at, status, snapshot)
  values (auth.uid(), p_test_id, v_ids, '{}'::jsonb,
          v_ends + interval '15 minutes', v_ends, 'in_progress', v_snap)
  returning * into v_attempt;

  insert into attempt_events (attempt_id, user_id, event, payload)
  values (v_attempt.id, auth.uid(), 'started',
          jsonb_build_object('questions', coalesce(array_length(v_ids, 1), 0)));

  return jsonb_build_object(
    'attemptId', v_attempt.id,
    'resumed', false,
    'answers', '{}'::jsonb,
    'endsAt', v_ends,
    'serverNow', now(),
    'test', to_jsonb(v_test) - 'created_at',
    'questions', (
      select coalesce(jsonb_agg(row_to_json(pq) order by x.idx), '[]'::jsonb)
      from unnest(v_ids) with ordinality as x(qid, idx)
      join public_questions pq on pq.id = x.qid
    )
  );
end;
$$;

-- ── autosave ─────────────────────────────────────────────────────
create or replace function public.save_attempt_progress(p_attempt_id uuid, p_answers jsonb)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  update attempt_sessions
     set answers = coalesce(p_answers, '{}'::jsonb),
         last_saved_at = now()
   where id = p_attempt_id
     and user_id = auth.uid()
     and finished_at is null
     and status = 'in_progress';
end;
$$;

-- ── idempotent, server-scored submission ─────────────────────────
create or replace function public.submit_attempt(
  p_test_id text, p_attempt_id uuid, p_answers jsonb,
  p_time_taken int default 0, p_lang text default 'en', p_auto_submitted boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_test   tests%rowtype;
  v_exam   exams%rowtype;
  v_attempt attempt_sessions%rowtype;
  v_plus   numeric;
  v_minus  numeric;
  v_ids    text[];
  v_row    record;
  v_perq   jsonb := '{}'::jsonb;
  v_score  numeric := 0;
  v_correct int := 0;
  v_wrong  int := 0;
  v_skipped int := 0;
  v_total  int := 0;
  v_result jsonb;
  v_res    text;
  v_answers jsonb;
  v_auto   boolean;
  v_result_id uuid;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  select * into v_test from tests where id = p_test_id;
  if not found then raise exception 'test not found'; end if;
  select * into v_exam from exams where id = v_test.exam_id;

  if p_attempt_id is not null then
    select * into v_attempt from attempt_sessions
    where id = p_attempt_id and user_id = auth.uid()
    for update;
    if not found then raise exception 'attempt not found'; end if;

    -- Idempotency: a retried submit returns the first stored result.
    if v_attempt.submitted_result_id is not null then
      select jsonb_build_object(
        'resultId', r.id, 'score', r.score, 'totalMarks', r.total_marks,
        'correct', r.correct, 'wrong', r.wrong, 'skipped', r.skipped,
        'accuracy', r.accuracy, 'totalQuestions', coalesce(r.total_questions, 0),
        'attempted', r.correct + r.wrong,
        'marksPerCorrect', r.marks_per_correct,
        'negative', r.negative_marking, 'perQ', r.per_q,
        'attemptId', p_attempt_id, 'idempotent', true
      ) into v_result
      from test_results r where r.id = v_attempt.submitted_result_id;
      return v_result;
    end if;

    v_ids := v_attempt.question_ids;
    v_answers := coalesce(v_attempt.answers, '{}'::jsonb) || coalesce(p_answers, '{}'::jsonb);

    if v_attempt.snapshot ? 'marksPerCorrect' then
      v_plus := (v_attempt.snapshot->>'marksPerCorrect')::numeric;
      v_minus := coalesce((v_attempt.snapshot->>'negativeMarking')::numeric, 0);
    end if;
  else
    select array_agg(question_id order by sort_order) into v_ids
      from test_questions where test_id = p_test_id;
    v_answers := coalesce(p_answers, '{}'::jsonb);
  end if;

  v_plus  := coalesce(v_plus, v_test.marks_per_correct, v_exam.marks_per_correct, 1);
  v_minus := coalesce(v_minus, v_test.negative_marking, v_exam.negative_marking,
             case when coalesce(v_exam.options_count, 4) = 5 then 0
                  else round(v_plus / 3, 2) end);

  if v_ids is null then raise exception 'no questions to grade'; end if;

  v_auto := p_auto_submitted
    or (v_attempt.ends_at is not null and now() > v_attempt.ends_at);

  for v_row in
    select q.id, q.correct_answer, v_answers->>q.id as chosen
    from questions q where q.id = any (v_ids)
  loop
    v_total := v_total + 1;
    if v_row.chosen is null or v_row.chosen = '' or v_row.chosen = 'e' then
      v_res := 'unattempted'; v_skipped := v_skipped + 1;
    elsif v_row.chosen = v_row.correct_answer then
      v_res := 'correct'; v_correct := v_correct + 1; v_score := v_score + v_plus;
    else
      v_res := 'wrong'; v_wrong := v_wrong + 1; v_score := v_score - v_minus;
    end if;
    v_perq := v_perq || jsonb_build_object(
      v_row.id, jsonb_build_object('res', v_res, 'a', v_row.chosen, 'correct', v_row.correct_answer)
    );

    insert into student_question_history
      (user_id, question_id, seen, correct, wrong, last_answer, last_result, last_seen_at)
    values (
      auth.uid(), v_row.id, 1,
      case when v_res = 'correct' then 1 else 0 end,
      case when v_res = 'wrong' then 1 else 0 end,
      v_row.chosen, v_res, now()
    )
    on conflict (user_id, question_id) do update set
      seen = student_question_history.seen + 1,
      correct = student_question_history.correct + case when v_res = 'correct' then 1 else 0 end,
      wrong = student_question_history.wrong + case when v_res = 'wrong' then 1 else 0 end,
      last_answer = excluded.last_answer,
      last_result = excluded.last_result,
      last_seen_at = now();
  end loop;

  insert into test_results
    (user_id, test_id, exam_id, attempt_id, score, total_marks, correct, wrong, skipped,
     accuracy, time_taken, answers, lang, auto_submitted, per_q,
     marks_per_correct, negative_marking, total_questions)
  values
    (auth.uid(), p_test_id, v_test.exam_id, p_attempt_id, round(v_score, 2), v_test.total_marks,
     v_correct, v_wrong, v_skipped,
     case when v_correct + v_wrong = 0 then 0
          else round((v_correct::numeric / (v_correct + v_wrong)) * 100)::int end,
     p_time_taken, v_answers, p_lang, v_auto, v_perq,
     v_plus, v_minus, v_total)
  returning id into v_result_id;

  v_result := jsonb_build_object(
    'resultId', v_result_id, 'score', round(v_score, 2), 'totalMarks', v_test.total_marks,
    'correct', v_correct, 'wrong', v_wrong, 'skipped', v_skipped,
    'accuracy', case when v_correct + v_wrong = 0 then 0
                     else round((v_correct::numeric / (v_correct + v_wrong)) * 100)::int end,
    'totalQuestions', v_total, 'attempted', v_correct + v_wrong,
    'marksPerCorrect', v_plus, 'negative', v_minus,
    'perQ', v_perq, 'attemptId', p_attempt_id, 'autoSubmitted', v_auto, 'idempotent', false
  );

  update tests set
    attempts_count = attempts_count + 1,
    avg_score = round(((avg_score * greatest(attempts_count, 1)) + round(v_score, 2))
                      / (greatest(attempts_count, 1) + 1), 2)
  where id = p_test_id;

  if p_attempt_id is not null then
    update attempt_sessions
       set finished_at = now(), status = 'submitted',
           submitted_result_id = v_result_id,
           answers = v_answers
     where id = p_attempt_id and user_id = auth.uid();
    insert into attempt_events (attempt_id, user_id, event, payload)
    values (p_attempt_id, auth.uid(), 'submitted',
            jsonb_build_object('resultId', v_result_id, 'score', round(v_score, 2)));
  end if;

  return v_result;
end;
$$;

-- ── result read paths (server-authoritative) ─────────────────────
create or replace function public.get_my_result(p_attempt_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'resultId', r.id, 'testId', r.test_id, 'score', r.score,
    'totalMarks', r.total_marks, 'correct', r.correct, 'wrong', r.wrong,
    'skipped', r.skipped, 'accuracy', r.accuracy, 'timeTaken', r.time_taken,
    'answers', r.answers, 'perQ', r.per_q, 'lang', r.lang,
    'autoSubmitted', r.auto_submitted, 'submittedAt', r.submitted_at,
    'marksPerCorrect', r.marks_per_correct, 'negative', r.negative_marking,
    'totalQuestions', r.total_questions, 'attemptId', r.attempt_id
  )
  from test_results r
  where r.attempt_id = p_attempt_id and r.user_id = auth.uid();
$$;

create or replace function public.get_latest_result(p_test_id text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'resultId', r.id, 'testId', r.test_id, 'score', r.score,
    'totalMarks', r.total_marks, 'correct', r.correct, 'wrong', r.wrong,
    'skipped', r.skipped, 'accuracy', r.accuracy, 'timeTaken', r.time_taken,
    'answers', r.answers, 'perQ', r.per_q, 'lang', r.lang,
    'autoSubmitted', r.auto_submitted, 'submittedAt', r.submitted_at,
    'marksPerCorrect', r.marks_per_correct, 'negative', r.negative_marking,
    'totalQuestions', r.total_questions, 'attemptId', r.attempt_id
  )
  from test_results r
  where r.test_id = p_test_id and r.user_id = auth.uid()
  order by r.submitted_at desc
  limit 1;
$$;

-- ── small student helpers ────────────────────────────────────────
create or replace function public.toggle_bookmark(p_question_id text, p_on boolean default true)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  if p_on then
    insert into bookmarks (user_id, question_id) values (auth.uid(), p_question_id)
    on conflict (user_id, question_id) do nothing;
  else
    delete from bookmarks where user_id = auth.uid() and question_id = p_question_id;
  end if;
  return p_on;
end;
$$;

create or replace function public.get_my_bookmarks()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'saved_at', b.created_at, 'question', row_to_json(pq)
  ) order by b.created_at desc), '[]'::jsonb)
  from bookmarks b
  join public_questions pq on pq.id = b.question_id
  where b.user_id = auth.uid();
$$;

create or replace function public.report_question(
  p_question_id text, p_report_type text default 'answer_wrong', p_message text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  insert into question_reports (question_id, user_id, report_type, message)
  values (p_question_id, auth.uid(),
          case when p_report_type in ('answer_wrong','duplicate','typo','explanation','other')
               then p_report_type else 'other' end,
          p_message)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.get_weak_topics(p_limit int default 10)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(row_to_json(t) order by t.wrong desc), '[]'::jsonb)
  from (
    select coalesce(q.topic, 'General') as topic,
           sum(h.wrong)::int as wrong,
           sum(h.correct)::int as correct,
           sum(h.seen)::int as seen
    from student_question_history h
    join questions q on q.id = h.question_id
    where h.user_id = auth.uid()
    group by coalesce(q.topic, 'General')
    having sum(h.wrong) > 0
    order by sum(h.wrong) desc
    limit greatest(1, least(p_limit, 50))
  ) t;
$$;

-- ── fix solutions: use the attempt snapshot, not array_agg(array) ─
create or replace function public.get_test_solutions(p_test_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ids text[];
begin
  if auth.uid() is null then return '{}'::jsonb; end if;
  if not exists (select 1 from test_results where test_id = p_test_id and user_id = auth.uid()) then
    return jsonb_build_object('error', 'attempt the test to see solutions');
  end if;
  select array_agg(question_id order by sort_order) into v_ids
    from test_questions where test_id = p_test_id;
  if v_ids is null then
    select r.question_ids into v_ids
    from attempt_sessions r
    where r.test_id = p_test_id and r.user_id = auth.uid()
    order by r.started_at desc limit 1;
  end if;
  return jsonb_build_object(
    'questions', (
      select coalesce(jsonb_agg(row_to_json(q) order by x.idx), '[]'::jsonb)
      from unnest(v_ids) with ordinality as x(qid, idx)
      join questions q on q.id = x.qid
    )
  );
end;
$$;

revoke all on function public.start_test_attempt(text) from anon;
revoke all on function public.submit_attempt(text, uuid, jsonb, int, text, boolean) from anon;
revoke all on function public.get_my_result(uuid) from anon;
revoke all on function public.get_latest_result(text) from anon;
grant execute on function public.start_test_attempt(text) to authenticated;
grant execute on function public.submit_attempt(text, uuid, jsonb, int, text, boolean) to authenticated;
grant execute on function public.get_my_result(uuid) to authenticated;
grant execute on function public.get_latest_result(text) to authenticated;
