-- 0008 — full test series: taxonomy, books, category tests, PYQ-trend tests,
--        topic practice and revision practice.
--
-- The fresh /tests hub has NINE per-exam categories:
--   PYQ | PYQ Trends MCQs | Book-wise | Full Mock | Subject-wise | Topic-wise
--   | Bihar Special | Current Affairs | Practice & Revision
--
-- What this migration adds for the live BPSC exam:
--   * 19 chapters that group the 114 real topics the bank already has
--   * a `topics` row per distinct (subject, topic), with questions.topic_id set
--   * 7 companion books mapped to real content via book_chapter_tests
--   * 5 subject tests, 18 chapter tests (3 of them tagged Bihar), a Bihar
--     Special grand test, a Current Affairs test and 3 PYQ-Trend MCQ tests.
--     Subject/chapter/CA/Bihar quizzes pull their questions dynamically from
--     the pool, so every attempt gets a fresh mix without maintaining
--     test_questions rows. PYQ-trend tests are curated (high-frequency BPSC
--     themes) and ARE linked through test_questions.
--   * RPCs: start_topic_practice, start_revision_practice, get_topic_overview
--     — practice sets stay device-only and never touch answer keys on the wire.
--   * PYQ stays an honest empty state: is_pyq is false for the whole bank, so
--     no fake "previous paper" tests are seeded until genuine papers are
--     imported.
-- Everything is idempotent and safe to re-run.

create extension if not exists pgcrypto;

-- ── 0. helpers ───────────────────────────────────────────────────
create or replace function public.slugify(p_text text)
returns text
language sql immutable as $$
  select nullif(regexp_replace(
           regexp_replace(trim(coalesce(p_text, '')), '[^a-zA-Z0-9]+', '-', 'g'),
           '(^-|-$)', '', 'g'),
         '');
$$;

create or replace function public.topic_id_for(p_subject_id text, p_topic text)
returns text
language sql immutable as $$
  select 'topic-' || replace(coalesce(p_subject_id, 'general'), 'sub-', '') || '-' || public.slugify(p_topic);
$$;

-- ── 1. allow the new test types ──────────────────────────────────
-- "pyq_trends" = MCQs written to the recurring BPSC theme/pattern of previous
-- years (original questions, never a claim of an official paper).
alter table tests drop constraint if exists tests_type_check;
alter table tests add constraint tests_type_check
  check (type in ('full','pyq','pyq_trends','subject','chapter','ncert','ca'));

-- ── 2. chapters: 19 curated groups over the live bank ────────────
insert into chapters (id, exam_id, subject_id, name_en, name_hi, sort_order) values
  ('ch-hist-ancient',  'exam-bpsc-001', 'sub-hist',   'Ancient India',                       'प्राचीन भारत', 1),
  ('ch-hist-medieval', 'exam-bpsc-001', 'sub-hist',   'Medieval India',                      'मध्यकालीन भारत', 2),
  ('ch-hist-modern',   'exam-bpsc-001', 'sub-hist',   'Modern India & Freedom Struggle',     'आधुनिक भारत एवं स्वतंत्रता संघर्ष', 3),
  ('ch-geo-physical',  'exam-bpsc-001', 'sub-geo',    'Physical & World Geography',          'भौतिक एवं विश्व भूगोल', 4),
  ('ch-geo-india',     'exam-bpsc-001', 'sub-geo',    'Geography of India',                  'भारत का भूगोल', 5),
  ('ch-geo-bihar',     'exam-bpsc-001', 'sub-geo',    'Geography of Bihar',                  'बिहार का भूगोल', 6),
  ('ch-pol-constitution','exam-bpsc-001','sub-polity','Constitutional Foundation',           'संवैधानिक आधार', 7),
  ('ch-pol-executive', 'exam-bpsc-001', 'sub-polity', 'Executive & Legislature',             'कार्यपालिका एवं विधायिका', 8),
  ('ch-pol-judiciary', 'exam-bpsc-001', 'sub-polity', 'Judiciary, Federalism & Local Governance','न्यायपालिका, संघवाद एवं स्थानीय शासन', 9),
  ('ch-econ-macro',    'exam-bpsc-001', 'sub-econ',   'Money, Banking & Public Finance',     'मुद्रा, बैंकिंग एवं लोक वित्त', 10),
  ('ch-econ-growth',   'exam-bpsc-001', 'sub-econ',   'Growth, Planning & Welfare',          'विकास, योजना एवं कल्याण', 11),
  ('ch-econ-external', 'exam-bpsc-001', 'sub-econ',   'External Sector & Bihar Economy',     'विदेशी क्षेत्र एवं बिहार अर्थव्यवस्था', 12),
  ('ch-sci-physics',   'exam-bpsc-001', 'sub-sci',    'Physics',                             'भौतिक विज्ञान', 13),
  ('ch-sci-chem',      'exam-bpsc-001', 'sub-sci',    'Chemistry',                           'रसायन विज्ञान', 14),
  ('ch-sci-bio',       'exam-bpsc-001', 'sub-sci',    'Biology & Environment',               'जीव विज्ञान एवं पर्यावरण', 15),
  ('ch-bihar-heritage','exam-bpsc-001', 'sub-bihar',  'Heritage of Bihar',                   'बिहार की विरासत', 16),
  ('ch-bihar-freedom', 'exam-bpsc-001', 'sub-bihar',  'Freedom Movement in Bihar',           'बिहार में स्वतंत्रता आंदोलन', 17),
  ('ch-bihar-today',   'exam-bpsc-001', 'sub-bihar',  'Bihar Today: Geography & Schemes',    'आज का बिहार: भूगोल एवं योजनाएँ', 18),
  ('ch-ca-current',    'exam-bpsc-001', 'sub-ca',     'Current Affairs',                     'समकालीन घटनाएँ', 19)
