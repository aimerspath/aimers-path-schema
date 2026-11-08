-- 0009 — get_catalog_overview: graceful null exam (catalogue page needs every
-- live exam's tests when no exam is preselected), plus draft/archived filtering.

create or replace function public.get_catalog_overview(p_exam_id text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'exam', (select row_to_json(e) from exams e where p_exam_id is not null and e.id = p_exam_id),
    'exams', (select coalesce(jsonb_agg(row_to_json(e) order by e.sort_order), '[]'::jsonb) from exams e),
    'subjects', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', s.id, 'exam_id', s.exam_id, 'name_en', s.name_en, 'name_hi', s.name_hi, 'sort_order', s.sort_order,
        'questionCount', (select count(*) from questions q where q.subject_id = s.id)
      ) order by s.sort_order), '[]'::jsonb)
      from subjects s where p_exam_id is null or s.exam_id = p_exam_id),
    'chapters', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'subject_id', c.subject_id, 'name_en', c.name_en, 'name_hi', c.name_hi, 'sort_order', c.sort_order,
        'questionCount', (select count(*) from questions q where q.chapter_id = c.id)
      ) order by c.sort_order), '[]'::jsonb)
      from chapters c where p_exam_id is null or c.exam_id = p_exam_id),
    'tests', (select coalesce(jsonb_agg(row_to_json(t) order by t.sort_order), '[]'::jsonb)
      from tests t
      where t.is_active
        and (p_exam_id is null or t.exam_id = p_exam_id)
        and coalesce(t.status, 'published') not in ('draft', 'archived')),
    'totalQuestions', (select count(*) from questions q
                       where p_exam_id is null or q.exam_id = p_exam_id)
  );
$$;

grant execute on function public.get_catalog_overview(text) to anon, authenticated;

insert into audit_logs (actor, action, table_name, record_id, after_data)
values (auth.uid(), 'MIGRATION', 'schema', '0009',
        jsonb_build_object('name', 'catalog_null_exam_fix'));
