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

{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

module Cogent.TypeCheck.Base where

import Cogent.Common.Syntax
import Cogent.Common.Types
import Cogent.Compiler
import Cogent.Surface
import Cogent.TypeCheck.Util
import Cogent.Util

import Control.Arrow (second)
import Control.Lens hiding (Context, (:<))
-- import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Trans.Maybe
import Control.Monad.Writer hiding (Alt)
import Data.Either (either)
import qualified Data.IntMap as IM
import Data.List (nub, (\\))
import qualified Data.Map as M
import Data.Monoid ((<>))
import qualified Data.Sequence as Seq
-- import qualified Data.Set as S
import Text.Parsec.Pos


data TypeError = FunctionNotFound VarName
               | TooManyTypeArguments FunName (Polytype TCType)
               | NotInScope FuncOrVar VarName
               | DuplicateVariableInPattern VarName  -- (Pattern TCName)
               | DifferingNumberOfConArgs TagName Int Int
               -- | DuplicateVariableInIrrefPattern VarName (IrrefutablePattern TCName)
               | UnknownTypeVariable VarName
               | UnknownTypeConstructor TypeName
               | TypeArgumentMismatch TypeName Int Int
               | TypeMismatch (TypeFragment TCType) (TypeFragment TCType)
               | RequiredTakenField FieldName TCType
               | TypeNotShareable TCType Metadata
               | TypeNotEscapable TCType Metadata
               | TypeNotDiscardable TCType Metadata
               | PatternsNotExhaustive TCType [TagName]
               | UnsolvedConstraint Constraint (IM.IntMap VarOrigin)
               | RecordWildcardsNotSupported
               | NotAFunctionType TCType
               | DuplicateRecordFields [FieldName]
               | DuplicateTypeVariable [VarName]
               | TakeFromNonRecordOrVariant (Maybe [FieldName]) TCType
               | PutToNonRecordOrVariant    (Maybe [FieldName]) TCType
               | TakeNonExistingField FieldName TCType
               | PutNonExistingField  FieldName TCType
               | DiscardWithoutMatch TagName
               | RequiredTakenTag TagName
               | CustTyGenIsPolymorphic TCType
               | CustTyGenIsSynonym TCType
               | TypeWarningAsError TypeWarning
               deriving (Eq, Show, Ord)

isWarnAsError :: TypeError -> Bool
isWarnAsError (TypeWarningAsError _) = True
isWarnAsError _ = False

data TypeWarning = UnusedLocalBind VarName
                 | TakeTakenField  FieldName TCType
                 | PutUntakenField FieldName TCType
                 deriving (Eq, Show, Ord)

type TypeEW = Either TypeError TypeWarning

-- FIXME: More fine-grained context is appreciated. e.g., only show alternatives that don't unify / zilinc
data ErrorContext = InExpression LocExpr TCType
                  | InPattern LocPatn
                  | InIrrefutablePattern LocIrrefPatn
                  | ThenBranch | ElseBranch
                  | SolvingConstraint Constraint
                  | NthAlternative Int LocPatn
                  | InDefinition SourcePos (TopLevel LocType LocPatn LocExpr)
                  | AntiquotedType LocType
                  | AntiquotedExpr LocExpr
                  | CustomisedCodeGen LocType
                  deriving (Eq, Show)

instance Ord ErrorContext where
  compare _ _ = EQ 

isCtxConstraint :: ErrorContext -> Bool
isCtxConstraint (SolvingConstraint _) = True
isCtxConstraint _ = False

data Bound = GLB | LUB deriving (Eq, Ord)

instance Show Bound where
  show GLB = "lower bound"
  show LUB = "upper bound"

data VarOrigin = ExpressionAt SourcePos
               | BoundOf (TypeFragment TCType) (TypeFragment TCType) Bound
               deriving (Eq, Show, Ord)


-- high-level context at the end of the list
type ContextualisedError   = ([ErrorContext], TypeError)
type ContextualisedWarning = ([ErrorContext], TypeWarning)

data Metadata = Reused { varName :: VarName, boundAt :: SourcePos, usedAt :: Seq.Seq SourcePos }
              | Unused { varName :: VarName, boundAt :: SourcePos }
              | UnusedInOtherBranch { varName :: VarName, boundAt :: SourcePos, usedAt :: Seq.Seq SourcePos }
              | UnusedInThisBranch  { varName :: VarName, boundAt :: SourcePos, usedAt :: Seq.Seq SourcePos }
              | Suppressed
              | UsedInMember { fieldName :: FieldName }
              | UsedInLetBang
              | TypeParam { functionName :: VarName, typeVarName :: VarName }
              | ImplicitlyTaken
              | Constant { varName :: VarName }
              deriving (Eq, Show, Ord)

data Constraint = (:<) (TypeFragment TCType) (TypeFragment TCType)
                | (:&) Constraint Constraint
                | Upcastable TCType TCType
                | Share TCType Metadata
                | Drop TCType Metadata
                | Escape TCType Metadata
                | (:@) Constraint ErrorContext
                | Unsat TypeError
                | SemiSat TypeWarning
                | Sat
                | Exhaustive TCType [RawPatn]
                deriving (Eq, Show, Ord)

instance Monoid Constraint where
  mempty = Sat
  mappend Sat x = x
  mappend x Sat = x
  -- mappend (Unsat r) x = Unsat r
  -- mappend x (Unsat r) = Unsat r
  mappend x y = x :& y

kindToConstraint :: Kind -> TCType -> Metadata -> Constraint
kindToConstraint k t m = (if canEscape  k then Escape t m else Sat)
                      <> (if canDiscard k then Drop   t m else Sat)
                      <> (if canShare   k then Share  t m else Sat)

warnToConstraint :: Bool -> TypeWarning -> Constraint
warnToConstraint f w | f = SemiSat w
                     | otherwise = Sat
-- warnToConstraint f w 
--   | f = case __cogent_warning_switch of
--           Flag_w -> Sat
--           Flag_Wwarn -> SemiSat w
--           Flag_Werror -> Unsat (TypeWarningAsError w)
--   | otherwise = Sat



data TypeFragment a = F a
                    | FRecord [(FieldName, (a, Taken))]
                    | FVariant (M.Map TagName ([a], Taken))
                    deriving (Eq, Show, Functor, Foldable, Traversable, Ord)

data TCType       = T (Type TCType)
                  | U Int  -- unifier
                  deriving (Show, Eq, Ord)

data FuncOrVar = MustFunc | MustVar | FuncOrVar deriving (Eq, Ord, Show)

funcOrVar :: TCType -> FuncOrVar
funcOrVar (U _) = FuncOrVar
funcOrVar (T (TVar  {})) = FuncOrVar
funcOrVar (T (TUnbox _)) = FuncOrVar
funcOrVar (T (TBang  _)) = FuncOrVar
funcOrVar (T (TFun {})) = MustFunc
funcOrVar _ = MustVar

data TExpr      t = TE { getTypeTE :: t, getExpr :: Expr t (TPatn t) (TIrrefPatn t) (TExpr t), getLocTE :: SourcePos }
deriving instance Show t => Show (TExpr t)

data TPatn      t = TP { getPatn :: Pattern (TIrrefPatn t), getLocTP :: SourcePos }
deriving instance Eq   t => Eq   (TPatn t)
deriving instance Ord  t => Ord  (TPatn t)
deriving instance Show t => Show (TPatn t)

data TIrrefPatn t = TIP { getIrrefPatn :: IrrefutablePattern (VarName, t) (TIrrefPatn t), getLocTIP :: SourcePos }
deriving instance Eq   t => Eq   (TIrrefPatn t)
deriving instance Ord  t => Ord  (TIrrefPatn t)
deriving instance Show t => Show (TIrrefPatn t)

instance Functor TExpr where
  fmap f (TE t e l) = TE (f t) (ffffmap f $ fffmap (fmap f) $ ffmap (fmap f) $ fmap (fmap f) e) l  -- Hmmm!
instance Functor TPatn where
  fmap f (TP p l) = TP (fmap (fmap f) p) l
instance Functor TIrrefPatn where
  fmap f (TIP ip l) = TIP (ffmap (second f) $ fmap (fmap f) ip) l

type TCName = (VarName, TCType)
type TCExpr = TExpr TCType
type TCPatn = TPatn TCType
type TCIrrefPatn = TIrrefPatn TCType

type TypedName = (VarName, RawType)
type TypedExpr = TExpr RawType
type TypedPatn = TPatn RawType
type TypedIrrefPatn = TIrrefPatn RawType

toTCType :: RawType -> TCType
toTCType (RT x) = T (fmap toTCType x)

-- Precondition: No unification variables left in the type
toLocType :: SourcePos -> TCType -> LocType
toLocType l (T x) = LocType l (fmap (toLocType l) x)
-- toLocType l (RemoveCase p t) = error "panic: removeCase found"
toLocType l _ = error "panic: unification variable found"

toLocExpr :: (SourcePos -> t -> LocType) -> TExpr t -> LocExpr
toLocExpr f (TE t e l) = LocExpr l (ffffmap (f l) $ fffmap (toLocPatn f) $ ffmap (toLocIrrefPatn f) $ fmap (toLocExpr f) e)

toLocPatn :: (SourcePos -> t -> LocType) -> TPatn t -> LocPatn
toLocPatn f (TP p l) = LocPatn l (fmap (toLocIrrefPatn f) p)

toLocIrrefPatn :: (SourcePos -> t -> LocType) -> TIrrefPatn t -> LocIrrefPatn
toLocIrrefPatn f (TIP p l) = LocIrrefPatn l (ffmap fst $ fmap (toLocIrrefPatn f) p)

toTypedExpr :: TCExpr -> TypedExpr
toTypedExpr = fmap toRawType

toTypedAlts :: [Alt TCPatn TCExpr] -> [Alt TypedPatn TypedExpr]
toTypedAlts = fmap (fmap (fmap toRawType) . ffmap (fmap toRawType))

toRawType :: TCType -> RawType
toRawType (T x) = RT (fmap toRawType x)
-- toRawType (RemoveCase p t) = error "panic: removeCase found"
toRawType _ = error "panic: unification variable found"

toRawExp :: TypedExpr -> RawExpr
toRawExp (TE t e _) = RE (fffmap toRawPatn . ffmap toRawIrrefPatn . fmap toRawExp $ e)

toRawPatn :: TypedPatn -> RawPatn
toRawPatn (TP p _) = RP (fmap toRawIrrefPatn p)

toRawIrrefPatn :: TypedIrrefPatn -> RawIrrefPatn
toRawIrrefPatn (TIP ip _) = RIP (ffmap fst $ fmap toRawIrrefPatn ip)



type TypeDict = [(TypeName, ([VarName], Maybe TCType))]  -- `Nothing' for abstract types

data TCState = TCS { _knownFuns    :: M.Map FunName (Polytype TCType)
                   , _knownTypes   :: TypeDict
                   , _knownConsts  :: M.Map VarName (TCType, SourcePos)
                   , _errors       :: [ContextualisedError]
                   , _warnings     :: [ContextualisedWarning]
                   , _errContext   :: [ErrorContext]
                   }

makeLenses ''TCState

type TcM lcl a = EnvM' TCState lcl a
type TcBaseM a = TcM () a

runTcM :: lcl -> TcM lcl a -> TcBaseM (a, lcl)
runTcM lcl ma = EnvM $ MaybeT $ StateT $ \(Env glb _) -> do 
                  (a, Env glb' lcl') <- flip runStateT (Env glb lcl) $ runMaybeT $ runEnvM ma
                  return (fmap ((,lcl')) a, Env glb' ()) 

zoom :: TcBaseM a -> TcM lcl a
zoom ma = EnvM $ MaybeT $ StateT $ \(Env glb lcl) -> do
            (a, Env glb' _) <- flip runStateT (Env glb ()) $ runMaybeT $ runEnvM ma
            return (a, Env glb' lcl)

typeErr :: TypeError -> TcM lcl ()
typeErr e = typeErr_ =<< ((,e) <$> use (env_glb.errContext))

typeErr_ :: ContextualisedError -> TcM lcl ()
typeErr_ e = (env_glb.errors) %= (++[e])

typeErrs_ :: [ContextualisedError] -> TcM lcl ()
typeErrs_ es = (env_glb.errors) %= (++es)

typeErrExit :: TypeError -> TcM lcl a
typeErrExit e = typeErr e >> exitErr

typeWarn :: TypeWarning -> TcM lcl ()
typeWarn w = typeWarn_ =<< ((,w) <$> use (env_glb.errContext))

typeWarn_ :: ContextualisedWarning -> TcM lcl ()
typeWarn_ w = case __cogent_warning_switch of
                Flag_w -> return ()
                Flag_Wwarn -> (env_glb.warnings) %= (++[w])
                Flag_Werror -> (env_glb.errors) %= (++[warnToErr w])

typeWarns_ :: [ContextualisedWarning] -> TcM lcl ()
typeWarns_ ws = mapM_ typeWarn_ ws

warnToErr :: ContextualisedWarning -> ContextualisedError
warnToErr = second TypeWarningAsError

exitErr :: TcM lcl a
exitErr = EnvM $ MaybeT $ StateT $ \s -> return (Nothing, s)

exitOnErr :: TcM lcl a -> TcM lcl a
exitOnErr ma = do a <- ma
                  errs <- use (env_glb.errors)
                  if null errs then return a else exitErr

substType :: [(VarName, TCType)] -> TCType -> TCType
substType vs (U x) = U x
-- substType vs (RemoveCase p x) = RemoveCase (fmap (fmap (substType vs)) p) (substType vs x)
substType vs (T (TVar v False )) | Just x <- lookup v vs = x
substType vs (T (TVar v True  )) | Just x <- lookup v vs = T (TBang x)
substType vs (T t) = T (fmap (substType vs) t)

-- Check for type well-formedness
validateType :: [VarName] -> RawType -> TcM lcl TCType
validateType vs t = either typeErrExit return =<< validateType' vs t

-- don't log erros, but instead return them
validateType' :: [VarName] -> RawType -> TcM lcl (Either TypeError TCType)
validateType' vs (RT t) = do
  ts <- use (env_glb.knownTypes)
  case t of
    TVar v _    | v `notElem` vs         -> return (Left $ UnknownTypeVariable v)
    TCon t as _ | Nothing <- lookup t ts -> return (Left $ UnknownTypeConstructor t)
                | Just (vs, _) <- lookup t ts
                , provided <- length as
                , required <- length vs
                , provided /= required
               -> return (Left $ TypeArgumentMismatch t provided required)
    TRecord fs _ | fields  <- map fst fs
                 , fields' <- nub fields
                -> if fields' == fields
                   then return . fmap T . sequence =<< traverse (validateType' vs) t
                   else return (Left $ DuplicateRecordFields (fields \\ fields'))
    _ -> return . fmap T . sequence =<< traverse (validateType' vs) t

validateTypes' :: (Traversable t) => [VarName] -> t RawType -> TcM lcl (Either TypeError (t TCType))
validateTypes' vs rs = sequence <$> traverse (validateType' vs) rs


-- Remove a pattern from a type, for case expressions.
removeCase :: LocPatn -> TCType -> TCType
removeCase (LocPatn _ (PIrrefutable _)) _ = (T (TVariant M.empty))
removeCase (LocPatn _ (PIntLit  _))     x = x
removeCase (LocPatn _ (PCharLit _))     x = x
removeCase (LocPatn _ (PBoolLit _))     x = x
removeCase (LocPatn _ (PCon t _))       x = (T (TTake (Just [t]) x))

forFlexes :: (Int -> TCType) -> TCType -> TCType
forFlexes f (U x) = f x
-- forFlexes f (RemoveCase p t) = let
--     p' = fmap (fmap (forFlexes f)) p
--     t' = forFlexes f t
--   in case removeCase p' t' of
--      Just t' -> t'
--      Nothing -> RemoveCase p' t'
forFlexes f (T x) = T (fmap (forFlexes f) x)

flexOf (U x) = Just x
flexOf (T (TTake _ v)) = flexOf v
flexOf (T (TPut  _ v)) = flexOf v
flexOf (T (TBang v))   = flexOf v
flexOf (T (TUnbox v))  = flexOf v
flexOf _ = Nothing


isSynonym :: RawType -> TcM lcl Bool
isSynonym (RT (TCon c _ _)) = lookup c <$> use (env_glb.knownTypes) >>= \case
  Nothing -> __impossible "isSynonym: type not in scope"
  Just (vs,Just _ ) -> return True
  Just (vs,Nothing) -> return False
isSynonym (RT t) = foldM (\b a -> (b ||) <$> isSynonym a) False t

isIntType :: RawType -> Bool
isIntType (RT (TCon cn ts s)) | cn `elem` words "U8 U16 U32 U64", null ts, s == Unboxed = True
isIntType _ = False

isVariantType :: RawType -> Bool
isVariantType (RT (TVariant _)) = True
isVariantType _ = False

isMonoType :: RawType -> Bool
isMonoType (RT (TVar {})) = False
isMonoType (RT t) = getAll $ foldMap (All . isMonoType) t

