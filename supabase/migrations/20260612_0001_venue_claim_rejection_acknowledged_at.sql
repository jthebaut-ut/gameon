-- Persistent dismissal of rejected venue claims for business owners (audit row kept).

ALTER TABLE public.venue_claims
  ADD COLUMN IF NOT EXISTS rejection_acknowledged_at timestamptz NULL;

COMMENT ON COLUMN public.venue_claims.rejection_acknowledged_at IS
  'When set, the owning business has dismissed this rejection from Settings; row stays for audit.';

-- When a claim becomes rejected, clear any prior acknowledgment so the new rejection surfaces.
CREATE OR REPLACE FUNCTION public.venue_claims_reset_rejection_acknowledgment()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  new_st text;
  old_st text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    new_st := lower(trim(coalesce(NEW.approval_status, '')));
    IF new_st LIKE '%reject%' THEN
      NEW.rejection_acknowledged_at := NULL;
    END IF;
    RETURN NEW;
  END IF;

  new_st := lower(trim(coalesce(NEW.approval_status, '')));
  old_st := lower(trim(coalesce(OLD.approval_status, '')));
  IF new_st LIKE '%reject%' AND old_st NOT LIKE '%reject%' THEN
    NEW.rejection_acknowledged_at := NULL;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_venue_claims_reset_rejection_ack ON public.venue_claims;
CREATE TRIGGER trg_venue_claims_reset_rejection_ack
  BEFORE INSERT OR UPDATE OF approval_status ON public.venue_claims
  FOR EACH ROW
  EXECUTE FUNCTION public.venue_claims_reset_rejection_acknowledgment();

-- Business owner (JWT session email matches claim owner_email) acknowledges a rejected claim.
CREATE OR REPLACE FUNCTION public.acknowledge_venue_claim_rejection(p_claim_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  sess_email text;
  claim_owner text;
  claim_st text;
  claim_ack timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT lower(trim(coalesce(u.email, '')))
  INTO sess_email
  FROM auth.users u
  WHERE u.id = auth.uid();

  IF sess_email IS NULL OR sess_email = '' THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT
    lower(trim(coalesce(c.owner_email, ''))),
    lower(trim(coalesce(c.approval_status, ''))),
    c.rejection_acknowledged_at
  INTO claim_owner, claim_st, claim_ack
  FROM public.venue_claims c
  WHERE c.id = p_claim_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Claim not found';
  END IF;

  IF claim_owner IS DISTINCT FROM sess_email THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;

  IF claim_st NOT LIKE '%reject%' THEN
    RAISE EXCEPTION 'Not a rejected claim';
  END IF;

  IF claim_ack IS NOT NULL THEN
    RETURN;
  END IF;

  UPDATE public.venue_claims
  SET rejection_acknowledged_at = now()
  WHERE id = p_claim_id;
END;
$$;

REVOKE ALL ON FUNCTION public.acknowledge_venue_claim_rejection(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.acknowledge_venue_claim_rejection(uuid) TO authenticated;

COMMENT ON FUNCTION public.acknowledge_venue_claim_rejection(uuid) IS
  'Sets rejection_acknowledged_at when the signed-in user''s auth email matches venue_claims.owner_email and the claim is rejected.';