on conflict (id) do update set
  exam_id     = excluded.exam_id,
  subject_id  = excluded.subject_id,
  name_en     = excluded.name_en,
  name_hi     = excluded.name_hi,
  sort_order  = excluded.sort_order;

-- ── 3. topics: one row per distinct (subject, topic) in the bank ─
insert into topics (id, exam_id, subject_id, name_en, sort_order)
select distinct on (q.subject_id, q.topic)
       public.topic_id_for(q.subject_id, q.topic),
       q.exam_id, q.subject_id, q.topic,
       row_number() over () -- placeholder order, refined below
from questions q
where q.topic is not null and q.topic <> ''
on conflict (id) do update set name_en = excluded.name_en;

update topics t
set sort_order = x.rn
from (
  select t2.id, row_number() over (partition by t2.subject_id order by t2.name_en) as rn
  from topics t2
) x
where x.id = t.id;

-- ── 4. link questions to their topic and chapter ─────────────────
update questions q
set topic_id = public.topic_id_for(q.subject_id, q.topic)
where q.topic is not null and q.topic <> ''
  and q.topic_id is distinct from public.topic_id_for(q.subject_id, q.topic);

update questions set chapter_id = 'ch-hist-ancient'
 where subject_id = 'sub-hist' and topic in ('Harappan Civilisation','Vedic Age','Buddhism','Jainism','Magadha','Mauryan Empire','Mauryan Art','Gupta Age','Post-Gupta Period');
update questions set chapter_id = 'ch-hist-medieval'
 where subject_id = 'sub-hist' and topic in ('South Indian Dynasties','Chola Empire','Vijayanagara Empire','Bahmani Kingdom','Delhi Sultanate','Sur Dynasty','Mughal Empire','Maratha Empire','Sikhism','Bhakti-Sufi Tradition');
update questions set chapter_id = 'ch-hist-modern'
 where subject_id = 'sub-hist' and topic in ('Revolt of 1857','Foundation of Congress','Moderates and Extremists','Revolutionary Movement','Non-Cooperation Movement','Civil Disobedience Movement','Quit India Movement','Partition of India','Integration of Princely States','Constituent Assembly');

update questions set chapter_id = 'ch-geo-physical'
 where subject_id = 'sub-geo' and topic in ('Latitude and Longitude','Continents','Oceans','Oceanography','World Straits','Rocks','River Landforms','Planetary Winds','Local Winds','Atmosphere');
update questions set chapter_id = 'ch-geo-india'
 where subject_id = 'sub-geo' and topic in ('Indian Rivers','Indian Monsoon','Soils of India','Indian Agriculture','Minerals of India','Transport in India','Mountain Passes');
update questions set chapter_id = 'ch-geo-bihar'
 where subject_id = 'sub-geo' and topic in ('Bihar Rivers','Bihar Drainage','Bihar Physiography');

update questions set chapter_id = 'ch-pol-constitution'
 where subject_id = 'sub-polity' and topic in ('Constitution Making','Sources of Constitution','Preamble','Fundamental Rights','Fundamental Duties','Directive Principles');
update questions set chapter_id = 'ch-pol-executive'
 where subject_id = 'sub-polity' and topic in ('President','Prime Minister and Cabinet','Parliament','Governor','Legislative Process');
update questions set chapter_id = 'ch-pol-judiciary'
 where subject_id = 'sub-polity' and topic in ('Supreme Court','High Courts','Federalism','Emergency Provisions','Constitutional Bodies','Panchayati Raj');

update questions set chapter_id = 'ch-econ-macro'
 where subject_id = 'sub-econ' and topic in ('National Income','Inflation','Monetary Policy','Banking','Financial Markets','Public Budget','Taxation');
