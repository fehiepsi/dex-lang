-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE StandaloneDeriving #-}

module SaferNames.Type (
  HasType (..), CheckableE (..), CheckableB (..),
  checkModule, checkTypes, getType, litType, getBaseMonoidType,
  instantiatePi, checkExtends, applyDataDefParams, indices,
  caseAltsBinderTys, tryGetType, projectLength) where

import Prelude hiding (id)
import Control.Category ((>>>))
import Control.Monad
import Control.Monad.Reader
import Data.Foldable (toList)
import Data.Functor
import Data.Int
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as M
import qualified Data.Set        as S

import LabeledItems

import Err
import Type (litType)
import Util (forMZipped, forMZipped_, iota)

import SaferNames.Syntax
import SaferNames.Name
import SaferNames.PPrint ()

-- === top-level API ===

checkModule :: (Distinct n, Fallible m) => Bindings n -> Module n -> m ()
checkModule bindings m =
  addContext ("Checking module:\n" ++ pprint m) $ asCompilerErr $
    runBindingsReaderT bindings $
      checkTypes m

checkTypes :: (BindingsReader m, Fallible1 m, CheckableE e)
           => e n -> m n ()
checkTypes e = do
  Distinct <- getDistinct
  WithBindings bindings e' <- addBindings e
  liftExcept $ runTyperT bindings $ void $ checkE e'

getType :: (BindingsReader m, HasType e)
           => e n -> m n (Type n)
getType e = do
  Distinct <- getDistinct
  WithBindings bindings e' <- addBindings e
  injectM $ runHardFail $ runTyperT bindings $ getTypeE e'

tryGetType :: (BindingsReader m, Fallible1 m, HasType e) => e n -> m n (Type n)
tryGetType e = do
  Distinct <- getDistinct
  WithBindings bindings e' <- addBindings e
  ty <- liftExcept $ runTyperT bindings $ getTypeE e'
  injectM ty

instantiatePi :: ScopeReader m => PiType n -> Atom n -> m n (EffectRow n, Atom n)
instantiatePi (PiType b eff body) x = do
  PairE eff' body' <- applyAbs (Abs b (PairE eff body)) (SubstVal x)
  return (eff', body')

-- === the type checking/querying monad ===

-- TODO: not clear why we need the explicit `Monad2` here since it should
-- already be a superclass, transitively, through both Fallible2 and
-- MonadAtomSubst.
class ( Monad2 m, Fallible2 m, EnvReader Name m
      , BindingsGetter2 m, BindingsExtender2 m)
     => Typer (m::MonadKind2)

