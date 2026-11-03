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