update questions set chapter_id = 'ch-econ-growth'
 where subject_id = 'sub-econ' and topic in ('Planning and NITI Aayog','Central Schemes','Poverty','Unemployment','Agriculture and MSP');
update questions set chapter_id = 'ch-econ-external'
 where subject_id = 'sub-econ' and topic in ('Balance of Payments','Foreign Trade','Bihar Economy');

update questions set chapter_id = 'ch-sci-physics'
 where subject_id = 'sub-sci' and topic in ('Units and Measurement','Motion','Light','Electricity','Space','Space Technology');
update questions set chapter_id = 'ch-sci-chem'
 where subject_id = 'sub-sci' and topic in ('Atomic Structure','Acids and Bases','Metals and Corrosion','Everyday Chemistry');
update questions set chapter_id = 'ch-sci-bio'
 where subject_id = 'sub-sci' and topic in ('Human Body','Cell Biology','Nutrition','Plant Biology','Diseases','Environment','Atmosphere');

update questions set chapter_id = 'ch-bihar-heritage'
 where subject_id = 'sub-bihar' and topic in ('Vaishali','Nalanda','Vikramashila','Bodh Gaya','Pawapuri','Madhubani Painting','Chhath Puja','Sonepur Fair');
update questions set chapter_id = 'ch-bihar-freedom'
 where subject_id = 'sub-bihar' and topic in ('Revolt of 1857 in Bihar','Champaran Satyagraha','Quit India Movement');
update questions set chapter_id = 'ch-bihar-today'
 where subject_id = 'sub-bihar' and topic in ('Kosi River','Mahatma Gandhi Setu','Bihar Caste Survey 2023','Jal-Jeevan-Hariyali');

update questions set chapter_id = 'ch-ca-current'
 where subject_id = 'sub-ca' and topic = 'Current Affairs';

-- ── 5. companion books (original Aimers Path workbooks) ──────────
insert into books (id, exam_id, subject_id, name_en, name_hi, author, publisher, description_en, description_hi, sort_order) values
  ('book-hist-comp',  'exam-bpsc-001', 'sub-hist',  'History Companion',            'इतिहास संगी',  'Aimers Path', 'Aimers Path',
   'Topic-wise practice set aligned to the BPSC syllabus: Ancient, Medieval and Modern India. Original questions, chapter by chapter.',
   'BPSC पाठ्यक्रम के अनुरूप विषयवार अभ्यास: प्राचीन, मध्यकालीन एवं आधुनिक भारत। अध्यायवार मूल प्रश्न।', 1),
  ('book-geo-comp',   'exam-bpsc-001', 'sub-geo',   'Geography Companion',          'भूगोल संगी',  'Aimers Path', 'Aimers Path',
   'Physical & World Geography, Geography of India and Geography of Bihar — original chapter-wise MCQs for BPSC.',
   'भौतिक एवं विश्व भूगोल, भारत तथा बिहार का भूगोल — अध्यायवार मूल MCQs।', 2),
  ('book-pol-comp',   'exam-bpsc-001', 'sub-polity','Polity Companion',             'पोलिटी संगी', 'Aimers Path', 'Aimers Path',
   'Indian Constitution, executive & legislature, judiciary, federalism and local governance — original chapter-wise MCQs.',
   'भारतीय संविधान, कार्यपालिका-विधायिका, न्यायपालिका, संघवाद एवं स्थानीय शासन — अध्यायवार मूल MCQs।', 3),
  ('book-econ-comp',  'exam-bpsc-001', 'sub-econ',  'Economy Companion',            'इकोनॉमी संगी', 'Aimers Path', 'Aimers Path',
   'Money & banking, growth & welfare, external sector and the Bihar economy — original chapter-wise MCQs.',
   'मुद्रा-बैंकिंग, विकास-कल्याण, विदेशी क्षेत्र तथा बिहार अर्थव्यवस्था — अध्यायवार मूल MCQs।', 4),
  ('book-sci-comp',   'exam-bpsc-001', 'sub-sci',   'Science Companion',            'साइंस संगी',  'Aimers Path', 'Aimers Path',
   'Physics, Chemistry and Biology & Environment — original chapter-wise MCQs tuned to the BPSC general science paper.',
   'भौतिक विज्ञान, रसायन विज्ञान एवं जीव विज्ञान-पर्यावरण — BPSC पैटर्न के अध्यायवार मूल MCQs।', 5),
  ('book-bihar-comp', 'exam-bpsc-001', 'sub-bihar', 'Bihar Special Companion',      'बिहार स्पेशल संगी', 'Aimers Path', 'Aimers Path',
   'Heritage of Bihar, the freedom movement in Bihar and Bihar today — original chapter-wise MCQs for Bihar Special.',
   'बिहार की विरासत, स्वतंत्रता आंदोलन तथा आज का बिहार — अध्यायवार मूल MCQs।', 6),
  ('book-ca-comp',    'exam-bpsc-001', 'sub-ca',    'Current Affairs Companion',    'करेंट अफेयर्स संगी', 'Aimers Path', 'Aimers Path',
   'Updated current-affairs MCQs for BPSC, refreshed with every bank import.',
   'BPSC के लिए समकालीन घटनाओं के MCQs — हर नए बैंक आयात के साथ अद्यतन।', 7)
