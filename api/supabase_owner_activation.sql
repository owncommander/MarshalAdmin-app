-- MarshalA owner-only activation issuance (Supabase SQL Editor).
-- Deploy once. Does not change existing pairing or sync functions, Oracle, or Bright.
-- IMPORTANT: after deployment, explicitly register the ONE owner's auth.users.id.
BEGIN;
CREATE TABLE IF NOT EXISTS public.marshal_activation_owner (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  owner_uid uuid NOT NULL UNIQUE REFERENCES auth.users(id),
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.marshal_activation_owner ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.marshal_activation_owner FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.marshal_owner_issue_activation(p_customer_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_tenant_id bigint;
  v_code text;
  v_id bigint;
  v_expiry timestamptz := now() + interval '30 minutes';
BEGIN
  IF auth.role() IS DISTINCT FROM 'authenticated'
     OR auth.uid() IS NULL
     OR NOT EXISTS (
       SELECT 1 FROM public.marshal_activation_owner
       WHERE singleton = true AND owner_uid = auth.uid()
     ) THEN
    RAISE EXCEPTION 'Unauthorized' USING ERRCODE = '42501';
  END IF;

  IF p_customer_code IS NULL OR p_customer_code !~ '^[0-9]{1,20}$' THEN
    RAISE EXCEPTION 'Invalid customer code' USING ERRCODE = '22023';
  END IF;

  SELECT id INTO v_tenant_id
  FROM public.marshal_tenants
  WHERE customer_code = p_customer_code AND is_active AND is_medical;
  IF v_tenant_id IS NULL THEN
    RAISE EXCEPTION 'Tenant not eligible' USING ERRCODE = '22023';
  END IF;

  -- Random 256-bit single-use code; only the SHA-256 digest is stored.
  v_code := encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.marshal_pairing_codes(tenant_id,code_sha256,expires_at)
  VALUES(v_tenant_id, encode(extensions.digest(v_code,'sha256'),'hex'),v_expiry)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object(
    'customer_code',p_customer_code,
    'activation_code',v_code,
    'expires_at',v_expiry,
    'pairing_id',v_id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.marshal_owner_issue_activation(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.marshal_owner_issue_activation(text) TO authenticated;
COMMIT;

-- ONE-TIME OWNER REGISTRATION (run separately, after replacing the UUID):
-- Find the intended owner's User UID in Supabase Authentication > Users.
-- INSERT INTO public.marshal_activation_owner(singleton, owner_uid)
-- VALUES (true, 'REPLACE_WITH_OWNER_AUTH_USER_UUID'::uuid);
-- Never register a second account. The singleton primary key prevents it.
-- Do not put the owner UID or any activation code in GitHub.
