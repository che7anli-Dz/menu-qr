-- ============================================================
-- Menu QR 🍽 — v1 — جداول Supabase
-- نفذ هاد السكريبت مرة وحدة في Supabase SQL Editor
-- (مشروع chosrqzpuczmirrxmnkf — نفس مشروع تسوق واربح / كَلَك / الذيب)
-- ملاحظة: ما تنفذوش إلا بإذن Ismail — كلمة سر القاعدة استعمال واحد
-- ============================================================

-- ---------- 1) المشاريع (مطعم / مقهى / فاست فود / سناك / باتيسري / عصير) ----------
create table if not exists menu_cafes (
  id uuid default gen_random_uuid() primary key,
  owner_id uuid not null,                 -- auth.users.id تاع صاحب المشروع
  name text not null,
  slug text unique not null,              -- الرابط: ?cafe=slug
  type text default 'restaurant',        -- نوع المحل: restaurant / cafe / patisserie / fastfood / snack / juice
  tagline text default '',
  whatsapp text not null,                 -- رقم الواتساب الرئيسي (الطلبات توصلو)
  kitchen_whatsapp text default '',       -- رقم واتساب المطبخ (طلبات الطاولات)
  cashier_whatsapp text default '',        -- رقم واتساب الكاشير (المجموع تاع كل طلب)
  phone text default '',                  -- رقم الاتصال
  facebook text default '',
  logo_url text default '' check (length(logo_url) <= 2000000), -- حد لحجم الصورة (base64) باش ما يثقلش القاعدة
  currency text default 'دج',
  views integer default 0,                -- عدد المشاهدات
  trial_ends_at timestamptz,              -- نهاية التجربة المجانية (14 يوم)
  is_active boolean default false,        -- الاشتراك فعال (يتفعّل يدوياً عبر واتساب)
  founder boolean default false,          -- من الأوائل 20: سعرو مثبت للأبد
  created_at timestamptz default now()
);

-- ---------- 2) الأقسام ----------
create table if not exists menu_categories (
  id uuid default gen_random_uuid() primary key,
  cafe_id uuid not null references menu_cafes(id) on delete cascade,
  name text not null,
  sort integer default 0,
  created_at timestamptz default now()
);

-- ---------- 3) الأطباق ----------
create table if not exists menu_items (
  id uuid default gen_random_uuid() primary key,
  cafe_id uuid not null references menu_cafes(id) on delete cascade,
  category_id uuid not null references menu_categories(id) on delete cascade,
  name text not null,
  description text default '',
  price numeric not null check (price >= 0),
  image_url text default '' check (length(image_url) <= 2000000), -- حد لحجم الصورة (base64) باش ما يثقلش القاعدة
  emoji text default '🍽️',
  available boolean default true,
  sort integer default 0,
  created_at timestamptz default now()
);

-- ---------- 4) فهارس ----------
create index if not exists idx_menu_cafes_owner on menu_cafes(owner_id);
create index if not exists idx_menu_cafes_slug on menu_cafes(slug);
create index if not exists idx_menu_cats_cafe on menu_categories(cafe_id);
create index if not exists idx_menu_items_cafe on menu_items(cafe_id);
create index if not exists idx_menu_items_cat on menu_items(category_id);

-- مشروع واحد برك لكل حساب (لوحة التحكم مبنية على مشروع واحد — يتفسخ هاد السطر إذا وليت تدعم عدة محلات لنفس الحساب)
create unique index if not exists idx_menu_cafes_owner_unique on menu_cafes(owner_id);

-- ---------- 5) RLS ----------
alter table menu_cafes enable row level security;
alter table menu_categories enable row level security;
alter table menu_items enable row level security;

-- المشاريع: القراءة للكل (المنيو عامة)، الكتابة غير للمالك
drop policy if exists "menu_cafes public read" on menu_cafes;
create policy "menu_cafes public read" on menu_cafes
  for select using (true);
drop policy if exists "menu_cafes owner write" on menu_cafes;
create policy "menu_cafes owner write" on menu_cafes
  for all using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