on conflict (id) do update set
  name_en = excluded.name_en, name_hi = excluded.name_hi,
  subject_id = excluded.subject_id, description_en = excluded.description_en,
  description_hi = excluded.description_hi, sort_order = excluded.sort_order,
  is_active = true;

insert into book_chapters (id, book_id, chapter_no, name_en, name_hi, sort_order) values
  ('bch-hist-ancient',  'book-hist-comp',  '1', 'Ancient India',        'प्राचीन भारत', 1),
  ('bch-hist-medieval', 'book-hist-comp',  '2', 'Medieval India',       'मध्यकालीन भारत', 2),
  ('bch-hist-modern',   'book-hist-comp',  '3', 'Modern India',         'आधुनिक भारत', 3),
  ('bch-geo-physical',  'book-geo-comp',   '1', 'Physical & World',     'भौतिक एवं विश्व', 1),
  ('bch-geo-india',     'book-geo-comp',   '2', 'Geography of India',   'भारत का भूगोल', 2),
  ('bch-geo-bihar',     'book-geo-comp',   '3', 'Geography of Bihar',   'बिहार का भूगोल', 3),
  ('bch-pol-foundation','book-pol-comp',   '1', 'Constitutional Found.', 'संवैधानिक आधार', 1),
  ('bch-pol-executive', 'book-pol-comp',   '2', 'Executive & Legislature','कार्यपालिका एवं विधायिका', 2),
  ('bch-pol-judiciary', 'book-pol-comp',   '3', 'Judiciary & Federalism', 'न्यायपालिका एवं संघवाद', 3),
  ('bch-econ-macro',    'book-econ-comp',  '1', 'Money & Banking',      'मुद्रा एवं बैंकिंग', 1),
  ('bch-econ-growth',   'book-econ-comp',  '2', 'Growth & Welfare',     'विकास एवं कल्याण', 2),
  ('bch-econ-external', 'book-econ-comp',  '3', 'External & Bihar Econ.', 'विदेशी क्षेत्र एवं बिहार', 3),
  ('bch-sci-physics',   'book-sci-comp',   '1', 'Physics',              'भौतिक विज्ञान', 1),
  ('bch-sci-chem',      'book-sci-comp',   '2', 'Chemistry',            'रसायन विज्ञान', 2),
  ('bch-sci-bio',       'book-sci-comp',   '3', 'Biology & Environment','जीव विज्ञान एवं पर्यावरण', 3),
  ('bch-bihar-heritage','book-bihar-comp','1', 'Heritage',             'विरासत', 1),
  ('bch-bihar-freedom', 'book-bihar-comp','2', 'Freedom Struggle',     'स्वतंत्रता संघर्ष', 2),
  ('bch-bihar-today',   'book-bihar-comp','3', 'Bihar Today',          'आज का बिहार', 3),
  ('bch-ca-current',    'book-ca-comp',    '1', 'Recent Affairs',       'ताज़ा घटनाएँ', 1)
on conflict (id) do update set name_en = excluded.name_en, name_hi = excluded.name_hi, sort_order = excluded.sort_order;

insert into book_chapter_tests (test_id, chapter_id) values
  ('test-bpsc-ch-hist-ancient',  'bch-hist-ancient'),
  ('test-bpsc-ch-hist-medieval', 'bch-hist-medieval'),
  ('test-bpsc-ch-hist-modern',   'bch-hist-modern'),
  ('test-bpsc-ch-geo-physical',  'bch-geo-physical'),
  ('test-bpsc-ch-geo-india',     'bch-geo-india'),
  ('test-bpsc-ch-geo-bihar',     'bch-geo-bihar'),
  ('test-bpsc-ch-pol-constitution','bch-pol-foundation'),
  ('test-bpsc-ch-pol-executive',  'bch-pol-executive'),
  ('test-bpsc-ch-pol-judiciary',  'bch-pol-judiciary'),
  ('test-bpsc-ch-econ-macro',     'bch-econ-macro'),
  ('test-bpsc-ch-econ-growth',    'bch-econ-growth'),
  ('test-bpsc-ch-econ-external',  'bch-econ-external'),
  ('test-bpsc-ch-sci-physics',    'bch-sci-physics'),
  ('test-bpsc-ch-sci-chem',       'bch-sci-chem'),
  ('test-bpsc-ch-sci-bio',        'bch-sci-bio'),
  ('test-bpsc-ch-bihar-heritage', 'bch-bihar-heritage'),
  ('test-bpsc-ch-bihar-freedom',  'bch-bihar-freedom'),
  ('test-bpsc-ch-bihar-today',    'bch-bihar-today'),
  ('test-ca-mixed-01',            'bch-ca-current')
