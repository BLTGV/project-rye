-- A gated configuration type cannot be aliased away.
--
-- Work item: work/011-loose-ends.md
-- Contract:  contracts/sql-surface.md, "Configuration writes need an admin",
--            paragraph "A gated type cannot be aliased away".
-- Decision:  docs/decisions/0007-configuration-writes-need-an-admin.md
--
-- The gate in 0023 compares the stored spelling, because every reader of
-- configuration does: registry_value() and governing_scope() match the literal
-- `registry_entry` and `review_policy`. record_assertion() canonicalizes before
-- it inserts, so an alias OF a gated type is gated. The hole is the other
-- direction. A registry entry keyed `type_alias:assertion_type:registry_entry`
-- makes canonical_type() resolve `registry_entry` to some other name, so a
-- later write under the gated name is stored under the alias target, and the
-- trigger -- which reads the stored spelling -- lets it land accepted. The
-- write is then not read as configuration either, so what it costs is the gate,
-- not the configuration; but one such alias is enough to turn the gate off for
-- everything that arrives through record_assertion() afterwards. Found by the
-- work/005 verification, rated LOW because recording the alias itself needs an
-- admin today.
--
-- The rule: a registry entry whose assertion_key is
-- `type_alias:assertion_type:<T>`, where <T> has a `settle` row in
-- assertion_type_access, is refused for every caller at every status --
-- candidate included, and an admin included. There is nothing to demote it to:
-- a candidate alias is one accept_assertion() away from being live, and the
-- point of the gate is that no route makes a gated write accepted by accident.
--
-- Data, like the rest of the gate. The set of types comes from the `settle`
-- rows, so adding a type to the gate refuses aliases out of it with no further
-- migration, and `scope_status` joins the rule the moment its row exists.
--
-- An alias INTO a gated type is unaffected, as the contract says. Writing
-- `type_alias:assertion_type:draft_policy = "review_policy"` makes a write
-- under `draft_policy` canonicalize to `review_policy`, which is the gated
-- spelling, so the write is demoted by record_assertion() and refused on every
-- other route. It narrows what a non-admin can do; it cannot widen it.
--
-- Where it lives: assertion_settle_gate_guard(), before the branch that returns
-- early for a row that is not becoming accepted. One trigger, so a
-- SECURITY DEFINER helper does not escape it and neither does a raw INSERT. The
-- whole 0023 body is carried forward unchanged below; the only new code is the
-- first block.
--
-- On UPDATE the rule fires only when the row becomes accepted, which is what
-- accept_assertion() on a candidate alias does. An update that leaves an
-- already-accepted row accepted, or that closes a candidate, is left to the
-- rest of the guard: an instance that recorded such an alias before this
-- migration must still be able to supersede or reject it, and only an admin
-- can, because the rest of the guard says so.

SET search_path = rye, pg_catalog, public;

CREATE OR REPLACE FUNCTION assertion_settle_gate_guard() RETURNS trigger
SET search_path = rye, pg_catalog
AS $$
DECLARE
    v_alias_from       text;
    v_becomes_accepted boolean;
    v_changes_accepted boolean;
    v_roles text[];
    v_type  text;
BEGIN
    v_becomes_accepted := NEW.status = 'accepted'
        AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'accepted');
    v_changes_accepted := TG_OP = 'UPDATE' AND OLD.status = 'accepted';

    -- No alias may point FROM a gated configuration type. The key carries the
    -- aliased name; the claim carries what it would resolve to, and is not
    -- read here, because what matters is which name stops reaching the gate.
    -- The type is the stored spelling `registry_entry`, because that is the
    -- only spelling registry_value() reads an alias from.
    IF NEW.assertion_type = 'registry_entry'
       AND (TG_OP = 'INSERT' OR v_becomes_accepted)
    THEN
        v_alias_from := nullif(
            substring(NEW.assertion_key from '^type_alias:assertion_type:(.+)$'), ''
        );
        IF v_alias_from IS NOT NULL
           AND assertion_settle_roles(v_alias_from) IS NOT NULL
        THEN
            RAISE EXCEPTION
                'Cannot record a type alias from "%": it is Rye configuration, and an alias would route a write under that name past the settle gate',
                v_alias_from
                USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    IF NOT v_becomes_accepted AND NOT v_changes_accepted THEN
        RETURN NEW;
    END IF;

    -- On an UPDATE the stored spelling is OLD's: an accepted configuration row
    -- stays configuration even if the update tried to retype it, and the
    -- immutability guard refuses retyping anyway.
    v_type := CASE WHEN TG_OP = 'UPDATE' THEN OLD.assertion_type ELSE NEW.assertion_type END;

    v_roles := assertion_settle_roles(v_type);
    IF v_roles IS NULL THEN
        RETURN NEW;
    END IF;
    IF coalesce(nullif(current_setting('app.current_role', true), ''), '')
       = ANY(v_roles)
    THEN
        RETURN NEW;
    END IF;

    IF v_changes_accepted THEN
        RAISE EXCEPTION
            'Assertion type % is Rye configuration: only % may change an accepted entry, including ending one. Record the replacement with record_assertion() and it becomes a candidate waiting for one of those roles.',
            v_type,
            array_to_string(v_roles, ', ')
            USING ERRCODE = 'insufficient_privilege';
    END IF;

    RAISE EXCEPTION
        'Assertion type % is Rye configuration: only % may make it accepted. Record it with record_assertion() and it becomes a candidate waiting for one of those roles.',
        v_type,
        array_to_string(v_roles, ', ')
        USING ERRCODE = 'insufficient_privilege';
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION assertion_settle_gate_guard() IS
    'Refuse any write that makes an assertion of a settle-gated type accepted, any change to a row of a gated type that is already accepted, and any registry_entry that aliases a settle-gated type away (assertion_key type_alias:assertion_type:<gated type>, at every status, for every caller). Unless app.current_role is one of the allowed roles, for the first two. Fires inside SECURITY DEFINER helpers and on raw writes alike. DELETE needs no branch: assertion_delete_policy refuses every delete.';