-- الأقسام والأطباق: القراءة للكل، الكتابة غير لمالك المشروع
drop policy if exists "menu_categories public read" on menu_categories;
create policy "menu_categories public read" on menu_categories
  for select using (true);
drop policy if exists "menu_categories owner write" on menu_categories;
create policy "menu_categories owner write" on menu_categories
  for all using (
    exists (select 1 from menu_cafes c where c.id = menu_categories.cafe_id and c.owner_id = auth.uid())
  ) with check (
    exists (select 1 from menu_cafes c where c.id = menu_categories.cafe_id and c.owner_id = auth.uid())
  );

drop policy if exists "menu_items public read" on menu_items;
create policy "menu_items public read" on menu_items
  for select using (true);
drop policy if exists "menu_items owner write" on menu_items;
create policy "menu_items owner write" on menu_items
  for all using (
    exists (select 1 from menu_cafes c where c.id = menu_items.cafe_id and c.owner_id = auth.uid())
  ) with check (
    exists (select 1 from menu_cafes c where c.id = menu_items.cafe_id and c.owner_id = auth.uid())
  );

-- ---------- 6) عدّاد المشاهدات (دالة آمنة — أي زائر يقدر يزيد +1 برك) ----------
create or replace function bump_menu_views(p_cafe_id uuid)
returns void
language sql
security definer
as $$
  update menu_cafes set views = coalesce(views, 0) + 1 where id = p_cafe_id;
$$;
grant execute on function bump_menu_views(uuid) to anon, authenticated;

-- ---------- 7) حماية الاشتراك: التحكم غير عند Ismail ----------
-- المشكل: سياسة RLS تسمح لمالك المشروع يبدل أي خانة في سطرو، يعني يقدر يفعّل اشتراكو بروحو ولا يمدد التجربة من الـ API.
-- الحل: زوج triggers —
--   (أ) عند الإنشاء: التجربة 14 يوم تتحدد من السيرفر، والاشتراك يبدا مطفي، حتى لو الزبون بعث قيم أخرى.
--   (ب) عند التعديل: حقول الاشتراك (is_active / trial_ends_at / founder) ما يتبدلوش من التطبيق (role authenticated) — غير من Supabase Dashboard / SQL Editor تاع Ismail (roles service_role و postgres يتجاوزو RLS والـ trigger).
create or replace function init_menu_subscription()
returns trigger
language plpgsql
as $$
begin
  new.trial_ends_at := now() + interval '14 days';
  new.is_active := false;
  new.founder := false;
  return new;
end;
$$;
drop trigger if exists trg_init_menu_subscription on menu_cafes;
create trigger trg_init_menu_subscription
  before insert on menu_cafes
  for each row execute function init_menu_subscription();

create or replace function guard_menu_subscription()
returns trigger
language plpgsql
as $$
begin
  if current_role = 'authenticated' then
    if new.is_active is distinct from old.is_active
       or new.trial_ends_at is distinct from old.trial_ends_at
       or new.founder is distinct from old.founder then
      raise exception 'subscription fields are managed by the platform owner';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists trg_guard_menu_subscription on menu_cafes;
create trigger trg_guard_menu_subscription
  before update on menu_cafes
  for each row execute function guard_menu_subscription();

-- ---------- 8) صلاحيات الـ API (بدونها التطبيق ما يقدرش يقرا/يكتب — RLS وحدها ما تكفيش) ----------
grant select on menu_cafes to anon, authenticated;
grant insert, update, delete on menu_cafes to authenticated;
grant select on menu_categories to anon, authenticated;
grant insert, update, delete on menu_categories to authenticated;
grant select on menu_items to anon, authenticated;
grant insert, update, delete on menu_items to authenticated;

-- ---------- 9) الطلبات بلا واتساب (شاشة المطبخ + الكاشير) ----------
alter table menu_cafes add column if not exists delivery_enabled boolean not null default false;

create table if not exists menu_orders (
  id uuid default gen_random_uuid() primary key,
  cafe_id uuid not null references menu_cafes(id) on delete cascade,
  kind text not null check (kind in ('table','delivery','pickup')),
  table_no integer,
  customer_name text default '',
  customer_phone text default '',
  address text default '',
  items jsonb not null default '[]'::jsonb,
  total numeric not null default 0,
  status text not null default 'new' check (status in ('new','preparing','done','cancelled')),
  created_at timestamptz default now()
);
create index if not exists idx_menu_orders_cafe on menu_orders(cafe_id, created_at desc);