on conflict (test_id) do update set chapter_id = excluded.chapter_id;

-- ── 6. category tests ───────────────────────────────────────────
-- Subject tests pull their questions from the live pool at attempt time
-- (start_test_attempt falls back to the subject/chapter pool), so every
-- attempt gets a fresh mix. Sizes follow the real pool, capped at 35.
with pool as (
  select s.id as subject_id, count(q.id) as n
  from subjects s
  left join questions q on q.subject_id = s.id and q.status = 'published'
  where s.exam_id = 'exam-bpsc-001'
    and s.id in ('sub-hist','sub-geo','sub-polity','sub-econ','sub-sci')
  group by s.id
),
meta as (
  select p.subject_id, p.n,
    case p.subject_id
      when 'sub-hist'   then 'test-bpsc-hist-01'
      when 'sub-geo'    then 'test-bpsc-geo-01'
      when 'sub-polity' then 'test-bpsc-pol-01'
      when 'sub-econ'   then 'test-bpsc-econ-01'
      when 'sub-sci'    then 'test-bpsc-sci-01'
    end as tid,
    case p.subject_id
      when 'sub-hist'   then 'History Subject Test'
      when 'sub-geo'    then 'Geography Subject Test'
      when 'sub-polity' then 'Polity Subject Test'
      when 'sub-econ'   then 'Economy Subject Test'
      when 'sub-sci'    then 'General Science Subject Test'
    end as title_en,
    case p.subject_id
      when 'sub-hist'   then 'इतिहास — विषय टेस्ट'
      when 'sub-geo'    then 'भूगोल — विषय टेस्ट'
      when 'sub-polity' then 'राजव्यवस्था — विषय टेस्ट'
      when 'sub-econ'   then 'अर्थव्यवस्था — विषय टेस्ट'
      when 'sub-sci'    then 'सामान्य विज्ञान — विषय टेस्ट'
    end as title_hi,
    case p.subject_id
      when 'sub-hist'   then 'Ancient, medieval and modern India in one fresh-mix paper.'
      when 'sub-geo'    then 'Physical, world, Indian and Bihar geography mixed fresh each attempt.'
      when 'sub-polity' then 'Constitution, executive, judiciary and federalism mixed fresh each attempt.'
      when 'sub-econ'   then 'Macro, planning, external sector and Bihar economy mixed fresh each attempt.'
      when 'sub-sci'    then 'Physics, chemistry and biology mixed fresh each attempt.'
    end as desc_en
  from pool p
)
insert into tests (id, exam_id, subject_id, title, title_en, title_hi, description_en, type,
                   total_questions, duration_minutes, total_marks, marks_per_correct,
                   negative_marking, is_free, is_active, sort_order, status, settings)
select m.tid, 'exam-bpsc-001', m.subject_id, m.title_en, m.title_en, m.title_hi, m.desc_en,
       'subject', m.n, m.n, m.n, 1, 0.33, true, true, (10 + row_number() over ())::int,
       'published', jsonb_build_object('category','subject','source','pool')
from meta m
on conflict (id) do update set
  total_questions = excluded.total_questions, duration_minutes = excluded.duration_minutes,
  total_marks = excluded.total_marks, title_en = excluded.title_en, title_hi = excluded.title_hi,
  description_en = excluded.description_en, settings = excluded.settings,
  is_active = true, status = 'published';

-- Chapter tests (15 tagged "chapter", the 3 Bihar ones tagged "bihar").
with pool as (
  select s.id as subject_id, c.id as chapter_id, count(q.id) as n
  from chapters c
  join subjects s on s.id = c.subject_id
  left join questions q on q.chapter_id = c.id and q.status = 'published'
  where c.exam_id = 'exam-bpsc-001' and c.id <> 'ch-ca-current'
  group by s.id, c.id
),
meta as (
  select p.*, 'test-bpsc-ch-' || replace(p.chapter_id, 'ch-', '') as tid,
         c.name_en as title_en, c.name_hi as title_hi,
         case when p.subject_id = 'sub-bihar' then 'bihar' else 'chapter' end as category
  from pool p
  join chapters c on c.id = p.chapter_id
)
insert into tests (id, exam_id, subject_id, chapter_id, title, title_en, title_hi, description_en, type,
                   total_questions, duration_minutes, total_marks, marks_per_correct,
                   negative_marking, is_free, is_active, sort_order, status, settings)
