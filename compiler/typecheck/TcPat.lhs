%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

TcPat: Typechecking patterns

\begin{code}
module TcPat ( tcLetPat, tcPat, tcPats, tcOverloadedLit,
	       addDataConStupidTheta, badFieldCon, polyPatSig ) where

#include "HsVersions.h"

import {-# SOURCE #-}	TcExpr( tcSyntaxOp, tcInferRho)

import HsSyn
import TcHsSyn
import TcRnMonad
import Inst
import Id
import Var
import CoreFVs
import Name
import TcSimplify
import TcEnv
import TcMType
import TcType
import VarEnv
import VarSet
import TcUnify
import TcHsType
import TysWiredIn
import Type
import Coercion
import StaticFlags
import TyCon
import DataCon
import PrelNames
import BasicTypes hiding (SuccessFlag(..))
import SrcLoc
import ErrUtils
import Util
import Maybes
import Outputable
import FastString
import Monad
\end{code}


%************************************************************************
%*									*
		External interface
%*									*
%************************************************************************

\begin{code}
tcLetPat :: (Name -> Maybe TcRhoType)
      	 -> LPat Name -> BoxySigmaType 
     	 -> TcM a
      	 -> TcM (LPat TcId, a)
tcLetPat sig_fn pat pat_ty thing_inside
  = do	{ let init_state = PS { pat_ctxt = LetPat sig_fn,
				pat_eqs  = False }
	; (pat', ex_tvs, res) <- tc_lpat pat pat_ty init_state 
                                   (\ _ -> thing_inside)

	-- Don't know how to deal with pattern-bound existentials yet
	; checkTc (null ex_tvs) (existentialExplode pat)

	; return (pat', res) }

-----------------
tcPats :: HsMatchContext Name
       -> [LPat Name]		 -- Patterns,
       -> [BoxySigmaType]	 --   and their types
       -> BoxyRhoType 		 -- Result type,
       -> (BoxyRhoType -> TcM a) --   and the checker for the body
       -> TcM ([LPat TcId], a)

-- This is the externally-callable wrapper function
-- Typecheck the patterns, extend the environment to bind the variables,
-- do the thing inside, use any existentially-bound dictionaries to 
-- discharge parts of the returning LIE, and deal with pattern type
-- signatures

--   1. Initialise the PatState
--   2. Check the patterns
--   3. Check the body
--   4. Check that no existentials escape

tcPats ctxt pats tys res_ty thing_inside
  = tc_lam_pats (APat ctxt) (zipEqual "tcLamPats" pats tys)
	        res_ty thing_inside

tcPat :: HsMatchContext Name
      -> LPat Name -> BoxySigmaType 
      -> BoxyRhoType             -- Result type
      -> (BoxyRhoType -> TcM a)  -- Checker for body, given
                                 -- its result type
      -> TcM (LPat TcId, a)
tcPat ctxt = tc_lam_pat (APat ctxt)

tc_lam_pat :: PatCtxt -> LPat Name -> BoxySigmaType -> BoxyRhoType
           -> (BoxyRhoType -> TcM a) -> TcM (LPat TcId, a)
tc_lam_pat ctxt pat pat_ty res_ty thing_inside
  = do	{ ([pat'],thing) <- tc_lam_pats ctxt [(pat, pat_ty)] res_ty thing_inside
	; return (pat', thing) }

-----------------
tc_lam_pats :: PatCtxt
	    -> [(LPat Name,BoxySigmaType)]
       	    -> BoxyRhoType            -- Result type
       	    -> (BoxyRhoType -> TcM a) -- Checker for body, given its result type
       	    -> TcM ([LPat TcId], a)
tc_lam_pats ctxt pat_ty_prs res_ty thing_inside 
  =  do	{ let init_state = PS { pat_ctxt = ctxt, pat_eqs = False }

	; (pats', ex_tvs, res) <- do { traceTc (text "tc_lam_pats" <+> (ppr pat_ty_prs $$ ppr res_ty)) 
				  ; tcMultiple tc_lpat_pr pat_ty_prs init_state $ \ pstate' ->
				    if (pat_eqs pstate' && (not $ isRigidTy res_ty))
				     then nonRigidResult ctxt res_ty
	     			     else thing_inside res_ty }

	; let tys = map snd pat_ty_prs
	; tcCheckExistentialPat pats' ex_tvs tys res_ty

	; return (pats', res) }


-----------------
tcCheckExistentialPat :: [LPat TcId]		-- Patterns (just for error message)
		      -> [TcTyVar]		-- Existentially quantified tyvars bound by pattern
		      -> [BoxySigmaType]	-- Types of the patterns
		      -> BoxyRhoType		-- Type of the body of the match
		      				-- Tyvars in either of these must not escape
		      -> TcM ()
-- NB: we *must* pass "pats_tys" not just "body_ty" to tcCheckExistentialPat
-- For example, we must reject this program:
--	data C = forall a. C (a -> Int) 
-- 	f (C g) x = g x
-- Here, result_ty will be simply Int, but expected_ty is (C -> a -> Int).

tcCheckExistentialPat _ [] _ _
  = return ()	-- Short cut for case when there are no existentials

tcCheckExistentialPat pats ex_tvs pat_tys body_ty
  = addErrCtxtM (sigPatCtxt pats ex_tvs pat_tys body_ty)	$
    checkSigTyVarsWrt (tcTyVarsOfTypes (body_ty:pat_tys)) ex_tvs

data PatState = PS {
	pat_ctxt :: PatCtxt,
	pat_eqs  :: Bool        -- <=> there are any equational constraints 
				-- Used at the end to say whether the result
				-- type must be rigid
  }

data PatCtxt 
  = APat (HsMatchContext Name)
  | LetPat (Name -> Maybe TcRhoType)	-- Used for let(rec) bindings

notProcPat :: PatCtxt -> Bool
notProcPat (APat ProcExpr) = False
notProcPat _	  	   = True

patSigCtxt :: PatState -> UserTypeCtxt
patSigCtxt (PS { pat_ctxt = LetPat _ }) = BindPatSigCtxt
patSigCtxt _                            = LamPatSigCtxt
\end{code}



%************************************************************************
%*									*
		Binders
%*									*
%************************************************************************

\begin{code}
tcPatBndr :: PatState -> Name -> BoxySigmaType -> TcM TcId
tcPatBndr (PS { pat_ctxt = LetPat lookup_sig }) bndr_name pat_ty
  | Just mono_ty <- lookup_sig bndr_name
  = do	{ mono_name <- newLocalName bndr_name
	; boxyUnify mono_ty pat_ty
	; return (Id.mkLocalId mono_name mono_ty) }

  | otherwise
  = do	{ pat_ty' <- unBoxPatBndrType pat_ty bndr_name
	; mono_name <- newLocalName bndr_name
	; return (Id.mkLocalId mono_name pat_ty') }

tcPatBndr (PS { pat_ctxt = _lam_or_proc }) bndr_name pat_ty
  = do	{ pat_ty' <- unBoxPatBndrType pat_ty bndr_name
		-- We have an undecorated binder, so we do rule ABS1,
		-- by unboxing the boxy type, forcing any un-filled-in
		-- boxes to become monotypes
		-- NB that pat_ty' can still be a polytype:
		-- 	data T = MkT (forall a. a->a)
		-- 	f t = case t of { MkT g -> ... }
		-- Here, the 'g' must get type (forall a. a->a) from the
		-- MkT context
	; return (Id.mkLocalId bndr_name pat_ty') }


-------------------
bindInstsOfPatId :: TcId -> TcM a -> TcM (a, LHsBinds TcId)
bindInstsOfPatId id thing_inside
  | not (isOverloadedTy (idType id))
  = do { res <- thing_inside; return (res, emptyLHsBinds) }
  | otherwise
  = do	{ (res, lie) <- getLIE thing_inside
	; binds <- bindInstsOfLocalFuns lie [id]
	; return (res, binds) }

-------------------
unBoxPatBndrType :: BoxyType -> Name -> TcM TcType
unBoxPatBndrType  ty name = unBoxArgType ty (ptext (sLit "The variable") <+> quotes (ppr name))

unBoxWildCardType :: BoxyType -> TcM TcType
unBoxWildCardType ty      = unBoxArgType ty (ptext (sLit "A wild-card pattern"))

unBoxViewPatType :: BoxyType -> Pat Name -> TcM TcType
unBoxViewPatType  ty pat  = unBoxArgType ty (ptext (sLit "The view pattern") <+> ppr pat)

unBoxArgType :: BoxyType -> SDoc -> TcM TcType
-- In addition to calling unbox, unBoxArgType ensures that the type is of ArgTypeKind; 
-- that is, it can't be an unboxed tuple.  For example, 
--	case (f x) of r -> ...
-- should fail if 'f' returns an unboxed tuple.
unBoxArgType ty pp_this
  = do	{ ty' <- unBox ty	-- Returns a zonked type

	-- Neither conditional is strictly necesssary (the unify alone will do)
	-- but they improve error messages, and allocate fewer tyvars
	; if isUnboxedTupleType ty' then
		failWithTc msg
	  else if isSubArgTypeKind (typeKind ty') then
		return ty'
	  else do 	-- OpenTypeKind, so constrain it
	{ ty2 <- newFlexiTyVarTy argTypeKind
	; unifyType ty' ty2
	; return ty' }}
  where
    msg = pp_this <+> ptext (sLit "cannot be bound to an unboxed tuple")
\end{code}


%************************************************************************
%*									*
		The main worker functions
%*									*
%************************************************************************

Note [Nesting]
~~~~~~~~~~~~~~
tcPat takes a "thing inside" over which the pattern scopes.  This is partly
so that tcPat can extend the environment for the thing_inside, but also 
so that constraints arising in the thing_inside can be discharged by the
pattern.

This does not work so well for the ErrCtxt carried by the monad: we don't
want the error-context for the pattern to scope over the RHS. 
Hence the getErrCtxt/setErrCtxt stuff in tc_lpats.

\begin{code}
--------------------
type Checker inp out =  forall r.
			  inp
		       -> PatState
		       -> (PatState -> TcM r)
		       -> TcM (out, [TcTyVar], r)

tcMultiple :: Checker inp out -> Checker [inp] [out]
tcMultiple tc_pat args pstate thing_inside
  = do	{ err_ctxt <- getErrCtxt
	; let loop pstate []
		= do { res <- thing_inside pstate
		     ; return ([], [], res) }

	      loop pstate (arg:args)
		= do { (p', p_tvs, (ps', ps_tvs, res)) 
				<- tc_pat arg pstate $ \ pstate' ->
				   setErrCtxt err_ctxt $
				   loop pstate' args
		-- setErrCtxt: restore context before doing the next pattern
		-- See note [Nesting] above
				
		     ; return (p':ps', p_tvs ++ ps_tvs, res) }

	; loop pstate args }

--------------------
tc_lpat_pr :: (LPat Name, BoxySigmaType)
	   -> PatState
	   -> (PatState -> TcM a)
	   -> TcM (LPat TcId, [TcTyVar], a)
tc_lpat_pr (pat, ty) = tc_lpat pat ty

tc_lpat :: LPat Name 
	-> BoxySigmaType
	-> PatState
	-> (PatState -> TcM a)
	-> TcM (LPat TcId, [TcTyVar], a)
tc_lpat (L span pat) pat_ty pstate thing_inside
  = setSrcSpan span		  $
    maybeAddErrCtxt (patCtxt pat) $
    do	{ (pat', tvs, res) <- tc_pat pstate pat pat_ty thing_inside
	; return (L span pat', tvs, res) }

--------------------
tc_pat	:: PatState
        -> Pat Name 
        -> BoxySigmaType	-- Fully refined result type
        -> (PatState -> TcM a)	-- Thing inside
        -> TcM (Pat TcId, 	-- Translated pattern
                [TcTyVar], 	-- Existential binders
                a)		-- Result of thing inside

tc_pat pstate (VarPat name) pat_ty thing_inside
  = do	{ id <- tcPatBndr pstate name pat_ty
	; (res, binds) <- bindInstsOfPatId id $
			  tcExtendIdEnv1 name id $
			  (traceTc (text "binding" <+> ppr name <+> ppr (idType id))
			   >> thing_inside pstate)
	; let pat' | isEmptyLHsBinds binds = VarPat id
		   | otherwise		   = VarPatOut id binds
	; return (pat', [], res) }

tc_pat pstate (ParPat pat) pat_ty thing_inside
  = do	{ (pat', tvs, res) <- tc_lpat pat pat_ty pstate thing_inside
	; return (ParPat pat', tvs, res) }

tc_pat pstate (BangPat pat) pat_ty thing_inside
  = do	{ (pat', tvs, res) <- tc_lpat pat pat_ty pstate thing_inside
	; return (BangPat pat', tvs, res) }

-- There's a wrinkle with irrefutable patterns, namely that we
-- must not propagate type refinement from them.  For example
--	data T a where { T1 :: Int -> T Int; ... }
--	f :: T a -> Int -> a
--	f ~(T1 i) y = y
-- It's obviously not sound to refine a to Int in the right
-- hand side, because the arugment might not match T1 at all!
--
-- Nor should a lazy pattern bind any existential type variables
-- because they won't be in scope when we do the desugaring
--
-- Note [Hopping the LIE in lazy patterns]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- In a lazy pattern, we must *not* discharge constraints from the RHS
-- from dictionaries bound in the pattern.  E.g.
--	f ~(C x) = 3
-- We can't discharge the Num constraint from dictionaries bound by
-- the pattern C!  
--
-- So we have to make the constraints from thing_inside "hop around" 
-- the pattern.  Hence the getLLE and extendLIEs later.

tc_pat pstate lpat@(LazyPat pat) pat_ty thing_inside
  = do	{ (pat', pat_tvs, (res,lie)) 
		<- tc_lpat pat pat_ty pstate $ \ _ ->
		   getLIE (thing_inside pstate)
		-- Ignore refined pstate', revert to pstate
	; extendLIEs lie
	-- getLIE/extendLIEs: see Note [Hopping the LIE in lazy patterns]

	-- Check no existentials
	; if (null pat_tvs) then return ()
	  else lazyPatErr lpat pat_tvs

	-- Check that the pattern has a lifted type
	; pat_tv <- newBoxyTyVar liftedTypeKind
	; boxyUnify pat_ty (mkTyVarTy pat_tv)

	; return (LazyPat pat', [], res) }

tc_pat _ p@(QuasiQuotePat _) _ _
  = pprPanic "Should never see QuasiQuotePat in type checker" (ppr p)

tc_pat pstate (WildPat _) pat_ty thing_inside
  = do	{ pat_ty' <- unBoxWildCardType pat_ty	-- Make sure it's filled in with monotypes
	; res <- thing_inside pstate
	; return (WildPat pat_ty', [], res) }

tc_pat pstate (AsPat (L nm_loc name) pat) pat_ty thing_inside
  = do	{ bndr_id <- setSrcSpan nm_loc (tcPatBndr pstate name pat_ty)
	; (pat', tvs, res) <- tcExtendIdEnv1 name bndr_id $
			      tc_lpat pat (idType bndr_id) pstate thing_inside
	    -- NB: if we do inference on:
	    --		\ (y@(x::forall a. a->a)) = e
	    -- we'll fail.  The as-pattern infers a monotype for 'y', which then
	    -- fails to unify with the polymorphic type for 'x'.  This could 
	    -- perhaps be fixed, but only with a bit more work.
	    --
	    -- If you fix it, don't forget the bindInstsOfPatIds!
	; return (AsPat (L nm_loc bndr_id) pat', tvs, res) }

tc_pat pstate (orig@(ViewPat expr pat _)) overall_pat_ty thing_inside 
  = do	{ -- morally, expr must have type
         -- `forall a1...aN. OPT' -> B` 
         -- where overall_pat_ty is an instance of OPT'.
         -- Here, we infer a rho type for it,
         -- which replaces the leading foralls and constraints
         -- with fresh unification variables.
         (expr',expr'_inferred) <- tcInferRho expr
         -- next, we check that expr is coercible to `overall_pat_ty -> pat_ty`
       ; let expr'_expected = \ pat_ty -> (mkFunTy overall_pat_ty pat_ty)
         -- tcSubExp: expected first, offered second
         -- returns coercion
         -- 
         -- NOTE: this forces pat_ty to be a monotype (because we use a unification 
         -- variable to find it).  this means that in an example like
         -- (view -> f)    where view :: _ -> forall b. b
         -- we will only be able to use view at one instantation in the
         -- rest of the view
	; (expr_coerc, pat_ty) <- tcInfer $ \ pat_ty -> 
		tcSubExp ViewPatOrigin (expr'_expected pat_ty) expr'_inferred

         -- pattern must have pat_ty
       ; (pat', tvs, res) <- tc_lpat pat pat_ty pstate thing_inside
         -- this should get zonked later on, but we unBox it here
         -- so that we do the same checks as above
	; annotation_ty <- unBoxViewPatType overall_pat_ty orig        
	; return (ViewPat (mkLHsWrap expr_coerc expr') pat' annotation_ty, tvs, res) }

-- Type signatures in patterns
-- See Note [Pattern coercions] below
tc_pat pstate (SigPatIn pat sig_ty) pat_ty thing_inside
  = do	{ (inner_ty, tv_binds, coi) <- tcPatSig (patSigCtxt pstate) sig_ty 
                                                                    pat_ty
        ; unless (isIdentityCoI coi) $ 
            failWithTc (badSigPat pat_ty)
	; (pat', tvs, res) <- tcExtendTyVarEnv2 tv_binds $
			      tc_lpat pat inner_ty pstate thing_inside
	; return (SigPatOut pat' inner_ty, tvs, res) }

tc_pat _ pat@(TypePat _) _ _
  = failWithTc (badTypePat pat)

------------------------
-- Lists, tuples, arrays
tc_pat pstate (ListPat pats _) pat_ty thing_inside
  = do	{ (elt_ty, coi) <- boxySplitListTy pat_ty
        ; let scoi = mkSymCoI coi
	; (pats', pats_tvs, res) <- tcMultiple (\p -> tc_lpat p elt_ty)
					 	pats pstate thing_inside
 	; return (mkCoPatCoI scoi (ListPat pats' elt_ty) pat_ty, pats_tvs, res) 
        }

tc_pat pstate (PArrPat pats _) pat_ty thing_inside
  = do	{ (elt_ty, coi) <- boxySplitPArrTy pat_ty
        ; let scoi = mkSymCoI coi
	; (pats', pats_tvs, res) <- tcMultiple (\p -> tc_lpat p elt_ty)
						pats pstate thing_inside 
	; when (null pats) (zapToMonotype pat_ty >> return ())  -- c.f. ExplicitPArr in TcExpr
	; return (mkCoPatCoI scoi (PArrPat pats' elt_ty) pat_ty, pats_tvs, res)
        }

tc_pat pstate (TuplePat pats boxity _) pat_ty thing_inside
  = do	{ let tc = tupleTyCon boxity (length pats)
        ; (arg_tys, coi) <- boxySplitTyConApp tc pat_ty
        ; let scoi = mkSymCoI coi
	; (pats', pats_tvs, res) <- tcMultiple tc_lpat_pr (pats `zip` arg_tys)
					       pstate thing_inside

	-- Under flag control turn a pattern (x,y,z) into ~(x,y,z)
	-- so that we can experiment with lazy tuple-matching.
	-- This is a pretty odd place to make the switch, but
	-- it was easy to do.
	; let pat_ty'          = mkTyConApp tc arg_tys
                                     -- pat_ty /= pat_ty iff coi /= IdCo
              unmangled_result = TuplePat pats' boxity pat_ty'
	      possibly_mangled_result
	        | opt_IrrefutableTuples && 
                  isBoxed boxity            = LazyPat (noLoc unmangled_result)
	        | otherwise		    = unmangled_result

 	; ASSERT( length arg_tys == length pats )      -- Syntactically enforced
	  return (mkCoPatCoI scoi possibly_mangled_result pat_ty, pats_tvs, res)
        }

------------------------
-- Data constructors
tc_pat pstate (ConPatIn (L con_span con_name) arg_pats) pat_ty thing_inside
  = do	{ data_con <- tcLookupDataCon con_name
	; let tycon = dataConTyCon data_con
	; tcConPat pstate con_span data_con tycon pat_ty arg_pats thing_inside }

------------------------
-- Literal patterns
tc_pat pstate (LitPat simple_lit) pat_ty thing_inside
  = do	{ let lit_ty = hsLitType simple_lit
	; coi <- boxyUnify lit_ty pat_ty
			-- coi is of kind: lit_ty ~ pat_ty
	; res <- thing_inside pstate
			-- pattern coercions have to
			-- be of kind: pat_ty ~ lit_ty
			-- hence, sym coi
	; return (mkCoPatCoI (mkSymCoI coi) (LitPat simple_lit) pat_ty, 
                   [], res) }

------------------------
-- Overloaded patterns: n, and n+k
tc_pat pstate (NPat over_lit mb_neg eq) pat_ty thing_inside
  = do	{ let orig = LiteralOrigin over_lit
	; lit'    <- tcOverloadedLit orig over_lit pat_ty
	; eq'     <- tcSyntaxOp orig eq (mkFunTys [pat_ty, pat_ty] boolTy)
	; mb_neg' <- case mb_neg of
			Nothing  -> return Nothing	-- Positive literal
			Just neg -> 	-- Negative literal
					-- The 'negate' is re-mappable syntax
 			    do { neg' <- tcSyntaxOp orig neg (mkFunTy pat_ty pat_ty)
			       ; return (Just neg') }
	; res <- thing_inside pstate
	; return (NPat lit' mb_neg' eq', [], res) }

tc_pat pstate (NPlusKPat (L nm_loc name) lit ge minus) pat_ty thing_inside
  = do	{ bndr_id <- setSrcSpan nm_loc (tcPatBndr pstate name pat_ty)
 	; let pat_ty' = idType bndr_id
	      orig    = LiteralOrigin lit
	; lit' <- tcOverloadedLit orig lit pat_ty'

	-- The '>=' and '-' parts are re-mappable syntax
	; ge'    <- tcSyntaxOp orig ge    (mkFunTys [pat_ty', pat_ty'] boolTy)
	; minus' <- tcSyntaxOp orig minus (mkFunTys [pat_ty', pat_ty'] pat_ty')

	-- The Report says that n+k patterns must be in Integral
	-- We may not want this when using re-mappable syntax, though (ToDo?)
	; icls <- tcLookupClass integralClassName
	; instStupidTheta orig [mkClassPred icls [pat_ty']]	
    
	; res <- tcExtendIdEnv1 name bndr_id (thing_inside pstate)
	; return (NPlusKPat (L nm_loc bndr_id) lit' ge' minus', [], res) }

tc_pat _ _other_pat _ _ = panic "tc_pat" 	-- ConPatOut, SigPatOut, VarPatOut
\end{code}


%************************************************************************
%*									*
	Most of the work for constructors is here
	(the rest is in the ConPatIn case of tc_pat)
%*									*
%************************************************************************

[Pattern matching indexed data types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider the following declarations:

  data family Map k :: * -> *
  data instance Map (a, b) v = MapPair (Map a (Pair b v))

and a case expression

  case x :: Map (Int, c) w of MapPair m -> ...

As explained by [Wrappers for data instance tycons] in MkIds.lhs, the
worker/wrapper types for MapPair are

  $WMapPair :: forall a b v. Map a (Map a b v) -> Map (a, b) v
  $wMapPair :: forall a b v. Map a (Map a b v) -> :R123Map a b v

So, the type of the scrutinee is Map (Int, c) w, but the tycon of MapPair is
:R123Map, which means the straight use of boxySplitTyConApp would give a type
error.  Hence, the smart wrapper function boxySplitTyConAppWithFamily calls
boxySplitTyConApp with the family tycon Map instead, which gives us the family
type list {(Int, c), w}.  To get the correct split for :R123Map, we need to
unify the family type list {(Int, c), w} with the instance types {(a, b), v}
(provided by tyConFamInst_maybe together with the family tycon).  This
unification yields the substitution [a -> Int, b -> c, v -> w], which gives us
the split arguments for the representation tycon :R123Map as {Int, c, w}

In other words, boxySplitTyConAppWithFamily implicitly takes the coercion 

  Co123Map a b v :: {Map (a, b) v ~ :R123Map a b v}

moving between representation and family type into account.  To produce type
correct Core, this coercion needs to be used to case the type of the scrutinee
from the family to the representation type.  This is achieved by
unwrapFamInstScrutinee using a CoPat around the result pattern.

Now it might appear seem as if we could have used the previous GADT type
refinement infrastructure of refineAlt and friends instead of the explicit
unification and CoPat generation.  However, that would be wrong.  Why?  The
whole point of GADT refinement is that the refinement is local to the case
alternative.  In contrast, the substitution generated by the unification of
the family type list and instance types needs to be propagated to the outside.
Imagine that in the above example, the type of the scrutinee would have been
(Map x w), then we would have unified {x, w} with {(a, b), v}, yielding the
substitution [x -> (a, b), v -> w].  In contrast to GADT matching, the
instantiation of x with (a, b) must be global; ie, it must be valid in *all*
alternatives of the case expression, whereas in the GADT case it might vary
between alternatives.

RIP GADT refinement: refinements have been replaced by the use of explicit
equality constraints that are used in conjunction with implication constraints
to express the local scope of GADT refinements.

\begin{code}
--	Running example:
-- MkT :: forall a b c. (a~[b]) => b -> c -> T a
-- 	 with scrutinee of type (T ty)

tcConPat :: PatState -> SrcSpan -> DataCon -> TyCon 
	 -> BoxySigmaType	-- Type of the pattern
	 -> HsConPatDetails Name -> (PatState -> TcM a)
	 -> TcM (Pat TcId, [TcTyVar], a)
tcConPat pstate con_span data_con tycon pat_ty arg_pats thing_inside
  = do	{ let (univ_tvs, ex_tvs, eq_spec, eq_theta, dict_theta, arg_tys, _)
                = dataConFullSig data_con
	      skol_info  = PatSkol data_con
	      origin     = SigOrigin skol_info
	      full_theta = eq_theta ++ dict_theta

	  -- Instantiate the constructor type variables [a->ty]
	  -- This may involve doing a family-instance coercion, and building a
	  -- wrapper 
	; (ctxt_res_tys, coi, unwrap_ty) <- boxySplitTyConAppWithFamily tycon 
                                                                        pat_ty
        ; let sym_coi = mkSymCoI coi  -- boxy split coercion oriented wrongly
	      pat_ty' = mkTyConApp tycon ctxt_res_tys
                                      -- pat_ty' /= pat_ty iff coi /= IdCo
              
              wrap_res_pat res_pat = mkCoPatCoI sym_coi uwScrut pat_ty
                where
                  uwScrut = unwrapFamInstScrutinee tycon ctxt_res_tys
                                                   unwrap_ty res_pat

	  -- Add the stupid theta
	; addDataConStupidTheta data_con ctxt_res_tys

	; ex_tvs' <- tcInstSkolTyVars skol_info ex_tvs	
                     -- Get location from monad, not from ex_tvs

	; let tenv     = zipTopTvSubst (univ_tvs ++ ex_tvs)
				       (ctxt_res_tys ++ mkTyVarTys ex_tvs')
	      arg_tys' = substTys tenv arg_tys

	; if null ex_tvs && null eq_spec && null full_theta
	  then do { -- The common case; no class bindings etc 
                    -- (see Note [Arrows and patterns])
		    (arg_pats', inner_tvs, res) <- tcConArgs data_con arg_tys' 
						    arg_pats pstate thing_inside
		  ; let res_pat = ConPatOut { pat_con = L con_span data_con, 
			            	      pat_tvs = [], pat_dicts = [], 
                                              pat_binds = emptyLHsBinds,
					      pat_args = arg_pats', 
                                              pat_ty = pat_ty' }

		    ; return (wrap_res_pat res_pat, inner_tvs, res) }

	  else do   -- The general case, with existential, and local equality 
                    -- constraints
	{ checkTc (notProcPat (pat_ctxt pstate))
		  (existentialProcPat data_con)
		  -- See Note [Arrows and patterns]

          -- Need to test for rigidity if *any* constraints in theta as class
          -- constraints may have superclass equality constraints.  However,
          -- we don't want to check for rigidity if we got here only because
          -- ex_tvs was non-null.
--        ; unless (null theta') $
          -- FIXME: AT THE MOMENT WE CHEAT!  We only perform the rigidity test
          --   if we explicitly or implicitly (by a GADT def) have equality 
          --   constraints.
        ; let eq_preds = [mkEqPred (mkTyVarTy tv, ty) | (tv, ty) <- eq_spec]
	      theta'   = substTheta tenv (eq_preds ++ full_theta)
                           -- order is *important* as we generate the list of
                           -- dictionary binders from theta'
	      no_equalities = not (any isEqPred theta')
	      pstate' | no_equalities = pstate
		      | otherwise     = pstate { pat_eqs = True }

	; unless no_equalities $ checkTc (isRigidTy pat_ty) $
                                 nonRigidMatch (pat_ctxt pstate) data_con

	; ((arg_pats', inner_tvs, res), lie_req) <- getLIE $
		tcConArgs data_con arg_tys' arg_pats pstate' thing_inside

	; loc <- getInstLoc origin
	; dicts <- newDictBndrs loc theta'
	; dict_binds <- tcSimplifyCheckPat loc ex_tvs' dicts lie_req

        ; let res_pat = ConPatOut { pat_con = L con_span data_con, 
			            pat_tvs = ex_tvs',
			            pat_dicts = map instToVar dicts, 
			            pat_binds = dict_binds,
			            pat_args = arg_pats', pat_ty = pat_ty' }
	; return (wrap_res_pat res_pat, ex_tvs' ++ inner_tvs, res)
	} }
  where
    -- Split against the family tycon if the pattern constructor 
    -- belongs to a family instance tycon.
    boxySplitTyConAppWithFamily tycon pat_ty =
      traceTc traceMsg >>
      case tyConFamInst_maybe tycon of
        Nothing                   -> 
          do { (scrutinee_arg_tys, coi1) <- boxySplitTyConApp tycon pat_ty
             ; return (scrutinee_arg_tys, coi1, pat_ty)
             }
	Just (fam_tycon, instTys) -> 
	  do { (scrutinee_arg_tys, coi1) <- boxySplitTyConApp fam_tycon pat_ty
	     ; (_, freshTvs, subst) <- tcInstTyVars (tyConTyVars tycon)
             ; let instTys' = substTys subst instTys
	     ; cois <- boxyUnifyList instTys' scrutinee_arg_tys
             ; let coi = if isIdentityCoI coi1
                         then  -- pat_ty was splittable
                               -- => boxyUnifyList had real work to do
                           mkTyConAppCoI fam_tycon instTys' cois
                         else  -- pat_ty was not splittable
                               -- => scrutinee_arg_tys are fresh tvs and
                               --    boxyUnifyList just instantiated those
                           coi1
	     ; return (freshTvs, coi, mkTyConApp fam_tycon instTys')
                                      -- this is /= pat_ty 
                                      -- iff cois is non-trivial
	     }
      where
        traceMsg = sep [ text "tcConPat:boxySplitTyConAppWithFamily:" <+>
		         ppr tycon <+> ppr pat_ty
		       , text "  family instance:" <+> 
			 ppr (tyConFamInst_maybe tycon)
                       ]

    -- Wraps the pattern (which must be a ConPatOut pattern) in a coercion
    -- pattern if the tycon is an instance of a family.
    --
    unwrapFamInstScrutinee :: TyCon -> [Type] -> Type -> Pat Id -> Pat Id
    unwrapFamInstScrutinee tycon args unwrap_ty pat
      | Just co_con <- tyConFamilyCoercion_maybe tycon 
--      , not (isNewTyCon tycon)       -- newtypes are explicitly unwrapped by
				     -- the desugarer
          -- NB: We can use CoPat directly, rather than mkCoPat, as we know the
          --	 coercion is not the identity; mkCoPat is inconvenient as it
          --	 wants a located pattern.
      = CoPat (WpCast $ mkTyConApp co_con args)       -- co fam ty to repr ty
	      (pat {pat_ty = mkTyConApp tycon args})    -- representation type
	      unwrap_ty					-- family inst type
      | otherwise
      = pat

tcConArgs :: DataCon -> [TcSigmaType]
	  -> Checker (HsConPatDetails Name) (HsConPatDetails Id)

tcConArgs data_con arg_tys (PrefixCon arg_pats) pstate thing_inside
  = do	{ checkTc (con_arity == no_of_args)	-- Check correct arity
		  (arityErr "Constructor" data_con con_arity no_of_args)
	; let pats_w_tys = zipEqual "tcConArgs" arg_pats arg_tys
	; (arg_pats', tvs, res) <- tcMultiple tcConArg pats_w_tys
					      pstate thing_inside 
	; return (PrefixCon arg_pats', tvs, res) }
  where
    con_arity  = dataConSourceArity data_con
    no_of_args = length arg_pats

tcConArgs data_con arg_tys (InfixCon p1 p2) pstate thing_inside
  = do	{ checkTc (con_arity == 2)	-- Check correct arity
	 	  (arityErr "Constructor" data_con con_arity 2)
	; let [arg_ty1,arg_ty2] = arg_tys	-- This can't fail after the arity check
	; ([p1',p2'], tvs, res) <- tcMultiple tcConArg [(p1,arg_ty1),(p2,arg_ty2)]
					      pstate thing_inside
	; return (InfixCon p1' p2', tvs, res) }
  where
    con_arity  = dataConSourceArity data_con

tcConArgs data_con arg_tys (RecCon (HsRecFields rpats dd)) pstate thing_inside
  = do	{ (rpats', tvs, res) <- tcMultiple tc_field rpats pstate thing_inside
	; return (RecCon (HsRecFields rpats' dd), tvs, res) }
  where
    tc_field :: Checker (HsRecField FieldLabel (LPat Name)) (HsRecField TcId (LPat TcId))
    tc_field (HsRecField field_lbl pat pun) pstate thing_inside
      = do { (sel_id, pat_ty) <- wrapLocFstM find_field_ty field_lbl
	   ; (pat', tvs, res) <- tcConArg (pat, pat_ty) pstate thing_inside
	   ; return (HsRecField sel_id pat' pun, tvs, res) }

    find_field_ty :: FieldLabel -> TcM (Id, TcType)
    find_field_ty field_lbl
	= case [ty | (f,ty) <- field_tys, f == field_lbl] of

		-- No matching field; chances are this field label comes from some
		-- other record type (or maybe none).  As well as reporting an
		-- error we still want to typecheck the pattern, principally to
		-- make sure that all the variables it binds are put into the
		-- environment, else the type checker crashes later:
		--	f (R { foo = (a,b) }) = a+b
		-- If foo isn't one of R's fields, we don't want to crash when
		-- typechecking the "a+b".
	   [] -> do { addErrTc (badFieldCon data_con field_lbl)
		    ; bogus_ty <- newFlexiTyVarTy liftedTypeKind
		    ; return (error "Bogus selector Id", bogus_ty) }

		-- The normal case, when the field comes from the right constructor
	   (pat_ty : extras) -> 
		ASSERT( null extras )
		do { sel_id <- tcLookupField field_lbl
		   ; return (sel_id, pat_ty) }

    field_tys :: [(FieldLabel, TcType)]
    field_tys = zip (dataConFieldLabels data_con) arg_tys
	-- Don't use zipEqual! If the constructor isn't really a record, then
	-- dataConFieldLabels will be empty (and each field in the pattern
	-- will generate an error below).

tcConArg :: Checker (LPat Name, BoxySigmaType) (LPat Id)
tcConArg (arg_pat, arg_ty) pstate thing_inside
  = tc_lpat arg_pat arg_ty pstate thing_inside
\end{code}

\begin{code}
addDataConStupidTheta :: DataCon -> [TcType] -> TcM ()
-- Instantiate the "stupid theta" of the data con, and throw 
-- the constraints into the constraint set
addDataConStupidTheta data_con inst_tys
  | null stupid_theta = return ()
  | otherwise	      = instStupidTheta origin inst_theta
  where
    origin = OccurrenceOf (dataConName data_con)
	-- The origin should always report "occurrence of C"
	-- even when C occurs in a pattern
    stupid_theta = dataConStupidTheta data_con
    tenv = mkTopTvSubst (dataConUnivTyVars data_con `zip` inst_tys)
    	 -- NB: inst_tys can be longer than the univ tyvars
	 --     because the constructor might have existentials
    inst_theta = substTheta tenv stupid_theta
\end{code}

Note [Arrows and patterns]
~~~~~~~~~~~~~~~~~~~~~~~~~~
(Oct 07) Arrow noation has the odd property that it involves "holes in the scope". 
For example:
  expr :: Arrow a => a () Int
  expr = proc (y,z) -> do
          x <- term -< y
          expr' -< x

Here the 'proc (y,z)' binding scopes over the arrow tails but not the
arrow body (e.g 'term').  As things stand (bogusly) all the
constraints from the proc body are gathered together, so constraints
from 'term' will be seen by the tcPat for (y,z).  But we must *not*
bind constraints from 'term' here, becuase the desugarer will not make
these bindings scope over 'term'.

The Right Thing is not to confuse these constraints together. But for
now the Easy Thing is to ensure that we do not have existential or
GADT constraints in a 'proc', and to short-cut the constraint
simplification for such vanilla patterns so that it binds no
constraints. Hence the 'fast path' in tcConPat; but it's also a good
plan for ordinary vanilla patterns to bypass the constraint
simplification step.


%************************************************************************
%*									*
		Overloaded literals
%*									*
%************************************************************************

In tcOverloadedLit we convert directly to an Int or Integer if we
know that's what we want.  This may save some time, by not
temporarily generating overloaded literals, but it won't catch all
cases (the rest are caught in lookupInst).

\begin{code}
tcOverloadedLit :: InstOrigin
		 -> HsOverLit Name
		 -> BoxyRhoType
		 -> TcM (HsOverLit TcId)
tcOverloadedLit orig lit@(OverLit { ol_val = val, ol_rebindable = rebindable
				  , ol_witness = meth_name }) res_ty
  | rebindable
	-- Do not generate a LitInst for rebindable syntax.  
	-- Reason: If we do, tcSimplify will call lookupInst, which
	--	   will call tcSyntaxName, which does unification, 
	--	   which tcSimplify doesn't like
	-- ToDo: noLoc sadness
  = do	{ hs_lit <- mkOverLit val
	; let lit_ty = hsLitType hs_lit
	; fi' <- tcSyntaxOp orig meth_name (mkFunTy lit_ty res_ty)
	 	-- Overloaded literals must have liftedTypeKind, because
	 	-- we're instantiating an overloaded function here,
	 	-- whereas res_ty might be openTypeKind. This was a bug in 6.2.2
		-- However this'll be picked up by tcSyntaxOp if necessary
	; let witness = HsApp (noLoc fi') (noLoc (HsLit hs_lit))
	; return (lit { ol_witness = witness, ol_type = res_ty }) }

  | Just expr <- shortCutLit val res_ty 
  = return (lit { ol_witness = expr, ol_type = res_ty })

  | otherwise
  = do 	{ loc <- getInstLoc orig
	; res_tau <- zapToMonotype res_ty
	; new_uniq <- newUnique
	; let	lit_nm   = mkSystemVarName new_uniq (fsLit "lit")
		lit_inst = LitInst {tci_name = lit_nm, tci_lit = lit, 
				    tci_ty = res_tau, tci_loc = loc}
		witness = HsVar (instToId lit_inst)
	; extendLIE lit_inst
	; return (lit { ol_witness = witness, ol_type = res_ty }) }
\end{code}


%************************************************************************
%*									*
		Note [Pattern coercions]
%*									*
%************************************************************************

In principle, these program would be reasonable:
	
	f :: (forall a. a->a) -> Int
	f (x :: Int->Int) = x 3

	g :: (forall a. [a]) -> Bool
	g [] = True

In both cases, the function type signature restricts what arguments can be passed
in a call (to polymorphic ones).  The pattern type signature then instantiates this
type.  For example, in the first case,  (forall a. a->a) <= Int -> Int, and we
generate the translated term
	f = \x' :: (forall a. a->a).  let x = x' Int in x 3

From a type-system point of view, this is perfectly fine, but it's *very* seldom useful.
And it requires a significant amount of code to implement, becuase we need to decorate
the translated pattern with coercion functions (generated from the subsumption check 
by tcSub).  

So for now I'm just insisting on type *equality* in patterns.  No subsumption. 

Old notes about desugaring, at a time when pattern coercions were handled:

A SigPat is a type coercion and must be handled one at at time.  We can't
combine them unless the type of the pattern inside is identical, and we don't
bother to check for that.  For example:

	data T = T1 Int | T2 Bool
	f :: (forall a. a -> a) -> T -> t
	f (g::Int->Int)   (T1 i) = T1 (g i)
	f (g::Bool->Bool) (T2 b) = T2 (g b)

We desugar this as follows:

	f = \ g::(forall a. a->a) t::T ->
	    let gi = g Int
	    in case t of { T1 i -> T1 (gi i)
			   other ->
	    let	gb = g Bool
	    in case t of { T2 b -> T2 (gb b)
			   other -> fail }}

Note that we do not treat the first column of patterns as a
column of variables, because the coerced variables (gi, gb)
would be of different types.  So we get rather grotty code.
But I don't think this is a common case, and if it was we could
doubtless improve it.

Meanwhile, the strategy is:
	* treat each SigPat coercion (always non-identity coercions)
		as a separate block
	* deal with the stuff inside, and then wrap a binding round
		the result to bind the new variable (gi, gb, etc)


%************************************************************************
%*									*
\subsection{Errors and contexts}
%*									*
%************************************************************************

\begin{code}
patCtxt :: Pat Name -> Maybe Message	-- Not all patterns are worth pushing a context
patCtxt (VarPat _)  = Nothing
patCtxt (ParPat _)  = Nothing
patCtxt (AsPat _ _) = Nothing
patCtxt pat 	    = Just (hang (ptext (sLit "In the pattern:")) 
			       4 (ppr pat))

-----------------------------------------------

existentialExplode :: LPat Name -> SDoc
existentialExplode pat
  = hang (vcat [text "My brain just exploded.",
	        text "I can't handle pattern bindings for existential or GADT data constructors.",
	        text "Instead, use a case-expression, or do-notation, to unpack the constructor.",
		text "In the binding group for"])
	4 (ppr pat)

sigPatCtxt :: [LPat Var] -> [Var] -> [TcType] -> TcType -> TidyEnv
           -> TcM (TidyEnv, SDoc)
sigPatCtxt pats bound_tvs pat_tys body_ty tidy_env 
  = do	{ pat_tys' <- mapM zonkTcType pat_tys
	; body_ty' <- zonkTcType body_ty
	; let (env1,  tidy_tys)    = tidyOpenTypes tidy_env (map idType show_ids)
	      (env2, tidy_pat_tys) = tidyOpenTypes env1 pat_tys'
	      (env3, tidy_body_ty) = tidyOpenType  env2 body_ty'
	; return (env3,
		 sep [ptext (sLit "When checking an existential match that binds"),
		      nest 4 (vcat (zipWith ppr_id show_ids tidy_tys)),
		      ptext (sLit "The pattern(s) have type(s):") <+> vcat (map ppr tidy_pat_tys),
		      ptext (sLit "The body has type:") <+> ppr tidy_body_ty
		]) }
  where
    bound_ids = collectPatsBinders pats
    show_ids = filter is_interesting bound_ids
    is_interesting id = any (`elemVarSet` varTypeTyVars id) bound_tvs

    ppr_id id ty = ppr id <+> dcolon <+> ppr ty
	-- Don't zonk the types so we get the separate, un-unified versions

badFieldCon :: DataCon -> Name -> SDoc
badFieldCon con field
  = hsep [ptext (sLit "Constructor") <+> quotes (ppr con),
	  ptext (sLit "does not have field"), quotes (ppr field)]

polyPatSig :: TcType -> SDoc
polyPatSig sig_ty
  = hang (ptext (sLit "Illegal polymorphic type signature in pattern:"))
       2 (ppr sig_ty)

badSigPat :: TcType -> SDoc
badSigPat pat_ty = ptext (sLit "Pattern signature must exactly match:") <+> 
                   ppr pat_ty

badTypePat :: Pat Name -> SDoc
badTypePat pat = ptext (sLit "Illegal type pattern") <+> ppr pat

existentialProcPat :: DataCon -> SDoc
existentialProcPat con
  = hang (ptext (sLit "Illegal constructor") <+> quotes (ppr con) <+> ptext (sLit "in a 'proc' pattern"))
       2 (ptext (sLit "Proc patterns cannot use existentials or GADTs"))

lazyPatErr :: Pat name -> [TcTyVar] -> TcM ()
lazyPatErr _ tvs
  = failWithTc $
    hang (ptext (sLit "A lazy (~) pattern cannot match existential or GADT data constructors"))
       2 (vcat (map pprSkolTvBinding tvs))

nonRigidMatch :: PatCtxt -> DataCon -> SDoc
nonRigidMatch ctxt con
  =  hang (ptext (sLit "GADT pattern match in non-rigid context for") <+> quotes (ppr con))
	2 (ptext (sLit "Probable solution: add a type signature for") <+> what ctxt)
  where
     what (APat (FunRhs f _)) = quotes (ppr f)
     what (APat CaseAlt)      = ptext (sLit "the scrutinee of the case expression")
     what (APat LambdaExpr )  = ptext (sLit "the lambda expression")
     what (APat (StmtCtxt _)) = ptext (sLit "the right hand side of a do/comprehension binding")
     what _other	      = ptext (sLit "something")

nonRigidResult :: PatCtxt -> Type -> TcM a
nonRigidResult ctxt res_ty
  = do	{ env0 <- tcInitTidyEnv
	; let (env1, res_ty') = tidyOpenType env0 res_ty
	      msg = hang (ptext (sLit "GADT pattern match with non-rigid result type")
				<+> quotes (ppr res_ty'))
		  	 2 (ptext (sLit "Solution: add a type signature for")
			   	  <+> what ctxt )
	; failWithTcM (env1, msg) }
  where
     what (APat (FunRhs f _)) = quotes (ppr f)
     what (APat CaseAlt)      = ptext (sLit "the entire case expression")
     what (APat LambdaExpr)   = ptext (sLit "the lambda exression")
     what (APat (StmtCtxt _)) = ptext (sLit "the entire do/comprehension expression")
     what _other              = ptext (sLit "something")
\end{code}