newtype TyperT (m::MonadKind) (i::S) (o::S) (a :: *) =
  TyperT { runTyperT' :: EnvReaderT Name (BindingsReaderT m) i o a }
  deriving ( Functor, Applicative, Monad
           , EnvReader Name
           , MonadFail
           , Fallible
           , ScopeReader, ScopeGetter, BindingsReader
           , BindingsGetter, Scopable, BindingsExtender)

runTyperT :: (Fallible m, Distinct n)
          => Bindings n -> TyperT m n n a -> m a
runTyperT bindings m = do
  runBindingsReaderT bindings $
    runEnvReaderT idEnv $
      runTyperT' m

instance Fallible m => Typer (TyperT m)

-- === typeable things ===

-- Minimal complete definition: getTypeE | getTypeAndSubstE
-- (Usually we just implement `getTypeE` but for big things like blocks it can
-- be worth implementing the specialized versions too, as optimizations.)
class (InjectableE e, SubstE Name e) => HasType (e::E) where
  getTypeE   :: Typer m => e i -> m i o (Type o)
  getTypeE e = snd <$> getTypeAndSubstE e

  getTypeAndSubstE :: Typer m => e i -> m i o (e o, Type o)
  getTypeAndSubstE e = (,) <$> substM e <*> getTypeE e

  checkTypeE :: Typer m => Type o -> e i -> m i o (e o)
  checkTypeE reqTy e = do
    (e', ty) <- getTypeAndSubstE e
    checkAlphaEq reqTy ty
    return e'

class (InjectableE e, SubstE Name e) => CheckableE (e::E) where
  checkE :: Typer m => e i -> m i o (e o)

class HasNamesB b => CheckableB (b::B) where
  checkB :: Typer m
         => b i i'
         -> (forall o'. Ext o o' => b o o' -> m i' o' a)
         -> m i o a

checkBEvidenced :: (CheckableB b, Typer m)
                => b i i'
                -> (forall o'. ExtEvidence o o' -> b o o' -> m i' o' a)
                -> m i o a
checkBEvidenced b cont = checkB b \b' -> cont getExtEvidence b'

-- === convenience functions ===

infixr 7 |:
(|:) :: (Typer m, HasType e) => e i -> Type o -> m i o ()
(|:) x reqTy = void $ checkTypeE reqTy x

-- === Module interfaces ===

instance CheckableE Module where
  checkE (Module ir decls evaluated) = do
    -- TODO: need to add back the IR check. Should we just do it alongside type checking
    -- instead of as a separate pass?
    -- addContext "Checking IR variant" $ checkModuleVariant m
    addContext "Checking module body" $
      checkB decls \decls' -> do
        addContext "Checking module result" do
          evaluated' <- checkE evaluated
          return $ Module ir decls' evaluated'

instance CheckableE EvaluatedModule where
  checkE (EvaluatedModule bindings scs sourceMap) =
    checkB bindings \bindings' -> do
      scs' <- checkE scs
      sourceMap' <- checkE sourceMap
      return $ EvaluatedModule bindings' scs' sourceMap'

instance CheckableE SourceMap where
  checkE sourceMap = substM sourceMap

instance CheckableE SynthCandidates where
  checkE (SynthCandidates xs ys zs) =
    SynthCandidates <$> mapM checkE xs
                    <*> mapM checkE ys
                    <*> mapM checkE zs

instance CheckableB BindingsFrag where
  checkB (BindingsFrag frag effs) cont = do
    scope <- getScope
    env <- getEnv
    Distinct <- getDistinct
    DistinctAbs frag' env' <- return $ refreshRecEnvFrag scope env frag
    extendBindings (BindingsFrag frag' Nothing) do
      void $ dropSubst $ traverseEnvFrag checkE $ fromRecEnvFrag frag'
      withEnv env' do
        effs' <- mapM checkE effs
        cont $ BindingsFrag frag' effs'

instance NameColor c => CheckableE (Binding c) where
  checkE binding = case binding of
    AtomNameBinding   atomNameBinding -> AtomNameBinding <$> checkE atomNameBinding
    DataDefBinding    dataDef         -> DataDefBinding  <$> checkE dataDef
    TyConBinding      dataDefName     -> TyConBinding    <$> substM dataDefName
    DataConBinding    dataDefName idx -> DataConBinding  <$> substM dataDefName <*> pure idx
    ClassBinding      classDef        -> ClassBinding    <$> substM classDef
    SuperclassBinding className idx e -> SuperclassBinding <$> substM className <*> pure idx <*> substM e
    MethodBinding     className idx e -> MethodBinding     <$> substM className <*> pure idx <*> substM e

instance CheckableE AtomBinding where
  checkE binding = case binding of
    LetBound letBinding -> LetBound    <$> checkE letBinding
    LamBound lamBinding -> LamBound    <$> checkE lamBinding
    PiBound  piBinding  -> PiBound     <$> checkE piBinding
    MiscBound ty        -> MiscBound   <$> checkTypeE TyKind ty
    SolverBound b       -> SolverBound <$> checkE b

instance CheckableE SolverBinding where
  checkE (InfVarBound ty ctx) = InfVarBound <$> checkTypeE TyKind ty <*> pure ctx
  checkE (SkolemBound ty    ) = SkolemBound <$> checkTypeE TyKind ty

instance CheckableE DataDef where
  checkE = substM -- TODO

-- === type checking core ===

instance CheckableE Atom where
  checkE atom = fst <$> getTypeAndSubstE atom

instance HasType Atom where
  getTypeE atom = case atom of
    Var name -> do
      name' <- substM name
      bindingType <$> lookupBindings name'
    Lam lamExpr -> getTypeE lamExpr
    Pi piType -> getTypeE piType
    Con con  -> typeCheckPrimCon con
    TC tyCon -> typeCheckPrimTC  tyCon
    Eff eff  -> checkE eff $> EffKind
    DataCon _ (name,_) params con args -> do
      name' <- substM name
      funTy <- dataConFunType name' con
      foldM checkApp funTy $ params ++ args
    TypeCon (name, _) params -> do
      name' <- substM name
      funTy <- typeConFunType name'
      foldM checkApp funTy $ params
    LabeledRow row -> checkLabeledRow row $> LabeledRowKind
    Record items -> do
      types <- mapM getTypeE items
      return $ RecordTy (NoExt types)
    RecordTy row -> checkLabeledRow row $> TyKind
    Variant vtys@(Ext (LabeledItems types) _) label i arg -> do
      let ty = VariantTy vtys
      let argTy = do
            labelTys <- M.lookup label types
            guard $ i < length labelTys
            return $ labelTys NE.!! i
      case argTy of
        Just argType -> do
          argType' <- substM argType
          arg |: argType'
        Nothing -> throw TypeErr $ "Bad variant: " <> pprint atom
                                   <> " with type " <> pprint ty
      checkTypeE TyKind ty
    VariantTy row -> checkLabeledRow row $> TyKind
    ACase e alts resultTy -> checkCase e alts resultTy
    DataConRef (defName, _) params args -> do
      defName' <- substM defName
      DataDefBinding def@(DataDef _ paramBs [DataConDef _ argBs]) <- lookupBindings defName'
      paramTys <- nonDepBinderNestTypes paramBs
      params' <- forMZipped paramTys params checkTypeE
      argBs' <- applyNaryAbs (Abs paramBs argBs) (map SubstVal params')
      checkDataConRefBindings argBs' args
      return $ RawRefTy $ TypeCon (defName',def) params'
    BoxedRef ptr numel (Abs b@(_:>annTy) body) -> do
      PtrTy (_, t) <- getTypeE ptr
      annTy |: TyKind
      annTy' <- substM annTy
      checkAlphaEq annTy' (BaseTy t)
      numel |: IdxRepTy
      depTy <- refreshBinders b \b' -> do
        bodyTy <- getTypeE body
        return $ Abs b' bodyTy
      liftMaybe $ fromConstAbs depTy
    ProjectElt (i NE.:| is) v -> do
      ty <- getTypeE $ case NE.nonEmpty is of
              Nothing -> Var v
              Just is' -> ProjectElt is' v
      case ty of
        TypeCon (defName, _) params -> do
          v' <- substM v
          DataDefBinding def <- lookupBindings defName
          [DataConDef _ (Abs bs' UnitE)] <- applyDataDefParams def params
          PairB bsInit (Nest (_:>bTy) _) <- return $ splitNestAt i bs'
          -- `ty` can depends on earlier binders from this constructor. Rewrite
          -- it to also use projections.
          dropSubst $
            applyNaryAbs (Abs bsInit bTy) [ SubstVal (ProjectElt (j NE.:| is) v')
                                          | j <- iota $ nestLength bsInit]
        RecordTy (NoExt types) -> return $ toList types !! i
        RecordTy _ -> throw CompilerErr "Can't project partially-known records"
        ProdTy xs -> return $ xs !! i
        Var _ -> throw CompilerErr $ "Tried to project value of unreduced type " <> pprint ty
        _ -> throw TypeErr $
              "Only single-member ADTs and record types can be projected. Got " <> pprint ty <> "   " <> pprint v

instance (NameColor c, ToBinding ann c, CheckableE ann)
         => CheckableB (BinderP c ann) where
  checkB (b:>ann) cont = do
    ann' <- checkE ann
    withFreshNameBinder (getNameHint b) (toBinding ann') \b' ->
      extendRenamer (b@>binderName b') $
        cont $ b' :> ann'

instance HasType Expr where
  getTypeE expr = case expr of
    App f x -> do
      fTy <- getTypeE f
      checkApp fTy x
    Atom x   -> getTypeE x
    Op   op  -> typeCheckPrimOp op
    Hof  hof -> typeCheckPrimHof hof
    Case e alts resultTy -> checkCase e alts resultTy

instance HasType Block where
  getTypeE (Block ty decls expr) = do
    tyReq <- substM ty
    checkB decls \_ -> do
      tyReq' <- injectM tyReq
      expr |: tyReq'
    return tyReq

instance CheckableB Decl where
  checkB (Let b binding) cont =
    checkB (b:>binding) \(b':>binding') -> cont $ Let b' binding'

instance CheckableE DeclBinding where
  checkE (DeclBinding ann ty expr) = do
    ty' <- checkTypeE TyKind ty
    expr' <- checkTypeE ty' expr
    return $ DeclBinding ann ty' expr'

instance CheckableE LamBinding where
  checkE (LamBinding arr ty) = do
    ty' <- checkTypeE TyKind ty
    return $ LamBinding arr ty'

instance CheckableE PiBinding where
  checkE (PiBinding arr ty) = do
    ty' <- checkTypeE TyKind ty
    return $ PiBinding arr ty'

instance CheckableB LamBinder where
  checkB (LamBinder b ty arr effs) cont = do
    ty' <- checkTypeE TyKind ty
    let binding = toBinding $ LamBinding arr ty'
    withFreshNameBinder (getNameHint b) binding \b' -> do
      extendRenamer (b@>binderName b') do
        effs' <- checkE effs
        extendBindings (BindingsFrag emptyOutFrag (Just effs')) $
          cont $ LamBinder b' ty' arr effs'

instance HasType LamExpr where
  getTypeE (LamExpr b body) = do
    checkB b \(LamBinder b' ty arr eff') -> do
      bodyTy <- getTypeE body
      return $ Pi $ PiType (PiBinder b' ty arr) eff' bodyTy

instance HasType PiType where
  getTypeE (PiType b@(PiBinder _ _ arr) eff resultTy) = do
    checkArrowAndEffects arr eff
    checkB b \_ -> do
      void $ checkE eff
      resultTy|:TyKind
    return TyKind

instance CheckableB PiBinder where
  checkB (PiBinder b ty arr) cont = do
    ty' <- checkTypeE TyKind ty
    let binding = toBinding $ PiBinding arr ty'
    withFreshNameBinder (getNameHint b) binding \b' -> do
      extendRenamer (b@>binderName b') do
        extendBindings (BindingsFrag emptyOutFrag (Just Pure)) $
          cont $ PiBinder b' ty' arr

instance (BindsNames b, CheckableB b) => CheckableB (Nest b) where
  checkB nest cont = case nest of
    Empty -> cont Empty
    Nest b rest ->
      checkBEvidenced b \ext1 b' ->
        checkBEvidenced rest \ext2 rest' ->
          withExtEvidence (ext1 >>> ext2) $
            cont $ Nest b' rest'

typeCheckPrimTC :: Typer m => PrimTC (Atom i) -> m i o (Type o)
typeCheckPrimTC tc = case tc of
  BaseType _       -> return TyKind
  IntRange a b     -> a|:IdxRepTy >> b|:IdxRepTy >> return TyKind
  IndexRange t a b -> do
    t' <- checkTypeE TyKind t
    mapM_ (|:t') a >> mapM_ (|:t') b >> return TyKind
  IndexSlice n l   -> n|:TyKind >> l|:TyKind >> return TyKind
  ProdType tys     -> mapM_ (|:TyKind) tys >> return TyKind
  SumType  cs      -> mapM_ (|:TyKind) cs  >> return TyKind
  RefType r a      -> mapM_ (|:TyKind) r >> a|:TyKind >> return TyKind
  TypeKind         -> return TyKind
  EffectRowKind    -> return TyKind
  LabeledRowKindTC -> return TyKind
  ParIndexRange t gtid nthr -> gtid|:IdxRepTy >> nthr|:IdxRepTy >> t|:TyKind >> return TyKind

typeCheckPrimCon :: Typer m => PrimCon (Atom i) -> m i o (Type o)
typeCheckPrimCon con = case con of
  Lit l -> return $ BaseTy $ litType l
  ProdCon xs -> ProdTy <$> mapM getTypeE xs
  SumCon ty tag payload -> do
    ty'@(SumTy caseTys) <- substM ty
    unless (0 <= tag && tag < length caseTys) $ throw TypeErr "Invalid SumType tag"
    payload |: (caseTys !! tag)
    return ty'
  SumAsProd ty tag _ -> tag |:TagRepTy >> substM ty  -- TODO: check!
  ClassDictHole _ ty  -> ty |:TyKind   >> substM ty
  IntRangeVal     l h i -> i|:IdxRepTy >> substM (TC $ IntRange     l h)
  IndexRangeVal t l h i -> i|:IdxRepTy >> substM (TC $ IndexRange t l h)
  IndexSliceVal _ _ _ -> error "not implemented"
  BaseTypeRef p -> do
    (PtrTy (_, b)) <- getTypeE p
    return $ RawRefTy $ BaseTy b
  TabRef tabTy -> do
    Pi (PiType binder Pure (RawRefTy a)) <- getTypeE tabTy
    PiBinder _ _ TabArrow <- return binder
    return $ RawRefTy $ Pi $ PiType binder Pure a
  ConRef conRef -> case conRef of
    ProdCon xs -> RawRefTy <$> (ProdTy <$> mapM typeCheckRef xs)
    IntRangeVal     l h i -> do
      l' <- substM l
      h' <- substM h
      i|:(RawRefTy IdxRepTy) >> return (RawRefTy $ TC $ IntRange     l' h')
    IndexRangeVal t l h i -> do
      t' <- substM t
      l' <- mapM substM l
      h' <- mapM substM h
      i|:(RawRefTy IdxRepTy)
      return $ RawRefTy $ TC $ IndexRange t' l' h'
    SumAsProd ty tag _ -> do    -- TODO: check args!
      tag |:(RawRefTy TagRepTy)
      RawRefTy <$> substM ty
    _ -> error $ "Not a valid ref: " ++ pprint conRef
  ParIndexCon t v -> t|:TyKind >> v|:IdxRepTy >> substM t
  RecordRef _ -> error "Not implemented"

typeCheckPrimOp :: Typer m => PrimOp (Atom i) -> m i o (Type o)
typeCheckPrimOp op = case op of
  TabCon ty xs -> do
    ty'@(TabTyAbs piTy) <- checkTypeE TyKind ty
    idxs <- indices $ piArgType piTy
    forMZipped_ xs idxs \x i -> do
      (_, eltTy) <- instantiatePi piTy i
      x |: eltTy
    return ty'
  ScalarBinOp binop x y -> do
    xTy <- typeCheckBaseType x
    yTy <- typeCheckBaseType y
    TC <$> BaseType <$> checkBinOp binop xTy yTy
  ScalarUnOp  unop  x -> do
    xTy <- typeCheckBaseType x
    TC <$> BaseType <$> checkUnOp unop xTy
  Select p x y -> do
    p |: (BaseTy $ Scalar Word8Type)
    ty <- getTypeE x
    y |: ty
    return ty
  UnsafeFromOrdinal ty i -> ty|:TyKind >> i|:IdxRepTy >> substM ty
  ToOrdinal i -> getTypeE i $> IdxRepTy
  IdxSetSize i -> getTypeE i $> IdxRepTy
  FFICall _ ansTy args -> do
    forM_ args \arg -> do
      argTy <- getTypeE arg
      case argTy of
        BaseTy _ -> return ()
        _        -> throw TypeErr $ "All arguments of FFI calls have to be " ++
                                    "fixed-width base types, but got: " ++ pprint argTy
    declareEff IOEffect
    substM ansTy
  Inject i -> do
    TC tc <- getTypeE i
    case tc of
      IndexRange ty _ _ -> return ty
      ParIndexRange ty _ _ -> return ty
      _ -> throw TypeErr $ "Unsupported inject argument type: " ++ pprint (TC tc)
  PrimEffect ref m -> do
    TC (RefType ~(Just (Var h')) s) <- getTypeE ref
    case m of
      MGet      ->                 declareEff (RWSEffect State  h') $> s
      MPut  x   -> x|:s         >> declareEff (RWSEffect State  h') $> UnitTy
      MAsk      ->                 declareEff (RWSEffect Reader h') $> s
      MExtend x -> do
        updaterTy <- s --> s
        x|:updaterTy >> declareEff (RWSEffect Writer h') $> UnitTy
  IndexRef ref i -> do
    RefTy h (Pi (PiType (PiBinder b iTy TabArrow) Pure eltTy)) <- getTypeE ref
    i' <- checkTypeE iTy i
    eltTy' <- applyAbs (Abs b eltTy) (SubstVal i')
    return $ RefTy h eltTy'
  ProjRef i ref -> do
    RefTy h (ProdTy tys) <- getTypeE ref
    return $ RefTy h $ tys !! i
  IOAlloc t n -> do
    n |: IdxRepTy
    declareEff IOEffect
    return $ PtrTy (Heap CPU, t)
  IOFree ptr -> do
    PtrTy _ <- getTypeE ptr
    declareEff IOEffect
    return UnitTy
  PtrOffset arr off -> do
    PtrTy (a, b) <- getTypeE arr
    off |: IdxRepTy
    return $ PtrTy (a, b)
  PtrLoad ptr -> do
    PtrTy (_, t) <- getTypeE ptr
    declareEff IOEffect
    return $ BaseTy t
  PtrStore ptr val -> do
    PtrTy (_, t)  <- getTypeE ptr
    val |: BaseTy t
    declareEff IOEffect
    return $ UnitTy
  SliceOffset s i -> do
    TC (IndexSlice n l) <- getTypeE s
    l' <- getTypeE i
    checkAlphaEq l l'
    return n
  SliceCurry s i -> do
    TC (IndexSlice n (PairTy u v)) <- getTypeE s
    u' <- getTypeE i
    checkAlphaEq u u'
    return $ TC $ IndexSlice n v
  VectorBinOp _ _ _ -> throw CompilerErr "Vector operations are not supported at the moment"
  VectorPack xs -> do
    unless (length xs == vectorWidth) $ throw TypeErr lengthMsg
    BaseTy (Scalar sb) <- getTypeE $ head xs
    mapM_ (|: (BaseTy (Scalar sb))) xs
    return $ BaseTy $ Vector sb
    where lengthMsg = "VectorBroadcast should have exactly " ++ show vectorWidth ++
                      " elements: " ++ pprint op
  VectorIndex x i -> do
    BaseTy (Vector sb) <- getTypeE x
    i |: TC (IntRange (IdxRepVal 0) (IdxRepVal $ fromIntegral vectorWidth))
    return $ BaseTy $ Scalar sb
  ThrowError ty -> ty|:TyKind >> substM ty
  ThrowException ty -> do
    declareEff ExceptionEffect
    ty|:TyKind >> substM ty
  CastOp t@(Var _) _ -> t |: TyKind >> substM t
  CastOp destTy e -> do
    sourceTy <- typeCheckBaseType e
    destTy  |: TyKind
    (TC (BaseType destTy')) <- substM destTy
    checkValidCast sourceTy destTy'
    return $ TC $ BaseType $ destTy'
  RecordCons items record -> do
    types <- mapM getTypeE items
    rty <- getTypeE record
    rest <- case rty of
      RecordTy rest -> return rest
      _ -> throw TypeErr $ "Can't add fields to a non-record object "
                        <> pprint record <> " (of type " <> pprint rty <> ")"
    return $ RecordTy $ prefixExtLabeledItems types rest
  RecordSplit types record -> do
    mapM_ (|: TyKind) types
    types' <- mapM substM types
    fullty <- getTypeE record
    full <- case fullty of
      RecordTy full -> return full
      _ -> throw TypeErr $ "Can't split a non-record object " <> pprint record
                        <> " (of type " <> pprint fullty <> ")"
    diff <- labeledRowDifference full (NoExt types')
    return $ RecordTy $ NoExt $
      Unlabeled [ RecordTy $ NoExt types', RecordTy diff ]
  VariantLift types variant -> do
    mapM_ (|: TyKind) types
    types' <- mapM substM types
    rty <- getTypeE variant
    rest <- case rty of
      VariantTy rest -> return rest
      _ -> throw TypeErr $ "Can't add alternatives to a non-variant object "
                        <> pprint variant <> " (of type " <> pprint rty <> ")"
    return $ VariantTy $ prefixExtLabeledItems types' rest
  VariantSplit types variant -> do
    mapM_ (|: TyKind) types
    types' <- mapM substM types
    fullty <- getTypeE variant
    full <- case fullty of
      VariantTy full -> return full
      _ -> throw TypeErr $ "Can't split a non-variant object "
                          <> pprint variant <> " (of type " <> pprint fullty
                          <> ")"
    diff <- labeledRowDifference full (NoExt types')
    return $ VariantTy $ NoExt $
      Unlabeled [ VariantTy $ NoExt types', VariantTy diff ]
  DataConTag x -> do
    (TypeCon _ _) <- getTypeE x
    return TagRepTy
  ToEnum t x -> do
    x |: Word8Ty
    TypeCon namedDef [] <- checkTypeE TyKind t
    DataDefBinding (DataDef _ _ dataConDefs) <- lookupBindings $ fst namedDef
    forM_ dataConDefs \(DataConDef _ (Abs binders _)) -> checkEmptyNest binders
    return $ TypeCon namedDef []
  SumToVariant x -> do
    SumTy cases <- getTypeE x
    return $ VariantTy $ NoExt $ foldMap (labeledSingleton "c") cases
  OutputStreamPtr ->
    return $ BaseTy $ hostPtrTy $ hostPtrTy $ Scalar Word8Type
    where hostPtrTy ty = PtrType (Heap CPU, ty)

typeCheckPrimHof :: Typer m => PrimHof (Atom i) -> m i o (Type o)
typeCheckPrimHof hof = addContext ("Checking HOF:\n" ++ pprint hof) case hof of
  For _ f -> do
    Pi (PiType (PiBinder b argTy PlainArrow) eff eltTy) <- getTypeE f
    eff' <- liftMaybe $ hoist b eff
    declareEffs eff'
    return $ Pi $ PiType (PiBinder b argTy TabArrow) Pure eltTy
  Tile dim fT fS -> do
    (TC (IndexSlice n l), effT, tr) <- getTypeE fT >>= fromNonDepPiType PlainArrow
    (sTy                , effS, sr) <- getTypeE fS >>= fromNonDepPiType PlainArrow
    checkAlphaEq n sTy
    checkAlphaEq effT effS
    declareEffs effT
    (leadingIdxTysT, Pure, resultTyT) <- fromNaryNonDepPiType (replicate dim TabArrow) tr
    (leadingIdxTysS, Pure, resultTyS) <- fromNaryNonDepPiType (replicate dim TabArrow) sr
    (dvTy, Pure, resultTyT') <- fromNonDepPiType TabArrow resultTyT
    checkAlphaEq l dvTy
    checkAlphaEq (ListE leadingIdxTysT) (ListE leadingIdxTysS)
    checkAlphaEq resultTyT' resultTyS
    naryNonDepPiType TabArrow Pure (leadingIdxTysT ++ [n]) resultTyT'
  PTileReduce baseMonoids n mapping -> do
    -- mapping : gtid:IdxRepTy -> nthr:IdxRepTy -> (...((ParIndexRange n gtid nthr)=>a, acc{n})..., acc1)
    ([_gtid, _nthr], Pure, mapResultTy) <-
      getTypeE mapping >>= fromNaryNonDepPiType [PlainArrow, PlainArrow]
    (tiledArrTy, accTys) <- fromLeftLeaningConsListTy (length baseMonoids) mapResultTy
    (_, tileElemTy) <- fromNonDepTabTy tiledArrTy
    -- TOOD: figure out what's going on with threadRange
    --   let threadRange = TC $ ParIndexRange n (binderAsVar gtid) (binderAsVar nthr)
    --   checkAlphaEq threadRange threadRange'
    -- TODO: Check compatibility of baseMonoids and accTys (need to be careful about lifting!)
    -- PTileReduce n mapping : (n=>a, (acc1, ..., acc{n}))
    n' <- substM n
    tabTy <- n' ==> tileElemTy
    -- PTileReduce n mapping : (n=>a, (acc1, ..., acc{n}))
    return $ PairTy tabTy $ mkConsListTy accTys
  While body -> do
    Pi (PiType (PiBinder b UnitTy PlainArrow) eff condTy) <- getTypeE body
    PairE eff' condTy' <- liftMaybe $ hoist b $ PairE eff condTy
    declareEffs eff'
    checkAlphaEq (BaseTy $ Scalar Word8Type) condTy'
    return UnitTy
  Linearize f -> do
    Pi (PiType (PiBinder binder a PlainArrow) Pure b) <- getTypeE f
    b' <- liftMaybe $ hoist binder b
    fLinTy <- a --@ b'
    a --> PairTy b' fLinTy
  Transpose f -> do
    Pi (PiType (PiBinder binder a LinArrow) Pure b) <- getTypeE f
    b' <- liftMaybe $ hoist binder b
    b' --@ a
  RunReader r f -> do
    (resultTy, readTy) <- checkRWSAction Reader f
    r |: readTy
    return resultTy
  RunWriter _ f -> do
    -- XXX: We can't verify compatibility between the base monoid and f, because
    --      the only way in which they are related in the runAccum definition is via
    --      the AccumMonoid typeclass. The frontend constraints should be sufficient
    --      to ensure that only well typed programs are accepted, but it is a bit
    --      disappointing that we cannot verify that internally. We might want to consider
    --      e.g. only disabling this check for prelude.
    uncurry PairTy <$> checkRWSAction Writer f
  RunState s f -> do
    (resultTy, stateTy) <- checkRWSAction State f
    s |: stateTy
    return $ PairTy resultTy stateTy
  RunIO f -> do
    Pi (PiType (PiBinder b UnitTy PlainArrow) eff resultTy) <- getTypeE f
    PairE eff' resultTy' <- liftMaybe $ hoist b $ PairE eff resultTy
    extendAllowedEffect IOEffect $ declareEffs eff'
    return resultTy'
  CatchException f -> do
    Pi (PiType (PiBinder b UnitTy PlainArrow) eff resultTy) <- getTypeE f
    PairE eff' resultTy' <- liftMaybe $ hoist b $ PairE eff resultTy
    extendAllowedEffect ExceptionEffect $ declareEffs eff'
    return $ MaybeTy resultTy'

checkRWSAction :: Typer m => RWS -> Atom i -> m i o (Type o, Type o)
checkRWSAction rws f = do
  BinaryFunTy regionBinder refBinder eff resultTy <- getTypeE f
  dropSubst $
    refreshBinders regionBinder \regionBinder' ->
      refreshBinders refBinder \_ -> do
        eff' <- substM eff
        regionName <- injectM $ binderName regionBinder'
        extendAllowedEffect (RWSEffect rws regionName) $ declareEffs eff'
  PiBinder _ (RefTy _ referentTy) _ <- return refBinder
  referentTy' <- liftMaybe $ hoist regionBinder referentTy
  resultTy' <- liftMaybe $ hoist (PairB regionBinder refBinder) resultTy
  return (resultTy', referentTy')

-- Having this as a separate helper function helps with "'b0' is untouchable" errors
-- from GADT+monad type inference.
checkEmptyNest :: Fallible m => Nest b n l -> m ()
checkEmptyNest Empty = return ()
checkEmptyNest _  = throw TypeErr "Not empty"

nonDepBinderNestTypes :: Typer m => Nest Binder o o' -> m i o [Type o]
nonDepBinderNestTypes Empty = return []
nonDepBinderNestTypes (Nest (b:>ty) rest) = do
  Abs rest' UnitE <- liftMaybe $ hoist b $ Abs rest UnitE
  restTys <- nonDepBinderNestTypes rest'
  return $ ty : restTys

dataConFunType :: Typer m => Name DataDefNameC o -> Int -> m i o (Type o)
dataConFunType name con = do
  DataDefBinding def@(DataDef _ paramBinders cons) <- lookupBindings name
  let DataConDef _ argBinders = cons !! con
  case argBinders of
    Abs argBinders' UnitE ->
      dropSubst $
        buildNaryPiType ImplicitArrow paramBinders \params -> do
          buildNaryPiType PlainArrow argBinders' \_ -> do
            params' <- mapM injectM params
            name'   <- injectM name
            def'    <- injectM def
            return $ TypeCon (name', def') params'

typeConFunType :: Typer m => Name DataDefNameC o -> m i o (Type o)
typeConFunType name = do
  DataDefBinding (DataDef _ paramBinders _) <- lookupBindings name
  dropSubst $ buildNaryPiType PlainArrow paramBinders \_ ->
    return TyKind

-- TODO: put this in Builder?
buildNaryPiType :: Typer m
                => Arrow
                -> Nest Binder i i'
                -> (forall o'. Ext o o' => [Type o'] -> m i' o' (Type o'))
                -> m i o (Type o)
buildNaryPiType _ Empty cont = cont []
buildNaryPiType arr (Nest (b:>argTy) rest) cont = do
  refreshBinders (PiBinder b argTy arr) \b' -> do
    Pi <$> PiType b' Pure <$> buildNaryPiType arr rest \params -> do
      param <- Var <$> injectM (binderName b')
      cont (param : params)

checkCase :: Typer m => HasType body => Atom i -> [AltP body i] -> Type i -> m i o (Type o)
checkCase scrut alts resultTy = do
  resultTy' <- substM resultTy
  scrutTy <- getTypeE scrut
  altsBinderTys <- caseAltsBinderTys scrutTy
  forMZipped_ alts altsBinderTys \alt bs ->
    checkAlt resultTy' bs alt
  return resultTy'

caseAltsBinderTys :: (MonadFail1 m, BindingsReader m)
                  => Type n -> m n [EmptyAbs (Nest Binder) n]
caseAltsBinderTys ty = case ty of
  TypeCon (defName, _) params -> do
    DataDefBinding def <- lookupBindings defName
    cons <- applyDataDefParams def params
    return [bs | DataConDef _ bs <- cons]
  VariantTy (NoExt types) -> do
    mapM typeAsBinderNest $ toList types
  VariantTy _ -> fail "Can't pattern-match partially-known variants"
  _ -> fail $ "Case analysis only supported on ADTs and variants, not on " ++ pprint ty

checkDataConRefBindings :: Typer m
                        => EmptyAbs (Nest Binder) o
                        -> EmptyAbs (Nest DataConRefBinding) i
                        -> m i o ()
checkDataConRefBindings (EmptyAbs Empty) (Abs Empty UnitE) = return ()
checkDataConRefBindings (EmptyAbs (Nest b restBs)) (EmptyAbs (Nest refBinding restRefs)) = do
  let DataConRefBinding b' ref = refBinding
  ref |: RawRefTy (binderAnn b)
  bAnn' <- substM $ binderAnn b'
  checkAlphaEq (binderAnn b) bAnn'
  checkB b' \b'' -> do
    ab <- injectM $ Abs b (EmptyAbs restBs)
    restBs' <- applyAbs ab (binderName b'')
    checkDataConRefBindings restBs' (EmptyAbs restRefs)
checkDataConRefBindings _ _ = throw CompilerErr $ "Mismatched args and binders"

typeAsBinderNest :: ScopeReader m => Type n -> m n (Abs (Nest Binder) UnitE n)
typeAsBinderNest ty = do
  Abs ignored body <- toConstAbs AtomNameRep UnitE
  return $ Abs (Nest (ignored:>ty) Empty) body

checkAlt :: HasType body => Typer m
         => Type o -> EmptyAbs (Nest Binder) o -> AltP body i -> m i o ()
checkAlt resultTyReq reqBs (Abs bs body) = do
  bs' <- substM (EmptyAbs bs)
  checkAlphaEq reqBs bs'
  refreshBinders bs \_ -> do
    resultTyReq' <- injectM resultTyReq
    body |: resultTyReq'

checkApp :: Typer m => Type o -> Atom i -> m i o (Type o)
checkApp fTy x = do
  Pi (PiType (PiBinder b argTy _) eff resultTy) <- return fTy
  x' <- checkTypeE argTy x
  PairE eff' resultTy' <- applyAbs (Abs b (PairE eff resultTy)) (SubstVal x')
  declareEffs eff'
  return resultTy'

typeCheckRef :: Typer m => HasType e => e i -> m i o (Type o)
typeCheckRef x = do
  TC (RefType _ a) <- getTypeE x
  return a

checkArrowAndEffects :: Fallible m => Arrow -> EffectRow n -> m ()
checkArrowAndEffects PlainArrow _ = return ()
checkArrowAndEffects _ Pure = return ()
checkArrowAndEffects _ _ = throw TypeErr $ "Only plain arrows may have effects"

checkIntBaseType :: Fallible m => Bool -> BaseType -> m ()
checkIntBaseType allowVector t = case t of
  Scalar sbt               -> checkSBT sbt
  Vector sbt | allowVector -> checkSBT sbt
  _ -> notInt
  where
    checkSBT sbt = case sbt of
      Int64Type -> return ()
      Int32Type -> return ()
      Word8Type  -> return ()
      Word32Type -> return ()
      Word64Type -> return ()
      _         -> notInt
    notInt = throw TypeErr $ "Expected a fixed-width " ++ (if allowVector then "" else "scalar ") ++
                             "integer type, but found: " ++ pprint t

checkFloatBaseType :: Fallible m => Bool -> BaseType -> m ()
checkFloatBaseType allowVector t = case t of
  Scalar sbt               -> checkSBT sbt
  Vector sbt | allowVector -> checkSBT sbt
  _ -> notFloat
  where
    checkSBT sbt = case sbt of
      Float64Type -> return ()
      Float32Type -> return ()
      _           -> notFloat
    notFloat = throw TypeErr $ "Expected a fixed-width " ++ (if allowVector then "" else "scalar ") ++
                               "floating-point type, but found: " ++ pprint t

checkValidCast :: Fallible m => BaseType -> BaseType -> m ()
checkValidCast (PtrType _) (PtrType _) = return ()
checkValidCast (PtrType _) (Scalar Int64Type) = return ()
checkValidCast (Scalar Int64Type) (PtrType _) = return ()
checkValidCast sourceTy destTy =
  checkScalarType sourceTy >> checkScalarType destTy
  where
    checkScalarType ty = case ty of
      Scalar Int64Type   -> return ()
      Scalar Int32Type   -> return ()
      Scalar Word8Type   -> return ()
      Scalar Float64Type -> return ()
      Scalar Float32Type -> return ()
      _ -> throw TypeErr $ "Can't cast " ++ pprint sourceTy ++ " to " ++ pprint destTy

typeCheckBaseType :: Typer m => HasType e => e i -> m i o BaseType
typeCheckBaseType e =
  getTypeE e >>= \case
    TC (BaseType b) -> return b
    ty -> throw TypeErr $ "Expected a base type. Got: " ++ pprint ty

data ArgumentType = SomeFloatArg | SomeIntArg | SomeUIntArg
data ReturnType   = SameReturn | Word8Return

checkOpArgType :: Fallible m => ArgumentType -> BaseType -> m ()
checkOpArgType argTy x =
  case argTy of
    SomeIntArg   -> checkIntBaseType   True x
    SomeUIntArg  -> assertEq x (Scalar Word8Type) ""
    SomeFloatArg -> checkFloatBaseType True x

checkBinOp :: Fallible m => BinOp -> BaseType -> BaseType -> m BaseType
checkBinOp op x y = do
  checkOpArgType argTy x
  assertEq x y ""
  return $ case retTy of
    SameReturn -> x
    Word8Return -> Scalar Word8Type
  where
    (argTy, retTy) = case op of
      IAdd   -> (ia, sr);  ISub   -> (ia, sr)
      IMul   -> (ia, sr);  IDiv   -> (ia, sr)
      IRem   -> (ia, sr);
      ICmp _ -> (ia, br)
      FAdd   -> (fa, sr);  FSub   -> (fa, sr)
      FMul   -> (fa, sr);  FDiv   -> (fa, sr);
      FPow   -> (fa, sr)
      FCmp _ -> (fa, br)
      BAnd   -> (ia, sr);  BOr    -> (ia, sr)
      BXor   -> (ia, sr)
      BShL   -> (ia, sr);  BShR   -> (ia, sr)
      where
        ia = SomeIntArg; fa = SomeFloatArg
        br = Word8Return; sr = SameReturn

checkUnOp :: Fallible m => UnOp -> BaseType -> m BaseType
checkUnOp op x = do
  checkOpArgType argTy x
  return $ case retTy of
    SameReturn -> x
    Word8Return -> Scalar Word8Type
  where
    (argTy, retTy) = case op of
      Exp              -> (f, sr)
      Exp2             -> (f, sr)
      Log              -> (f, sr)
      Log2             -> (f, sr)
      Log10            -> (f, sr)
      Log1p            -> (f, sr)
      Sin              -> (f, sr)
      Cos              -> (f, sr)
      Tan              -> (f, sr)
      Sqrt             -> (f, sr)
      Floor            -> (f, sr)
      Ceil             -> (f, sr)
      Round            -> (f, sr)
      LGamma           -> (f, sr)
      FNeg             -> (f, sr)
      BNot             -> (u, sr)
      where
        u = SomeUIntArg; f = SomeFloatArg; sr = SameReturn

-- === built-in index set type class ===

-- These only work for index set types without free variables. It's redundant
-- with the more general index set classs in Builder but this way we avoid the
-- dependency cycle. And we intend to make index sets a user-defined thing soon
-- anyway.

indices :: BindingsReader m => Type n -> m n [Atom n]
indices ty = do
  Distinct <- getDistinct
  case hoistToTop ty of
    Just ty' -> return $ map (inject . litFromOrdinal ty') [0 .. litIdxSetSize ty' - 1]
    Nothing -> error "can't get index literals from type with free vars"

litIdxSetSize :: Type VoidS -> Int32
litIdxSetSize (TC ty) = case ty of
  IntRange (IdxRepVal low) (IdxRepVal high) -> fromIntegral $ high - low
  IndexRange n low high -> high' - low'
    where
      low' = case low of
        InclusiveLim x -> litToOrdinal x
        ExclusiveLim x -> litToOrdinal x + 1
        Unlimited      -> 0
      high' = case high of
        InclusiveLim x -> litToOrdinal x + 1
        ExclusiveLim x -> litToOrdinal x
        Unlimited      -> litIdxSetSize n
  ProdType tys -> product $ fmap litIdxSetSize tys
  _ -> error $ "Not an (implemented) index set: " ++ pprint ty
litIdxSetSize _ = error "not a literal index set"

litToOrdinal :: Atom VoidS -> Int32
litToOrdinal x = case x of
  Con (IntRangeVal   _ _   (IdxRepVal i)) -> i
  Con (IndexRangeVal _ _ _ (IdxRepVal i)) -> i
  _ -> error $ "Not an (implemented) index: " ++ pprint x

litFromOrdinal :: Type VoidS -> Int32 -> Atom VoidS
litFromOrdinal ty i = case ty of
  TC (IntRange low high) -> Con $ IntRangeVal low high $ IdxRepVal i
  _ -> error $ "Not an (implemented) index set: " ++ pprint ty

-- === various helpers for querying types ===

getBaseMonoidType :: MonadFail1 m => ScopeReader m => Type n -> m n (Type n)
getBaseMonoidType ty = case ty of
  Pi (PiType b _ resultTy) -> liftMaybe $ hoist b resultTy
  _     -> return ty

applyDataDefParams :: ScopeReader m => DataDef n -> [Type n] -> m n [DataConDef n]
applyDataDefParams (DataDef _ bs cons) params =
  fromListE <$> applyNaryAbs (Abs bs (ListE cons)) (map SubstVal params)

-- === effects ===

instance CheckableE EffectRow where
  checkE effRow@(EffectRow effs effTail) = do
    forM_ effs \eff -> case eff of
      RWSEffect _ v -> Var v |: TyKind
      ExceptionEffect -> return ()
      IOEffect        -> return ()
    forM_ effTail \v -> do
      v' <- substM v
      ty <- bindingType <$> lookupBindings v'
      checkAlphaEq EffKind ty
    substM effRow

declareEff :: Typer m => Effect o -> m i o ()
declareEff eff = declareEffs $ oneEffect eff

declareEffs :: Typer m => EffectRow o -> m i o ()
declareEffs effs = do
  allowedEffects <- getAllowedEffects
  checkExtends allowedEffects effs

extendAllowedEffect :: Typer m => Effect o -> m i o () -> m i o ()
extendAllowedEffect newEff cont = do
  effs <- getAllowedEffects
  withAllowedEffects (extendEffect newEff effs) cont

checkExtends :: Fallible m => EffectRow n -> EffectRow n -> m ()
checkExtends allowed (EffectRow effs effTail) = do
  let (EffectRow allowedEffs allowedEffTail) = allowed
  case effTail of
    Just _ -> assertEq allowedEffTail effTail ""
    Nothing -> return ()
  forM_ effs \eff -> unless (eff `elem` allowedEffs) $
    throw CompilerErr $ "Unexpected effect: " ++ pprint eff ++
                      "\nAllowed: " ++ pprint allowed

extendEffect :: Effect n -> EffectRow n -> EffectRow n
extendEffect eff (EffectRow effs t) = EffectRow (S.insert eff effs) t

oneEffect :: Effect n -> EffectRow n
oneEffect eff = EffectRow (S.singleton eff) Nothing

-- === labeled row types ===

checkLabeledRow :: Typer m => ExtLabeledItems (Type i) (AtomName i) -> m i o ()
checkLabeledRow (Ext items rest) = do
  mapM_ (|: TyKind) items
  forM_ rest \name -> do
    name' <- lookupEnvM name
    ty <- bindingType <$> lookupBindings name'
    checkAlphaEq LabeledRowKind ty

labeledRowDifference :: Typer m
                     => ExtLabeledItems (Type o) (AtomName o)
                     -> ExtLabeledItems (Type o) (AtomName o)
                     -> m i o (ExtLabeledItems (Type o) (AtomName o))
labeledRowDifference (Ext (LabeledItems items) rest)
                     (Ext (LabeledItems subitems) subrest) = do
  -- Check types in the right.
  _ <- flip M.traverseWithKey subitems \label subtypes ->
    case M.lookup label items of
      Just types -> forMZipped_
          subtypes
          (NE.fromList $ NE.take (length subtypes) types)
          checkAlphaEq
      Nothing -> throw TypeErr $ "Extracting missing label " ++ show label
  -- Extract remaining types from the left.
  let
    neDiff xs ys = NE.nonEmpty $ NE.drop (length ys) xs
    diffitems = M.differenceWith neDiff items subitems
  -- Check tail.
  diffrest <- case (subrest, rest) of
    (Nothing, _) -> return rest
    (Just v, Just v') | v == v' -> return Nothing
    _ -> throw TypeErr $ "Row tail " ++ pprint subrest
      ++ " is not known to be a subset of " ++ pprint rest
  return $ Ext (LabeledItems diffitems) diffrest


projectLength :: (MonadFail1 m, ScopeReader m) => Type n -> m n Int
projectLength ty = case ty of
  TypeCon (_, def) params -> do
    [DataConDef _ (Abs bs UnitE)] <- applyDataDefParams def params
    return $ nestLength bs
  RecordTy (NoExt types) -> return $ length types
  ProdTy tys -> return $ length tys
  _ -> error $ "Projecting a type that doesn't support projecting: " ++ pprint ty