select m.tid, 'exam-bpsc-001', m.subject_id, m.chapter_id, m.title_en, m.title_en, m.title_hi,
       'Chapter-wise MCQ set: every attempt draws a fresh mix from this chapter cluster.',
       'chapter', m.n, greatest(m.n, 5), m.n, 1, 0.33, true, true,
       20 + (sort.rn * 1)::int, 'published',
       jsonb_build_object('category', m.category, 'source', 'pool')
from meta m
cross join (select id, row_number() over (order by id) as rn from chapters where exam_id = 'exam-bpsc-001') sort
where sort.id = m.chapter_id
on conflict (id) do update set
  total_questions = excluded.total_questions, duration_minutes = excluded.duration_minutes,
  total_marks = excluded.total_marks, title_en = excluded.title_en, title_hi = excluded.title_hi,
  settings = excluded.settings, is_active = true, status = 'published';

-- Bihar Special grand test + Current Affairs test.
with pool as (
  select s.id as subject_id, count(q.id) as n
  from subjects s
  left join questions q on q.subject_id = s.id and q.status = 'published'
  where s.exam_id = 'exam-bpsc-001' and s.id in ('sub-bihar','sub-ca')
  group by s.id
),
meta as (
  select p.subject_id, p.n,
    case p.subject_id when 'sub-bihar' then 'test-bihar-special-01' else 'test-ca-mixed-01' end as tid,
    case p.subject_id when 'sub-bihar' then 'Bihar Special Grand Test' else 'Current Affairs Test' end as title_en,
    case p.subject_id when 'sub-bihar' then 'बिहार स्पेशल ग्रैंड टेस्ट' else 'करेंट अफेयर्स टेस्ट' end as title_hi,
    case p.subject_id
      when 'sub-bihar' then 'Bihar heritage, freedom movement, geography and schemes — one fresh-mix paper.'
      else 'Current-events MCQs from the bank — refreshed with every import.'
    end as desc_en,
    case p.subject_id
      when 'sub-bihar' then 'बिहार की विरासत, स्वतंत्रता आंदोलन, भूगोल एवं योजनाएँ — एक मिश्रित पेपर।'
      else 'बैंक के करेंट अफेयर्स प्रश्न — हर आयात के साथ अद्यतन।'
    end as desc_hi,
    case p.subject_id when 'sub-bihar' then 'bihar' else 'ca' end as category
  from pool p
)
insert into tests (id, exam_id, subject_id, title, title_en, title_hi, description_en, description_hi,
                   type, total_questions, duration_minutes, total_marks, marks_per_correct,
                   negative_marking, is_free, is_active, sort_order, status, settings)
select m.tid, 'exam-bpsc-001', m.subject_id, m.title_en, m.title_en, m.title_hi, m.desc_en, m.desc_hi,
       case m.category when 'bihar' then 'chapter' else 'ca' end, m.n, m.n, m.n, 1, 0.33, true, true,
       case m.category when 'bihar' then 40 else 50 end, 'published',
       jsonb_build_object('category', m.category, 'source', 'pool')
from meta m
on conflict (id) do update set
  total_questions = excluded.total_questions, duration_minutes = excluded.duration_minutes,
  total_marks = excluded.total_marks, title_en = excluded.title_en, title_hi = excluded.title_hi,
  description_en = excluded.description_en, description_hi = excluded.description_hi,
  settings = excluded.settings, is_active = true, status = 'published';

-- PYQ Trend MCQs — original questions written to the recurring BPSC themes of
-- past papers (high-frequency topics). These are CURATED through test_questions
-- so the set is stable and topical; is_pyq stays false everywhere, and nothing
-- here claims to be an official paper.
insert into tests (id, exam_id, subject_id, title, title_en, title_hi, description_en, description_hi,
                   type, total_questions, duration_minutes, total_marks, marks_per_correct,
                   negative_marking, is_free, is_active, sort_order, status, settings)
select v.id, 'exam-bpsc-001', v.subject, v.title_en, v.title_en, v.title_hi, v.desc_en, v.desc_hi,
       v.ttype, v.n, v.n, v.n, 1, 0.33, true, true, v.sort, 'published', v.settings
