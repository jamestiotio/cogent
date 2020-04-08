--
-- Copyright 2018, Data61
-- Commonwealth Scientific and Industrial Research Organisation (CSIRO)
-- ABN 41 687 119 230.
--
-- This software may be distributed and modified according to the terms of
-- the GNU General Public License version 2. Note that NO WARRANTY is provided.
-- See "LICENSE_GPLv2.txt" for details.
--
-- @TAG(DATA61_GPL)
--

{-# OPTIONS_GHC -Werror -Wall #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cogent.TypeCheck.Solver.SinkFloat ( sinkfloat ) where

--
-- Sink/Float is a type inference phase which pushes structural information
-- through subtyping constraints (sinking it down or floating it up).
--
-- In particular, this means adding missing fields to record and variant rows
-- and breaking single unification variables unified with a tuple into a tuple
-- of unification variables. Note that type operators do not change the
-- structure of a type, and so this phase propagates this information through
-- these.
--

import Cogent.Common.Types
import Cogent.Surface (Type(..))
import Cogent.TypeCheck.Base
import Cogent.TypeCheck.Solver.Goal
import Cogent.TypeCheck.Solver.Monad
import qualified Cogent.TypeCheck.Solver.Rewrite as Rewrite
import qualified Cogent.TypeCheck.Row as Row
import qualified Cogent.TypeCheck.Subst as Subst

import Control.Applicative (empty)
import Control.Monad.Writer
import Control.Monad.Trans.Maybe
import qualified Data.Map as M
import Lens.Micro

sinkfloat :: Rewrite.RewriteT TcSolvM [Goal]
sinkfloat = Rewrite.rewrite' $ \gs ->
  let mentions = getMentions gs
      cs = map (strip . _goal) gs in
  {- MaybeT TcSolvM -}
  do a <- MaybeT $ do {- TcSolvM -}
       ms <- mapM (runMaybeT . (genStructSubst mentions)) cs -- a list of 'Maybe' substitutions.
       return . getFirst . mconcat $ First <$> ms -- only return the first 'Just' substitution.
     tell [a]
     return $ map (goal %~ Subst.applyC a) gs
  where
    strip :: Constraint -> Constraint
    strip (T (TBang t)    :<  v          )   = t :< v
    strip (v              :<  T (TBang t))   = v :< t
    strip (T (TBang t)    :=: v          )   = t :=: v
    strip (v              :=: T (TBang t))   = v :=: t
    strip (T (TUnbox t)  :<  v           )   = t :< v
    strip (v             :<  T (TUnbox t))   = v :< t
    strip (T (TUnbox t)  :=: v          )    = t :=: v
    strip (v             :=: T (TUnbox t))   = v :=: t
    strip c = c

    -- For sinking row information in a subtyping constraint
    canSink :: M.Map Int (Int,Int) -> Int -> Bool
    canSink mentions v | Just m <- M.lookup v mentions = fst m <= 1
                       | otherwise = False

    canFloat :: M.Map Int (Int,Int) -> Int -> Bool
    canFloat mentions v | Just m <- M.lookup v mentions = snd m <= 1
                        | otherwise = False

    genStructSubst :: M.Map Int (Int,Int) -> Constraint -> MaybeT TcSolvM Subst.Subst
    -- record rows
    genStructSubst _ (R rp r s :< U i) = do
      s' <- case s of
        Left Unboxed -> return $ Left Unboxed -- unboxed is preserved by bang and TUnbox, so we may propagate it
        _            -> Right <$> lift solvFresh
      makeRowUnifSubsts (flip (R rp) s') (filter Row.taken (Row.entries r)) i
    genStructSubst _ (U i :< R rp r s) = do
      s' <- case s of
        Left Unboxed -> return $ Left Unboxed -- unboxed is preserved by bang and TUnbox, so we may propagate it
        _            ->  Right <$> lift solvFresh
      -- Subst. a record structure for the unifier with only present entries of
      -- the record r (respecting the lattice order for records).
      makeRowUnifSubsts (flip (R rp) s') (filter (not . Row.taken) (Row.entries r)) i
    genStructSubst mentions (R _ r1 s1 :< R _ r2 s2)
      {- The most tricky case.
         For Records, present is the bottom of the order, taken is the top.
         If present things are in r2, then we can infer they must be in r1.
         If taken things are in r1, then we can infer they must be in r2.
      -}
      | es <- filter (\e -> not (Row.taken e) && not (e `elem` (Row.entries r1)))
                     (Row.entries r2)
      , not $ null es
      , Just rv <- Row.var r1
         = makeRowVarSubsts rv es
      | es <- filter (\e -> (Row.taken e) && not (e `elem` (Row.entries r2)))
                     (Row.entries r1)
      , not $ null es
      , Just rv <- Row.var r2
         = makeRowVarSubsts rv es

      | Row.isComplete r2 && all (`elem` Row.entries r2) (Row.entries r1)
      , Just rv <- Row.var r1
      , es <- filter (\e -> (Row.taken e) && not (e `elem` (Row.entries r1)))
                     (Row.entries r2)
      , canSink mentions rv && not (null es)
         = makeRowVarSubsts rv es

      | Row.isComplete r1 && all (`elem` Row.entries r1) (Row.entries r2)
      , Just rv <- Row.var r2
      , es <- filter (\e -> not (Row.taken e) && not (e `elem` (Row.entries r2)))
                     (Row.entries r1)
      , canFloat mentions rv && not (null es)
         = makeRowVarSubsts rv es

      | Row.isComplete r1
      , null (Row.diff r1 r2)
      , Just rv <- Row.var r2
         = makeRowShapeSubsts rv r1

      | Row.isComplete r2
      , null (Row.diff r2 r1)
      , Just rv <- Row.var r1
         = makeRowShapeSubsts rv r2
  
      | Left Unboxed <- s1 , Right i <- s2 = return $ Subst.ofSigil i Unboxed
      | Right i <- s1 , Left Unboxed <- s2 = return $ Subst.ofSigil i Unboxed

    genStructSubst (R rp r s :~~ U i) = do
      s' <- case s of
              Left Unboxed -> return $ Left Unboxed
              _            -> Right <$> lift solvFresh
      makeRowUnifSubsts (flip (R rp) s') r i
    genStructSubst (U i :~~ R rp r s) = do
      s' <- case s of
              Left Unboxed -> return $ Left Unboxed
              _            -> Right <$> lift solvFresh
      makeRowUnifSubsts (flip (R rp) s') r i

    -- variant rows
    genStructSubst _ (V r :< U i) =
      makeRowUnifSubsts V (filter (not . Row.taken) (Row.entries r)) i
    genStructSubst _ (U i :< V r) =
      makeRowUnifSubsts V (filter Row.taken (Row.entries r)) i
    genStructSubst mentions (V r1 :< V r2)
      {- The most tricky case.
         For variants, taken is the bottom of the order, taken is the top.
         If taken things are in r2, then we can infer they must be in r1.
         If present things are in r1, then we can infer they must be in r2.
       -}
      | es <- filter (\e -> (Row.taken e) && not (e `elem` (Row.entries r1)))
                   (Row.entries r2)
      , not $ null es
      , Just rv <- Row.var r1
         = makeRowVarSubsts rv es
      | es <- filter (\e -> not (Row.taken e) && not (e `elem` (Row.entries r2)))
                     (Row.entries r1)
      , not $ null es
      , Just rv <- Row.var r2
         = makeRowVarSubsts rv es

      | Row.isComplete r2 && all (`elem` Row.entries r2) (Row.entries r1)
      , Just rv <- Row.var r1
      , es <- filter (\e -> not (Row.taken e) && not (e `elem` (Row.entries r1)))
                     (Row.entries r2)
      , canSink mentions rv && not (null es)
         = makeRowVarSubsts rv es

      | Row.isComplete r1 && all (`elem` Row.entries r1) (Row.entries r2)
      , Just rv <- Row.var r2
      , es <- filter (\e -> (Row.taken e) && not (e `elem` (Row.entries r2)))
                     (Row.entries r1)
      , canFloat mentions rv && not (null es)
         = makeRowVarSubsts rv es

      | Row.isComplete r1
      , null (Row.diff r1 r2)
      , Just rv <- Row.var r2
         = makeRowShapeSubsts rv r1

      | Row.isComplete r2
      , null (Row.diff r2 r1)
      , Just rv <- Row.var r1
         = makeRowShapeSubsts rv r2

    genStructSubst (V r :~~ U i) = makeRowUnifSubsts V r i
    genStructSubst (U i :~~ V r) = makeRowUnifSubsts V r i

    -- tuples
    genStructSubst _ (T (TTuple ts) :< U i) = makeTupleUnifSubsts ts i
    genStructSubst _ (U i :< T (TTuple ts)) = makeTupleUnifSubsts ts i
    genStructSubst _ (T (TTuple ts) :=: U i) = makeTupleUnifSubsts ts i
    genStructSubst _ (U i :=: T (TTuple ts)) = makeTupleUnifSubsts ts i

    -- tcon
    genStructSubst _ (T (TCon n ts s) :< U i) = makeTConUnifSubsts n ts s i
    genStructSubst _ (U i :< T (TCon n ts s)) = makeTConUnifSubsts n ts s i
    genStructSubst _ (T (TCon n ts s) :=: U i) = makeTConUnifSubsts n ts s i
    genStructSubst _ (U i :=: T (TCon n ts s)) = makeTConUnifSubsts n ts s i

    -- tfun
    genStructSubst _ (T (TFun _ _) :< U i)  = makeFunUnifSubsts i
    genStructSubst _ (U i :< T (TFun _ _))  = makeFunUnifSubsts i
    genStructSubst _ (T (TFun _ _) :=: U i) = makeFunUnifSubsts i
    genStructSubst _ (U i :=: T (TFun _ _)) = makeFunUnifSubsts i

    -- tunit
    genStructSubst _ (t@(T TUnit) :< U i) = return $ Subst.ofType i t
    genStructSubst _ (U i :< t@(T TUnit)) = return $ Subst.ofType i t
    genStructSubst _ (t@(T TUnit) :=: U i) = return $ Subst.ofType i t
    genStructSubst _ (U i :=: t@(T TUnit)) = return $ Subst.ofType i t

    -- default
    genStructSubst _ _ = empty

    --
    -- Helper Functions
    --

    makeEntryUnif e = Row.mkEntry <$>
                      pure (Row.fname e) <*>
                      (U <$> lift solvFresh) <*> pure (Row.taken e)

    -- Substitute a record structure for the unifier with only the specified
    -- entries, hence an incomplete record.
    makeRowUnifSubsts frow es u =
      do rv <- lift solvFresh
         es' <- traverse makeEntryUnif es
         return $ Subst.ofType u (frow (Row.incomplete es' rv))

    -- Expand rows containing row variable rv with the specified entries.
    makeRowVarSubsts rv es =
      do rv' <- lift solvFresh
         es' <- traverse makeEntryUnif es
         return $ Subst.ofRow rv $ Row.incomplete es' rv'

    -- Create a shape substitution for the row variable.
    makeRowShapeSubsts rv row =
      return $ Subst.ofShape rv (Row.shape row)

    makeTupleUnifSubsts ts i = do
      tus <- traverse (const (U <$> lift solvFresh)) ts
      let t = T (TTuple tus)
      return $ Subst.ofType i t

    makeFunUnifSubsts i = do
      t' <- U <$> lift solvFresh
      u' <- U <$> lift solvFresh
      return . Subst.ofType i . T $ TFun t' u'

    makeTConUnifSubsts n ts s i = do
      tus <- traverse (const (U <$> lift solvFresh)) ts
      let t = T (TCon n tus s)  -- FIXME: A[R] :< (?0)! will break if ?0 ~> A[W] is needed somewhere else
      return $ Subst.ofType i t

