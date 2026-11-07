-- 0007 — answer-key, attempt and privacy hardening
-- Fixes discovered during the end-to-end security review:
--   * premium students could select correct_answer from the base questions table;
--   * any signed-in student could edit their own attempt_sessions row directly
--     (answers, ends_at, finished_at), bypassing the server timer;
--   * the peer_results policy exposed every student's answer sheet;
--   * expired attempts stayed "in progress" and a refresh silently started a new
--     timer instead of finalising the old paper;
--   * result totals used the declared paper size even when fewer questions were
--     actually delivered.
-- Everything below is idempotent and safe to re-run.

-- ── 0. role model used by the policies above ─────────────────────
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('student','admin','super_admin','content_manager','question_editor'));

-- ── 1. question bank: only editors read the base table ────────────
-- public_questions (a filtered view without answer columns) is the student path.
drop policy if exists public_question_read on questions;
drop policy if exists question_admin_read on questions;
create policy question_admin_read on questions for select
  using (public.can_edit_content());

-- ── 2. attempts: students read their row, never write it ─────────
drop policy if exists own_attempts on attempt_sessions;
drop policy if exists own_attempts_read on attempt_sessions;
create policy own_attempts_read on attempt_sessions for select
  using (user_id = auth.uid() or public.is_admin());
revoke insert, update, delete on attempt_sessions from anon, authenticated;

-- ── 3. results: private, peer answers no longer readable ─────────
drop policy if exists peer_results on test_results;
drop policy if exists own_results on test_results;
create policy own_results on test_results for select
  using (user_id = auth.uid() or public.is_admin());
revoke insert, update, delete on test_results from anon, authenticated;

-- ── 4. autosave is server-timed and immutable after submission ───
create or replace function public.save_attempt_progress(p_attempt_id uuid, p_answers jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_attempt attempt_sessions%rowtype;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  select * into v_attempt
  from attempt_sessions
  where id = p_attempt_id and user_id = auth.uid()
  for update;
  if not found then raise exception 'attempt not found'; end if;
  if v_attempt.finished_at is not null or v_attempt.status <> 'in_progress' then
    raise exception 'attempt is already submitted';
  end if;
  if coalesce(v_attempt.ends_at, v_attempt.expires_at) <= now() then
    raise exception 'time is up';
  end if;

  update attempt_sessions
     set answers = coalesce(p_answers, '{}'::jsonb),
         last_saved_at = now()
   where id = p_attempt_id;
end;
$$;

-- ── 5. idempotent, server-scored submission ──────────────────────
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
    if v_attempt.test_id <> p_test_id then
      raise exception 'attempt does not belong to this test';
    end if;

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
    if v_attempt.finished_at is not null then
      raise exception 'attempt is already submitted';
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

  -- The attempt is scored out of the questions actually delivered. This keeps
  -- partial imports honest and becomes the declared total once all questions exist.
  insert into test_results
    (user_id, test_id, exam_id, attempt_id, score, total_marks, correct, wrong, skipped,
     accuracy, time_taken, answers, lang, auto_submitted, per_q,
     marks_per_correct, negative_marking, total_questions)
  values
    (auth.uid(), p_test_id, v_test.exam_id, p_attempt_id,
     round(v_score, 2), round(v_total * v_plus, 2),
     v_correct, v_wrong, v_skipped,
     case when v_correct + v_wrong = 0 then 0
          else round((v_correct::numeric / (v_correct + v_wrong)) * 100)::int end,
     greatest(0, coalesce(p_time_taken, 0)), v_answers, p_lang, v_auto, v_perq,
     v_plus, v_minus, v_total)
  returning id into v_result_id;

  v_result := jsonb_build_object(
    'resultId', v_result_id, 'score', round(v_score, 2),
    'totalMarks', round(v_total * v_plus, 2),
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
            jsonb_build_object('resultId', v_result_id, 'score', round(v_score, 2),
                               'auto', v_auto));
  end if;

  return v_result;
end;
$$;

-- ── 6. resumable attempts + finalise expired papers ──────────────
create or replace function public.start_test_attempt(p_test_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_test   tests%rowtype;
  v_ids    text[];
  v_attempt attempt_sessions%rowtype;
  v_ends   timestamptz;
  v_snap   jsonb;
  v_exp    record;
  v_expired_result jsonb;
  v_last_result uuid;
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

  -- A refresh after time-up must finalise the old paper, not grant a new timer.
  for v_exp in
    select id from attempt_sessions
    where user_id = auth.uid() and test_id = p_test_id
      and finished_at is null and status = 'in_progress'
      and coalesce(ends_at, expires_at) <= now()
  loop
    v_expired_result := public.submit_attempt(p_test_id, v_exp.id, '{}'::jsonb, 0, 'en', true);
    v_last_result := coalesce((v_expired_result->>'resultId')::uuid, v_last_result);
  end loop;

  if v_last_result is not null then
    return jsonb_build_object(
      'expired', true,
      'resultId', v_last_result,
      'test', to_jsonb(v_test) - 'created_at',
      'questions', '[]'::jsonb
    );
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

-- ── 7. privacy-safe leaderboard ─────────────────────────────────
create or replace function public.get_test_leaderboard_rows(p_test_id text, p_limit int default 50)
returns jsonb
language sql stable security definer set search_path = public as $$
  with top_rows as (
    select r.id, r.test_id, r.score, r.accuracy, r.time_taken, r.submitted_at, r.user_id
    from test_results r
    where r.test_id = p_test_id
    order by r.score desc, r.submitted_at asc
    limit greatest(1, least(coalesce(p_limit, 50), 100))
  ),
  mine as (
    select max(score) as score from test_results
    where test_id = p_test_id and user_id = auth.uid()
  )
  select jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', x.id, 'test_id', x.test_id,
        'score', x.score, 'accuracy', x.accuracy, 'time_taken', x.time_taken,
        'submitted_at', x.submitted_at,
        'is_me', x.user_id = auth.uid(),
        'user_name', case when x.user_id = auth.uid() then 'You' else 'Aspirant' end
      ) order by x.score desc, x.submitted_at asc)
      from top_rows x
    ), '[]'::jsonb),
    'total', (select count(*) from test_results where test_id = p_test_id),
    'topScore', (select max(score) from test_results where test_id = p_test_id),
    'myRank', (
      select count(*) + 1 from test_results
      where test_id = p_test_id and score > coalesce((select score from mine), 0)
    ),
    'percentile', (
      select case
        when count(*) > 1 then
          round((count(*) filter (where score < coalesce((select score from mine), 0)))::numeric
                / (count(*) - 1) * 100, 2)
        else 100
      end
      from test_results where test_id = p_test_id
    )
  );
$$;

revoke all on function public.get_test_leaderboard_rows(text, int) from anon;
grant execute on function public.get_test_leaderboard_rows(text, int) to authenticated;

revoke all on function public.save_attempt_progress(uuid, jsonb) from anon;
grant execute on function public.save_attempt_progress(uuid, jsonb) to authenticated;
revoke all on function public.submit_attempt(text, uuid, jsonb, int, text, boolean) from anon;
grant execute on function public.submit_attempt(text, uuid, jsonb, int, text, boolean) to authenticated;
revoke all on function public.start_test_attempt(text) from anon;
grant execute on function public.start_test_attempt(text) to authenticated;

-- Audit trail for the changes above, and keep the vector of admin activity.
insert into audit_logs (actor, action, table_name, record_id, after_data)
values (auth.uid(), 'MIGRATION', 'schema', '0007',
        jsonb_build_object('name', 'answer_key_and_attempt_hardening'));