from (
  select 'test-pyq-trend-polity-01' as id, 'sub-polity' as subject,
         'PYQ Trend MCQs — Polity & Constitution' as title_en,
         'PYQ ट्रेंड MCQs — राजव्यवस्था एवं संविधान' as title_hi,
         'MCQs on the BPSC themes that repeat most often: rights, DPSP, Preamble, President, Parliament.',
         'वे BPSC थीम जो बार-बार दोहराई जाती हैं: अधिकार, नीति निदेशक तत्व, प्रस्तावना, राष्ट्रपति, संसद।',
         'pyq_trends' as ttype, 60 as sort,
         jsonb_build_object('category','pyq_trends','source','curated') as settings,
         (select count(*) from questions
           where subject_id = 'sub-polity' and status = 'published'
             and topic in ('Fundamental Rights','Sources of Constitution','Preamble','Directive Principles',
                           'President','Prime Minister and Cabinet','Parliament')) as n
  union all
  select 'test-pyq-trend-history-01', 'sub-hist',
         'PYQ Trend MCQs — History', 'PYQ ट्रेंड MCQs — इतिहास',
         'MCQs on the most-repeated BPSC history themes: Sultanate, Mauryas, Guptas, ancient culture.',
         'BPSC में सबसे अधिक दोहराई गई इतिहास थीम: सल्तनत, मौर्य, गुप्त, प्राचीन संस्कृति।',
         'pyq_trends', 61,
         jsonb_build_object('category','pyq_trends','source','curated'),
         (select count(*) from questions
           where subject_id = 'sub-hist' and status = 'published'
             and topic in ('Delhi Sultanate','Harappan Civilisation','Vedic Age','Mauryan Empire',
                           'Chola Empire','Gupta Age','Bhakti-Sufi Tradition'))
  union all
  select 'test-pyq-trend-geoenv-01', 'sub-sci',
         'PYQ Trend MCQs — Geography & Environment', 'PYQ ट्रेंड MCQs — भूगोल एवं पर्यावरण',
         'MCQs on the recurring BPSC geography/environment themes: monsoon, rivers, soils, ecology.',
         'BPSC की दोहराई जाने वाली भूगोल/पर्यावरण थीम: मानसून, नदियाँ, मृदा, पारिस्थितिकी।',
         'pyq_trends', 62,
         jsonb_build_object('category','pyq_trends','source','curated'),
         (select count(*) from questions
           where status = 'published'
             and ((subject_id = 'sub-geo' and topic in ('Atmosphere','Rocks','Latitude and Longitude',
                       'Indian Rivers','Bihar Rivers','Indian Monsoon','Soils of India'))
               or (subject_id = 'sub-sci' and topic in ('Environment'))))
) v
on conflict (id) do update set
  total_questions = excluded.total_questions, duration_minutes = excluded.duration_minutes,
  total_marks = excluded.total_marks, title_en = excluded.title_en, title_hi = excluded.title_hi,
  description_en = excluded.description_en, description_hi = excluded.description_hi,
  subject_id = excluded.subject_id, settings = excluded.settings,
  is_active = true, status = 'published';

delete from test_questions where test_id like 'test-pyq-trend-%';
insert into test_questions (test_id, question_id, sort_order)
select 'test-pyq-trend-polity-01', q.id,
       row_number() over (order by q.sort_order, q.id)
from questions q
where q.subject_id = 'sub-polity' and q.status = 'published'
  and q.topic in ('Fundamental Rights','Sources of Constitution','Preamble','Directive Principles',
                  'President','Prime Minister and Cabinet','Parliament');

insert into test_questions (test_id, question_id, sort_order)
select 'test-pyq-trend-history-01', q.id,
       row_number() over (order by q.sort_order, q.id)
from questions q
where q.subject_id = 'sub-hist' and q.status = 'published'
  and q.topic in ('Delhi Sultanate','Harappan Civilisation','Vedic Age','Mauryan Empire',
                  'Chola Empire','Gupta Age','Bhakti-Sufi Tradition');

insert into test_questions (test_id, question_id, sort_order)
select 'test-pyq-trend-geoenv-01', q.id,
       row_number() over (order by q.sort_order, q.id)
from questions q
where q.status = 'published'
  and ((q.subject_id = 'sub-geo' and q.topic in ('Atmosphere','Rocks','Latitude and Longitude',
              'Indian Rivers','Bihar Rivers','Indian Monsoon','Soils of India'))
    or (q.subject_id = 'sub-sci' and q.topic = 'Environment'));

-- The full mock keeps its own category badge in the fresh hub.
update tests
set settings = jsonb_build_object('category', 'full', 'source', 'curated')
where id = 'bpsc-full-mock-01';

-- ── 7. topic & revision practice (device-only; still server-picked) ──
create or replace function public.start_topic_practice(p_topic_id text, p_count int default 15)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ids text[];
  v_topic topics%rowtype;
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;
  select * into v_topic from topics where id = p_topic_id;
  if not found then raise exception 'topic not found'; end if;

  select array_agg(q.id order by random()) into v_ids from (
    select id from questions
    where topic_id = p_topic_id and status = 'published'
    limit greatest(1, least(coalesce(p_count, 15), 50))
  ) q;

  return jsonb_build_object(
    'topic', row_to_json(v_topic),
    'questions', (
      select coalesce(jsonb_agg(row_to_json(pq) order by x.idx), '[]'::jsonb)
      from unnest(coalesce(v_ids, array[]::text[])) with ordinality as x(qid, idx)
      join public_questions pq on pq.id = x.qid
    )
  );
end;
$$;