alter table menu_orders enable row level security;
-- أي زائر يقدر يبعث طلب (الزبون ماشي مسجل دخول)
drop policy if exists "orders_insert_public" on menu_orders;
create policy "orders_insert_public" on menu_orders
  for insert to anon, authenticated with check (true);
-- القراءة والتعديل غير لمالك المشروع
drop policy if exists "orders_select_owner" on menu_orders;
create policy "orders_select_owner" on menu_orders
  for select to authenticated using (cafe_id in (select id from menu_cafes where owner_id = auth.uid()));
drop policy if exists "orders_update_owner" on menu_orders;
create policy "orders_update_owner" on menu_orders
  for update to authenticated
  using (cafe_id in (select id from menu_cafes where owner_id = auth.uid()))
  with check (cafe_id in (select id from menu_cafes where owner_id = auth.uid()));

-- الطلب الجديد دايماً يبدا new (حماية من تلاعب العميل)
create or replace function menu_orders_force_new()
returns trigger language plpgsql as $$
begin
  new.status := 'new';
  return new;
end $$;
drop trigger if exists trg_menu_orders_force_new on menu_orders;
create trigger trg_menu_orders_force_new before insert on menu_orders
  for each row execute function menu_orders_force_new();

-- Realtime باش شاشة المطبخ تتحدث لحظياً (idempotent)
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'menu_orders') then
    execute 'alter publication supabase_realtime add table menu_orders';
  end if;
end $$;

grant select on menu_orders to anon, authenticated;
grant insert on menu_orders to anon, authenticated;
grant update on menu_orders to authenticated;

-- ================= القسم 10: حالات الطاولات (فتح/سد) =================
-- الطاولة المسدودة: الزبون اللي عندو الرابط ما يقدرش يزيد يطلب حتى يعاود السارفور يفتحها.
-- بلا سطر = الطاولة مفتوحة (توافق مع الروابط القديمة).
create table if not exists menu_tables (
  id uuid default gen_random_uuid() primary key,
  cafe_id uuid not null references menu_cafes(id) on delete cascade,
  table_no integer not null,
  status text not null default 'open' check (status in ('open','closed')),
  updated_at timestamptz default now(),
  unique(cafe_id, table_no)
);
create index if not exists idx_menu_tables_cafe on menu_tables(cafe_id, table_no);

alter table menu_tables enable row level security;
-- أي زائر يقدر يقرا حالة الطاولة (باش التطبيق يمنع الطلب قبل ما يبعثو)
drop policy if exists "menu_tables public read" on menu_tables;
create policy "menu_tables public read" on menu_tables for select to anon, authenticated using (true);
-- الكتابة غير لمالك المشروع
drop policy if exists "menu_tables owner write" on menu_tables;
create policy "menu_tables owner write" on menu_tables for all to authenticated
  using (cafe_id in (select id from menu_cafes where owner_id = auth.uid()))
  with check (cafe_id in (select id from menu_cafes where owner_id = auth.uid()));

-- حماية من السيرفر: طلب طاولة مسدودة يترفض حتى لو تجاوز فحص التطبيق
create or replace function menu_orders_check_table_open()
returns trigger language plpgsql as $$
begin
  if new.kind = 'table' and new.table_no is not null then
    if exists (select 1 from menu_tables t where t.cafe_id = new.cafe_id and t.table_no = new.table_no and t.status = 'closed') then
      raise exception 'table_closed';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_menu_orders_check_table_open on menu_orders;
create trigger trg_menu_orders_check_table_open before insert on menu_orders
  for each row execute function menu_orders_check_table_open();

-- Realtime (idempotent)
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'menu_tables') then
    execute 'alter publication supabase_realtime add table menu_tables';
  end if;
end $$;

grant select on menu_tables to anon, authenticated;
grant insert, update, delete on menu_tables to authenticated;
