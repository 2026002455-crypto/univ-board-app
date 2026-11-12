ALTER TABLE public.memberships
    ADD COLUMN IF NOT EXISTS suspension_reason text,
    ADD COLUMN IF NOT EXISTS left_at timestamptz;

ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS author_label text;
ALTER TABLE public.comments ADD COLUMN IF NOT EXISTS author_label text;

DROP TRIGGER IF EXISTS sync_member_email_trigger ON auth.users;
DROP FUNCTION IF EXISTS public.sync_member_email();
DROP TABLE IF EXISTS public.member_emails;

DO $$
DECLARE
    table_name text;
    fk_name text;
    author_attnum smallint;
BEGIN
    FOREACH table_name IN ARRAY ARRAY['posts', 'comments'] LOOP
        SELECT attnum INTO author_attnum
        FROM pg_attribute
        WHERE attrelid = format('public.%I', table_name)::regclass
          AND attname = 'author_id'
          AND NOT attisdropped;

        FOR fk_name IN
            SELECT conname
            FROM pg_constraint
            WHERE conrelid = format('public.%I', table_name)::regclass
              AND contype = 'f'
              AND array_length(conkey, 1) = 1
              AND conkey[1] = author_attnum
        LOOP
            EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', table_name, fk_name);
        END LOOP;

        EXECUTE format('ALTER TABLE public.%I ALTER COLUMN author_id DROP NOT NULL', table_name);
        EXECUTE format(
            'ALTER TABLE public.%I ADD CONSTRAINT %I FOREIGN KEY (author_id) REFERENCES public.profiles(id) ON DELETE SET NULL',
            table_name,
            table_name || '_author_id_fkey'
        );
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_space_members(p_space_id text)
RETURNS TABLE (
    user_id uuid,
    name text,
    email text,
    phone text,
    role text,
    status text,
    suspension_reason text,
    left_at timestamptz,
    site_role text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    actor_id uuid := auth.uid();
BEGIN
    IF actor_id IS NULL OR NOT (
        EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = actor_id AND p.role::text = 'admin')
        OR EXISTS (
            SELECT 1
            FROM public.memberships m
            WHERE m.space_id::text = p_space_id
              AND m.user_id = actor_id
              AND m.role::text = 'operator'
              AND m.status::text = 'approved'
              AND m.left_at IS NULL
        )
    ) THEN
        RAISE EXCEPTION 'Only this space operators and site admins may view member emails.' USING ERRCODE = '42501';
    END IF;

    RETURN QUERY
    SELECT m.user_id,
           COALESCE(p.name, '탈퇴한 회원')::text,
           COALESCE(u.email, '-')::text,
           COALESCE(p.phone, '-')::text,
           m.role::text,
           m.status::text,
           m.suspension_reason,
           m.left_at,
           COALESCE(p.role::text, 'user')
    FROM public.memberships m
    LEFT JOIN public.profiles p ON p.id = m.user_id
    LEFT JOIN auth.users u ON u.id = m.user_id
    WHERE m.space_id::text = p_space_id
    ORDER BY m.created_at;
END;
$$;

REVOKE ALL ON FUNCTION public.get_space_members(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_space_members(text) TO authenticated;

CREATE OR REPLACE FUNCTION public.manage_space_member(
    p_space_id text,
    p_user_id uuid,
    p_action text,
    p_reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
    actor_id uuid := auth.uid();
    target_role text;
BEGIN
    IF actor_id IS NULL OR p_user_id = actor_id THEN
        RAISE EXCEPTION 'You cannot manage your own account from this screen.' USING ERRCODE = '42501';
    END IF;

    SELECT p.role::text INTO target_role
    FROM public.profiles p
    WHERE p.id = p_user_id;

    IF target_role = 'admin' THEN
        RAISE EXCEPTION 'The site admin account cannot be changed here.' USING ERRCODE = '42501';
    END IF;

    IF NOT (
        EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = actor_id AND p.role::text = 'admin')
        OR EXISTS (
            SELECT 1
            FROM public.memberships m
            WHERE m.space_id::text = p_space_id
              AND m.user_id = actor_id
              AND m.role::text = 'operator'
              AND m.status::text = 'approved'
              AND m.left_at IS NULL
        )
    ) THEN
        RAISE EXCEPTION 'Only this space operators and site admins may manage members.' USING ERRCODE = '42501';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.memberships m
        WHERE m.space_id::text = p_space_id
          AND m.user_id = p_user_id
          AND m.left_at IS NULL
    ) THEN
        RAISE EXCEPTION 'Member not found in this space.' USING ERRCODE = 'P0002';
    END IF;

    IF p_action = 'suspend' THEN
        UPDATE public.memberships
        SET status = 'suspended', suspension_reason = NULLIF(BTRIM(p_reason), '')
        WHERE space_id::text = p_space_id AND user_id = p_user_id;
    ELSIF p_action = 'unsuspend' THEN
        UPDATE public.memberships
        SET status = 'approved', suspension_reason = NULL
        WHERE space_id::text = p_space_id AND user_id = p_user_id AND status::text = 'suspended';
    ELSIF p_action = 'leave' THEN
        UPDATE public.posts p
        SET author_label = '탈퇴한 회원'
        FROM public.boards b
        WHERE p.board_id = b.id
          AND b.space_id::text = p_space_id
          AND p.author_id = p_user_id;

        UPDATE public.comments c
        SET author_label = '탈퇴한 회원'
        FROM public.posts p
        JOIN public.boards b ON b.id = p.board_id
        WHERE c.post_id = p.id
          AND b.space_id::text = p_space_id
          AND c.author_id = p_user_id;

        DELETE FROM public.board_operators bo
        USING public.boards b
        WHERE bo.board_id = b.id
          AND b.space_id::text = p_space_id
          AND bo.user_id = p_user_id;

        UPDATE public.memberships
        SET left_at = now(), suspension_reason = NULL, role = 'member'
        WHERE space_id::text = p_space_id AND user_id = p_user_id;
    ELSE
        RAISE EXCEPTION 'Unsupported member action.' USING ERRCODE = '22023';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.manage_space_member(text, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_space_member(text, uuid, text, text) TO authenticated;