create or replace function public.start_revision_practice(
  p_exam_id text, p_mode text default 'wrong', p_count int default 20)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ids text[];
begin
  if auth.uid() is null then raise exception 'sign in required'; end if;

  if p_mode = 'wrong' then
    -- Questions this student got wrong (latest and historic attempts).
    select array_agg(q.id order by random()) into v_ids from (
      select q.id
      from student_question_history h
      join questions q on q.id = h.question_id
      where h.user_id = auth.uid() and q.exam_id = p_exam_id
        and q.status = 'published' and (h.wrong > 0 or h.last_result = 'wrong')
      limit greatest(1, least(coalesce(p_count, 20), 100))
    ) s;
  elsif p_mode = 'bookmarked' then
    select array_agg(q.id order by random()) into v_ids from (
      select q.id
      from bookmarks b
      join questions q on q.id = b.question_id
      where b.user_id = auth.uid() and q.exam_id = p_exam_id and q.status = 'published'
      limit greatest(1, least(coalesce(p_count, 20), 100))
    ) s;
  elsif p_mode = 'unseen' then
    select array_agg(q.id order by random()) into v_ids from (
      select q.id from questions q
      where q.exam_id = p_exam_id and q.status = 'published'
        and not exists (
          select 1 from student_question_history h
          where h.user_id = auth.uid() and h.question_id = q.id
        )
      limit greatest(1, least(coalesce(p_count, 20), 100))
    ) s;
  else -- 'weak': topics where wrong answers beat correct ones
    select array_agg(q.id order by random()) into v_ids from (
      select q.id
      from student_question_history h
      join questions q on q.id = h.question_id
      where h.user_id = auth.uid() and q.exam_id = p_exam_id and q.status = 'published'
        and h.wrong > 0 and h.correct <= h.wrong
      limit greatest(1, least(coalesce(p_count, 20), 100))
    ) s;
  end if;

  return jsonb_build_object(
    'mode', p_mode,
    'questions', (
      select coalesce(jsonb_agg(row_to_json(pq) order by x.idx), '[]'::jsonb)
      from unnest(coalesce(v_ids, array[]::text[])) with ordinality as x(qid, idx)
      join public_questions pq on pq.id = x.qid
    )
  );
end;
$$;

-- ── 8. topic overview for the fresh /topics page ─────────────────
create or replace function public.get_topic_overview(p_exam_id text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'chapters', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'subject_id', c.subject_id, 'name_en', c.name_en, 'name_hi', c.name_hi,
        'topicCount', (select count(*) from topics t where t.subject_id = c.subject_id
                        and exists (select 1 from questions q2
                                    where q2.topic_id = t.id and q2.chapter_id = c.id)),
        'questionCount', (select count(*) from questions q where q.chapter_id = c.id),
        'topics', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id', t.id, 'name_en', t.name_en,
            'questionCount', (select count(*) from questions q where q.topic_id = t.id and q.chapter_id = c.id)
          ) order by t.sort_order), '[]'::jsonb)
          from topics t
          where exists (select 1 from questions q where q.topic_id = t.id and q.chapter_id = c.id)
        )
      ) order by c.sort_order), '[]'::jsonb)
      from chapters c where c.exam_id = p_exam_id
    )
  );
$$;

create or replace function public.get_book_overview(p_exam_id text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'books', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', b.id, 'subject_id', b.subject_id, 'name_en', b.name_en, 'name_hi', b.name_hi,
        'author', b.author, 'description_en', b.description_en, 'description_hi', b.description_hi,
        'chapters', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'id', bc.id, 'chapter_no', bc.chapter_no, 'name_en', bc.name_en, 'name_hi', bc.name_hi,
            'test_id', bct.test_id
          ) order by bc.sort_order), '[]'::jsonb)
          from book_chapters bc
          left join book_chapter_tests bct on bct.chapter_id = bc.id
          where bc.book_id = b.id and bc.is_active
        )
      ) order by b.sort_order), '[]'::jsonb)
      from books b
      where b.exam_id = p_exam_id and b.is_active
    )
  );
$$;

-- ── 9. grants: practice RPCs never ship answers to anonymous users ─
revoke all on function public.start_topic_practice(text, int) from anon;
revoke all on function public.start_revision_practice(text, text, int) from anon;
revoke all on function public.get_topic_overview(text) from anon;
revoke all on function public.get_book_overview(text) from anon;
grant execute on function public.start_topic_practice(text, int) to authenticated;
grant execute on function public.start_revision_practice(text, text, int) to authenticated;
grant execute on function public.get_topic_overview(text) to authenticated, anon;
grant execute on function public.get_book_overview(text) to authenticated, anon;

insert into audit_logs (actor, action, table_name, record_id, after_data)
values (auth.uid(), 'MIGRATION', 'schema', '0008',
        jsonb_build_object('name', 'full_test_series_taxonomy'));
