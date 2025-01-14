-- Copyright 2021 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE UndecidableInstances #-}

module Simplify ( simplifyTopBlock, simplifyTopFunction, SimplifiedBlock (..)
                , liftSimplifyM, buildBlockSimplified
                , IxCache, MonadIxCache1, SimpleIxInstance (..)
                , simplifiedIxInstance, appSimplifiedIxMethod ) where

import Control.Category ((>>>))
import Control.Monad
import Control.Monad.Reader
import Control.Monad.State.Class
import Data.Foldable (toList)
import Data.Text.Prettyprint.Doc (Pretty (..), hardline)
import qualified Data.Map.Strict as M
import qualified Data.HashMap.Strict as HM
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as S
import GHC.Exts (inline)

import Err
import Name
import MTL1
import Builder
import Syntax
import Type
import Util (enumerate, foldMapM, restructure)
import CheapReduction
import Linearize
import Transpose
import LabeledItems
import Types.Primitives

-- === simplification monad ===

class (ScopableBuilder2 m, SubstReader AtomSubstVal m) => Simplifier m

newtype SimplifyM (i::S) (o::S) (a:: *) = SimplifyM
  { runSimplifyM' :: SubstReaderT AtomSubstVal (BuilderT HardFailM) i o a }
  deriving ( Functor, Applicative, Monad, ScopeReader, EnvExtender, Fallible
           , Builder, EnvReader, SubstReader AtomSubstVal, MonadFail )

liftSimplifyM :: (SinkableE e, EnvReader m) => SimplifyM n n (e n) -> m n (e n)
liftSimplifyM cont = do
  liftBuilder $ runSubstReaderT idSubst $ runSimplifyM' cont
{-# INLINE liftSimplifyM #-}

buildBlockSimplified
  :: (EnvReader m)
  => (forall l. (Emits l, DExt n l) => BuilderM l (Atom l))
  -> m n (Block n)
buildBlockSimplified m =
  liftSimplifyM do
    block <- liftBuilder $ buildBlock m
    buildBlock $ simplifyBlock block

instance Simplifier SimplifyM

-- TODO: figure out why we can't derive this one (here and elsewhere)
instance ScopableBuilder (SimplifyM i) where
  buildScoped cont = SimplifyM $ SubstReaderT $ ReaderT \env ->
    buildScoped $ runSubstReaderT (sink env) (runSimplifyM' cont)
  {-# INLINE buildScoped #-}

-- === Top-level API ===

data SimplifiedBlock n = SimplifiedBlock (Block n) (ReconstructAtom n)

-- TODO: extend this to work on functions instead of blocks (with blocks still
-- accessible as nullary functions)
simplifyTopBlock :: EnvReader m => Block n -> m n (SimplifiedBlock n)
simplifyTopBlock block = liftSimplifyM do
  (Abs UnitB block', Abs UnitB recon) <- simplifyAbs $ Abs UnitB block
  return $ SimplifiedBlock block' recon
{-# SCC simplifyTopBlock #-}

simplifyTopFunction :: EnvReader m => NaryPiType n -> Atom n -> m n (NaryLamExpr n)
simplifyTopFunction ty f = liftSimplifyM $
  buildNaryLamExpr ty \xs ->
    dropSubst $ simplifyExpr $ App (sink f) $ fmap Var xs
{-# SCC simplifyTopFunction #-}

instance GenericE SimplifiedBlock where
  type RepE SimplifiedBlock = PairE Block ReconstructAtom
  fromE (SimplifiedBlock block recon) = PairE block recon
  {-# INLINE fromE #-}
  toE   (PairE block recon) = SimplifiedBlock block recon
  {-# INLINE toE #-}

instance SinkableE SimplifiedBlock
instance SubstE Name SimplifiedBlock
instance CheckableE SimplifiedBlock where
  checkE (SimplifiedBlock block recon) =
    -- TODO: CheckableE instance for the recon too
    SimplifiedBlock <$> checkE block <*> substM recon

instance Pretty (SimplifiedBlock n) where
  pretty (SimplifiedBlock block recon) =
    pretty block <> hardline <> pretty recon

-- === All the bits of IR  ===

simplifyDecls :: Emits o => Nest Decl i i' -> SimplifyM i' o a -> SimplifyM i o a
simplifyDecls topDecls cont = do
  s  <- getSubst
  s' <- simpDeclsSubst s topDecls
  withSubst s' cont
{-# INLINE simplifyDecls #-}

simpDeclsSubst :: Emits o => Subst AtomSubstVal l o -> Nest Decl l i' -> SimplifyM i o (Subst AtomSubstVal i' o)
simpDeclsSubst !s = \case
  Empty -> return s
  Nest (Let b (DeclBinding _ _ expr)) rest -> do
    x <- withSubst s $ simplifyExpr expr
    simpDeclsSubst (s <>> (b@>SubstVal x)) rest

simplifyExpr :: Emits o => Expr i -> SimplifyM i o (Atom o)
simplifyExpr expr = confuseGHC >>= \_ -> case expr of
  App f xs -> do
    xs' <- mapM simplifyAtom xs
    simplifyApp f xs'
  TabApp f xs -> do
    xs' <- mapM simplifyAtom xs
    simplifyTabApp f xs'
  Atom x -> simplifyAtom x
  Op  op  -> (inline traversePrimOp) simplifyAtom op >>= simplifyOp
  Hof hof -> simplifyHof hof
  Case e alts resultTy eff -> do
    e' <- simplifyAtom e
    eff' <- substM eff
    resultTy' <- substM resultTy
    case trySelectBranch e' of
      Just (i, args) -> do
        Abs bs body <- return $ alts !! i
        extendSubst (bs @@> map SubstVal args) $ simplifyBlock body
      Nothing -> do
        isData resultTy' >>= \case
          True -> do
            alts' <- forM alts \(Abs bs body) -> do
              bs' <- substM $ EmptyAbs bs
              buildNaryAbs bs' \xs ->
                extendSubst (bs @@> map Rename xs) $
                  buildBlock $ simplifyBlock body
            liftM Var $ emit $ Case e' alts' resultTy' eff'
          False -> defuncCase e' alts resultTy'

caseComputingEffs
  :: forall m n. (MonadFail1 m, EnvReader m)
  => Atom n -> [Alt n] -> Type n -> m n (Expr n)
caseComputingEffs scrut alts resultTy = do
  Case scrut alts resultTy <$> foldMapM effectsE alts

defuncCase :: Emits o => Atom o -> [Alt i] -> Type o -> SimplifyM i o (Atom o)
defuncCase scrut alts resultTy = do
  split <- splitDataComponents resultTy
  (alts', recons) <- unzip <$> mapM (simplifyAlt split) alts
  closureTys <- mapM getAltNonDataTy alts'
  let closureSumTy = SumTy closureTys
  let newNonDataTy = nonDataTy split
  alts'' <- forM (enumerate alts') \(i, alt) -> injectAltResult closureSumTy i alt
  caseExpr <- caseComputingEffs scrut alts'' (PairTy (dataTy split) closureSumTy)
  caseResult <- liftM Var $ emit $ caseExpr

  (dataVal, sumVal) <- fromPair caseResult
  reconAlts <- forM (zip closureTys recons) \(ty, recon) -> do
    buildUnaryAtomAlt ty \v -> applyRecon (sink recon) (Var v)
  let nonDataVal = ACase sumVal reconAlts newNonDataTy
  Distinct <- getDistinct
  fromSplit split dataVal nonDataVal
  where
    getAltNonDataTy :: EnvReader m => Alt n -> m n (Type n)
    getAltNonDataTy (Abs bs body) = liftSubstEnvReaderM do
      substBinders bs \bs' -> do
        ~(PairTy _ ty) <- getTypeSubst body
        -- Result types of simplified abs should be hoistable past binder
        return $ ignoreHoistFailure $ hoist bs' ty

    injectAltResult :: EnvReader m => Type n -> Int -> Alt n -> m n (Alt n)
    injectAltResult sumTy con (Abs bs body) = liftBuilder do
      buildAlt (EmptyAbs bs) \vs -> do
        originalResult <- emitBlock =<< applySubst (bs@@>vs) body
        (dataResult, nonDataResult) <- fromPair originalResult
        return $ PairVal dataResult $ Con $ SumCon (sink sumTy) con nonDataResult

    -- similar to `simplifyAbs` but assumes that the result is a pair
    -- whose first component is data. The reconstruction returned only
    -- applies to the second component.
    simplifyAlt
      :: (BindsEnv b, SubstB Name b, SubstB AtomSubstVal b)
      => SplitDataNonData n -> Abs b Block i
      -> SimplifyM i o (Abs b Block o, ReconstructAtom o)
    simplifyAlt split (Abs bs body) = fromPairE <$> do
      substBinders bs \bs' -> do
        ab <- buildScoped $ simplifyBlock body
        refreshAbs ab \decls result -> do
          let locals = toScopeFrag bs' >>> toScopeFrag decls
          -- TODO: this might be too cautious. The type only needs to
          -- be hoistable above the decls. In principle it can still
          -- mention vars from the lambda binders.
          Distinct <- getDistinct
          (resultData, resultNonData) <- toSplit split result
          (newResult, newResultTy, reconAbs) <- telescopicCapture locals resultNonData
          resultDataTy <- getType resultData
          effs <- declNestEffects decls
          let ty = PairTy resultDataTy (sink newResultTy)
          let block = makeBlock decls effs (PairVal resultData newResult) ty
          return $ PairE (Abs bs' block) (LamRecon reconAbs)

simplifyApp :: forall i o. Emits o => Atom i -> NonEmpty (Atom o) -> SimplifyM i o (Atom o)
simplifyApp f xs =
  simplifyFuncAtom f >>= \case
    Left  lam  -> fast lam
    Right atom -> slow atom
  where
    fast :: LamExpr i' -> SimplifyM i' o (Atom o)
    fast lam = case fromNaryLam (NE.length xs) (Lam lam) of
      Just (bsCount, NaryLamExpr bs _ (Block _ decls atom)) -> do
          let (xsPref, xsRest) = NE.splitAt bsCount xs
          extendSubst (bs@@>(SubstVal <$> xsPref)) $ simplifyDecls decls $
            case nonEmpty xsRest of
              Nothing    -> simplifyAtom atom
              Just rest' -> simplifyApp atom rest'
      Nothing -> error "should never happen"

    slow :: Atom o -> SimplifyM i o (Atom o)
    slow atom = case atom of
      Lam   lam       -> dropSubst $ fast lam
      ACase e alts ty -> do
        -- TODO: Don't rebuild the alts here! Factor out Case simplification
        -- with lazy substitution and call it from here!
        resultTy <- getAppType ty $ toList xs
        alts' <- forM alts \(Abs bs a) -> do
          buildAlt (EmptyAbs bs) \vs -> do
            a' <- applySubst (bs@@>vs) a
            naryApp a' (map sink $ toList xs)
        caseExpr <- caseComputingEffs e alts' resultTy
        dropSubst $ simplifyExpr caseExpr
      _ -> naryApp atom $ toList xs

    simplifyFuncAtom :: Atom i -> SimplifyM i o (Either (LamExpr i) (Atom o))
    simplifyFuncAtom func = case func of
      Lam lam -> return $ Left lam
      _ -> Right <$> simplifyAtom func

-- TODO: de-dup this and simplifyApp?
simplifyTabApp :: forall i o. Emits o => Atom i -> NonEmpty (Atom o) -> SimplifyM i o (Atom o)
simplifyTabApp f xs =
  simplifyFuncAtom f >>= \case
    Left  lam  -> fast lam
    Right atom -> slow atom
  where
    fast :: TabLamExpr i' -> SimplifyM i' o (Atom o)
    fast lam = case fromNaryTabLam (NE.length xs) (TabLam lam) of
      Just (bsCount, NaryLamExpr bs _ (Block _ decls atom)) -> do
          let (xsPref, xsRest) = NE.splitAt bsCount xs
          extendSubst (bs@@>(SubstVal <$> xsPref)) $ simplifyDecls decls $
            case nonEmpty xsRest of
              Nothing    -> simplifyAtom atom
              Just rest' -> simplifyTabApp atom rest'
      Nothing -> error "should never happen"

    slow :: Atom o -> SimplifyM i o (Atom o)
    slow atom = case atom of
      TabLam   lam       -> dropSubst $ fast lam
      ACase e alts ty -> do
        -- TODO: Don't rebuild the alts here! Factor out Case simplification
        -- with lazy substitution and call it from here!
        resultTy <- getTabAppType ty $ toList xs
        alts' <- forM alts \(Abs bs a) -> do
          buildAlt (EmptyAbs bs) \vs -> do
            a' <- applySubst (bs@@>vs) a
            naryTabApp a' (map sink $ toList xs)
        caseExpr <- caseComputingEffs e alts' resultTy
        dropSubst $ simplifyExpr $ caseExpr
      _ -> naryTabApp atom $ toList xs

    simplifyFuncAtom :: Atom i -> SimplifyM i o (Either (TabLamExpr i) (Atom o))
    simplifyFuncAtom func = case func of
      TabLam lam -> return $ Left lam
      _ -> Right <$> simplifyAtom func

simplifyAtom :: Atom i -> SimplifyM i o (Atom o)
simplifyAtom atom = confuseGHC >>= \_ -> case atom of
  Var v -> simplifyVar v
  -- Tables that only contain data aren't necessarily getting inlined,
  -- so this might be the last chance to simplify them.
  TabLam (TabLamExpr b body) -> do
    -- TODO(subst): Use EnvReaderI to getType before subst
    substM atom >>= getType >>= isData >>= \case
      True -> do
        (Abs b' body', IdentityReconAbs) <- simplifyAbs $ Abs b body
        return $ TabLam $ TabLamExpr b' body'
      False -> substM atom
  -- We don't simplify body of lam because we'll beta-reduce it soon.
  Lam _    -> substM atom
  Pi  _   -> substM atom
  TabPi _ -> substM atom
  DepPairTy _ -> substM atom
  DepPair x y ty -> DepPair <$> simplifyAtom x <*> simplifyAtom y <*> substM ty
  Con con -> Con <$> (inline traversePrimCon) simplifyAtom con
  TC tc -> TC <$> (inline traversePrimTC) simplifyAtom tc
  Eff eff -> Eff <$> substM eff
  TypeCon name def params ->
    TypeCon name <$> substM def <*> mapM simplifyAtom params
  DataCon name def params con args ->
    DataCon name <$> substM def <*> mapM simplifyAtom params
                 <*> pure con <*> mapM simplifyAtom args
  DictCon d -> DictCon <$> substM d
  DictTy  t -> DictTy  <$> substM t
  Record items -> Record <$> mapM simplifyAtom items
  RecordTy _ -> substM atom >>= cheapNormalize >>= \atom' -> case atom' of
    StaticRecordTy items -> StaticRecordTy <$> dropSubst (mapM simplifyAtom items)
    _ -> error $ "Failed to simplify a record with a dynamic label: " ++ pprint atom'
  Variant types label i value -> do
    types' <- fromExtLabeledItemsE <$> substM (ExtLabeledItemsE types)
    value' <- simplifyAtom value
    return $ Variant types' label i value'
  VariantTy (Ext items ext) -> VariantTy <$> do
    items' <- mapM simplifyAtom items
    ext' <- liftM fromExtLabeledItemsE $ substM $ ExtLabeledItemsE $ Ext NoLabeledItems ext
    return $ prefixExtLabeledItems items' ext'
  LabeledRow elems -> substM elems >>= \elems' -> case fromFieldRowElems elems' of
    [StaticFields items] -> do
      items' <- dropSubst $ mapM simplifyAtom items
      return $ LabeledRow $ fieldRowElemsFromList [StaticFields items']
    []                   -> return $ LabeledRow $ fieldRowElemsFromList []
    _ -> error "Failed to simplify a labeled row"
  ACase e alts rTy   -> do
    e' <- simplifyAtom e
    case trySelectBranch e' of
      Just (i, args) -> do
        Abs bs body <- return $ alts !! i
        extendSubst (bs @@> map SubstVal args) $ simplifyAtom body
      Nothing -> do
        rTy' <- substM rTy
        alts' <- forM alts \(Abs bs body) -> do
          bs' <- substM $ EmptyAbs bs
          buildNaryAbs bs' \xs ->
            extendSubst (bs @@> map Rename xs) $
              simplifyAtom body
        return $ ACase e' alts' rTy'
  DataConRef _ _ _ -> error "Should only occur in Imp lowering"
  BoxedRef _ _     -> error "Should only occur in Imp lowering"
  DepPairRef _ _ _ -> error "Should only occur in Imp lowering"
  ProjectElt idxs v -> getProjection (toList idxs) <$> simplifyVar v

simplifyVar :: AtomName i -> SimplifyM i o (Atom o)
simplifyVar v = do
  env <- getSubst
  case env ! v of
    SubstVal x -> return x
    Rename v' -> do
      AtomNameBinding bindingInfo <- lookupEnv v'
      case bindingInfo of
        LetBound (DeclBinding _ _ (Atom x)) -> dropSubst $ simplifyAtom x
        _ -> return $ Var v'

simplifyLam :: Atom i -> SimplifyM i o (Atom o, Abs LamBinder ReconstructAtom o)
simplifyLam atom = case atom of
  Lam (LamExpr b body) -> doSimpLam b body
  _ -> simplifyAtom atom >>= \case
    Lam (LamExpr b body) -> dropSubst $ doSimpLam b body
    _ -> error "Not a lambda expression"
  where
    doSimpLam :: LamBinder i i' -> Block i'
      -> SimplifyM i o (Atom o, Abs LamBinder ReconstructAtom o)
    doSimpLam b body = do
      (Abs b' body', recon) <- simplifyAbs $ Abs b body
      return $! (Lam $ LamExpr b' body', recon)

type BinaryLamBinder = (PairB LamBinder LamBinder)

simplifyBinaryLam :: Emits o => Atom i
  -> SimplifyM i o (Atom o, Abs BinaryLamBinder ReconstructAtom o)
simplifyBinaryLam atom = case atom of
  Lam (LamExpr b1 (Block _ body1 (Lam (LamExpr b2 body2)))) -> doSimpBinaryLam b1 body1 b2 body2
  _ -> simplifyAtom atom >>= \case
    Lam (LamExpr b1 (Block _ body1 (Lam (LamExpr b2 body2)))) -> dropSubst $ doSimpBinaryLam b1 body1 b2 body2
    _ -> error "Not a binary lambda expression"
  where
    doSimpBinaryLam :: LamBinder i i' -> Nest Decl i' i'' -> LamBinder i'' i''' -> Block i'''
      -> SimplifyM i o (Atom o, Abs BinaryLamBinder ReconstructAtom o)
    doSimpBinaryLam b1 body1 b2 body2 =
      substBinders b1 \b1' -> do
        Abs decls (effs `PairE` (lam2 `PairE` lam2Ty `PairE` (Abs b2' recon'))) <-
          computeAbsEffects =<< buildScoped
            (simplifyDecls body1 do
              (Abs b2' body2', recon) <- simplifyAbs $ Abs b2 body2
              let lam2' = Lam (LamExpr b2' body2')
              lam2Ty' <- getType lam2'
              return (lam2' `PairE` lam2Ty' `PairE` recon))
        return $ case hoist decls $ Abs b2' recon' of
          HoistSuccess (Abs b2'' recon'') -> do
            let binBody = makeBlock decls effs lam2 lam2Ty
            let binRecon = Abs (b1' `PairB` b2'') recon''
            (Lam (LamExpr b1' binBody), binRecon)
          HoistFailure _ -> error "Binary lambda simplification failed: binder/recon depends on intermediate decls"

data SplitDataNonData n = SplitDataNonData
  { dataTy    :: Type n
  , nonDataTy :: Type n
  , toSplit   :: forall m l . (Fallible1 m, EnvReader m) => Atom l -> m l (Atom l, Atom l)
  , fromSplit :: forall m l . (Fallible1 m, EnvReader m) => Atom l -> Atom l -> m l (Atom l) }

-- bijection between that type and a (data, non-data) pair type.
splitDataComponents :: EnvReader m => Type n -> m n (SplitDataNonData n)
splitDataComponents = \case
  ProdTy tys -> do
    splits <- mapM splitDataComponents tys
    return $ SplitDataNonData
      { dataTy    = ProdTy $ map dataTy    splits
      , nonDataTy = ProdTy $ map nonDataTy splits
      , toSplit = \xProd -> do
          xs <- getUnpacked xProd
          (ys, zs) <- unzip <$> forM (zip xs splits) \(x, split) -> toSplit split x
          return (ProdVal ys, ProdVal zs)
      , fromSplit = \xsProd ysProd -> do
          xs <- getUnpacked xsProd
          ys <- getUnpacked ysProd
          zs <- forM (zip (zip xs ys) splits) \((x, y), split) -> fromSplit split x y
          return $ ProdVal zs }
  ty -> isData ty >>= \case
    True -> return $ SplitDataNonData
      { dataTy = ty
      , nonDataTy = UnitTy
      , toSplit = \x -> return (x, UnitVal)
      , fromSplit = \x _ -> return x }
    False -> return $ SplitDataNonData
      { dataTy = UnitTy
      , nonDataTy = ty
      , toSplit = \x -> return (UnitVal, x)
      , fromSplit = \_ x -> return x }
{-# SPECIALIZE splitDataComponents :: Type o -> SimplifyM i o (SplitDataNonData o) #-}

simplifyAbs
  :: (BindsEnv b, SubstB Name b, SubstB AtomSubstVal b)
  => Abs b Block i -> SimplifyM i o (Abs b Block o, Abs b ReconstructAtom o)
simplifyAbs (Abs bs body@(Block ann _ _)) = fromPairE <$> do
  substBinders bs \bs' -> do
    ab <- buildScoped $ simplifyBlock body
    refreshAbs ab \decls result -> do
      -- Reuse the input effect annotations, because simplifyBlock
      -- never changes them.
      effs <- case ann of
        (BlockAnn _ origEffs) -> substM origEffs
        NoBlockAnn -> return Pure
      ty <- getType result
      isData ty >>= \case
        True -> do
          ty' <- {-# SCC blockTypeNormalization #-} cheapNormalize ty
          let block = makeBlock decls effs result ty'
          return $ PairE (Abs bs' block) (Abs bs' IdentityRecon)
        False -> do
          let locals = toScopeFrag decls
          (newResult, newResultTy, reconAbs) <- telescopicCapture locals result
          let effs' = ignoreHoistFailure $ hoist decls effs
          let block = Block (BlockAnn (sink newResultTy) effs') decls newResult
          return $ PairE (Abs bs' block) (Abs bs' (LamRecon reconAbs))

-- TODO: come up with a coherent strategy for ordering these various reductions
simplifyOp :: Emits o => Op o -> SimplifyM i o (Atom o)
simplifyOp op = case op of
  RecordCons left right -> getType left >>= \case
    StaticRecordTy leftTys -> getType right >>= \case
      StaticRecordTy rightTys -> do
        -- Unpack, then repack with new arguments (possibly in the middle).
        leftList <- getUnpacked left
        let leftItems = restructure leftList leftTys
        rightList <- getUnpacked right
        let rightItems = restructure rightList rightTys
        return $ Record $ leftItems <> rightItems
      _ -> error "not a record"
    _ -> error "not a record"
  RecordConsDynamic (Con (LabelCon l)) val rec ->
    getType rec >>= \case
      StaticRecordTy itemTys -> do
        itemList <- getUnpacked rec
        let items = restructure itemList itemTys
        return $ Record $ labeledSingleton l val <> items
      _ -> error "not a record"
  RecordSplit f full -> getType full >>= \case
    StaticRecordTy fullTys -> case f of
      LabeledRow f' | [StaticFields fields] <- fromFieldRowElems f' -> do
        -- Unpack, then repack into two pieces.
        fullList <- getUnpacked full
        let fullItems = restructure fullList fullTys
        let (left, right) = splitLabeledItems fields fullItems
        return $ Record $ Unlabeled [Record left, Record right]
      _ -> error "failed to simplifiy a field row"
    _ -> error "not a record"
  RecordSplitDynamic (Con (LabelCon l)) rec ->
    getType rec >>= \case
      StaticRecordTy itemTys -> do
        itemList <- getUnpacked rec
        let items = restructure itemList itemTys
        let (val, rest) = splitLabeledItems (labeledSingleton l ()) items
        return $ PairVal (head $ toList val) $ Record rest
      _ -> error "not a record"
  VariantLift leftTys@(LabeledItems litems) right -> getType right >>= \case
    VariantTy (NoExt rightTys) -> do
      let fullRow = NoExt $ leftTys <> rightTys
      let labels = toList $ reflectLabels rightTys
      -- Emit a case statement (ordered by the arg type) that lifts the type.
      buildCase right (VariantTy fullRow) \caseIdx [v] -> do
          let (label, i) = labels !! caseIdx
          let idx = case M.lookup label litems of Nothing  -> i
                                                  Just tys -> i + length tys
          let fullRow' = fromExtLabeledItemsE $ sink $ ExtLabeledItemsE fullRow
          return $ Variant fullRow' label idx (Var v)
    _ -> error "not a variant"
  VariantSplit leftTys@(LabeledItems litems) full -> getType full >>= \case
    VariantTy (NoExt fullTys@(LabeledItems fullItems)) -> do
      -- Emit a case statement (ordered by the arg type) that splits into the
      -- appropriate piece, changing indices as needed.
      VariantTy resultRow <- getType $ Op op
      let splitRight ftys ltys = NE.nonEmpty $ NE.drop (length ltys) ftys
      let rightTys = LabeledItems $ M.differenceWith splitRight fullItems litems
      let labels = toList $ reflectLabels fullTys
      buildCase full (VariantTy resultRow) \caseIdx [v] -> do
        let (label, i) = labels !! caseIdx
        let resultRow' = fromExtLabeledItemsE $ sink $ ExtLabeledItemsE resultRow
        case M.lookup label litems of
          Just tys -> if i < length tys
            then return $ Variant resultRow' InternalSingletonLabel 0 $
              Variant (NoExt $ fmap sink leftTys) label i (Var v)
            else return $ Variant resultRow' InternalSingletonLabel 1 $
              Variant (NoExt $ fmap sink rightTys) label (i - length tys) $ Var v
          Nothing -> return $ Variant resultRow' InternalSingletonLabel 1 $
            Variant (NoExt $ fmap sink rightTys) label i $ Var v
    _ -> error "Not a variant type"
  CastOp (BaseTy (Scalar Int32Type)) (Con (Lit (Int64Lit val))) ->
    return $ Con $ Lit $ Int32Lit $ fromIntegral val
  -- Those are not no-ops! Builder methods do algebraic simplification!
  ScalarBinOp ISub x y -> isub x y
  ScalarBinOp IAdd x y -> iadd x y
  ScalarBinOp IMul x y -> imul x y
  ScalarBinOp IDiv x y -> idiv x y
  ScalarBinOp (ICmp Less ) x y -> ilt x y
  ScalarBinOp (ICmp Equal) x y -> ieq x y
  Select c x y -> select c x y
  ProjMethod dict i -> projectDictMethod dict i
  _ -> emitOp op

pattern IdentityReconAbs :: Abs binder ReconstructAtom n
pattern IdentityReconAbs <- Abs _ IdentityRecon

projectDictMethod :: Emits o => Atom o -> Int -> SimplifyM i o (Atom o)
projectDictMethod d i = do
  cheapNormalize d >>= \case
    DictCon (InstanceDict instanceName args) -> dropSubst do
      args' <- mapM simplifyAtom args
      InstanceDef _ bs _ body <- lookupInstanceDef instanceName
      let InstanceBody _ methods = body
      let method = methods !! i
      extendSubst (bs@@>(SubstVal <$> args')) $
        simplifyBlock method
    Con (ExplicitDict _ method) -> do
      case i of
        0 -> return method
        _ -> error "ExplicitDict only supports single-method classes"
    d' -> error $ "Not a simplified dict: " ++ pprint d'

simplifyHof :: Emits o => Hof i -> SimplifyM i o (Atom o)
simplifyHof hof = case hof of
  For d lam@(Lam lamExpr) -> do
    ixTy <- substM $ argType lamExpr
    (lam', Abs b recon) <- simplifyLam lam
    ans <- liftM Var $ emit $ Hof $ For d lam'
    case recon of
      IdentityRecon -> return ans
      LamRecon reconAbs ->
        buildTabLam noHint ixTy \i' -> do
          elt <- tabApp (sink ans) $ Var i'
          -- TODO Avoid substituting the body of `recon` twice (once
          -- for `applySubst` and once for `applyReconAbs`).  Maybe
          -- by making `applyReconAbs` run in a `SubstReader`?
          reconAbs' <- applySubst (b @> i') reconAbs
          applyReconAbs reconAbs' elt
  While body -> do
    (lam', IdentityReconAbs) <- simplifyLam body
    liftM Var $ emit $ Hof $ While lam'
  RunReader r lam -> do
    r' <- simplifyAtom r
    (lam', Abs b recon) <- simplifyBinaryLam lam
    ans <- emit $ Hof $ RunReader r' lam'
    let recon' = ignoreHoistFailure $ hoist b recon
    applyRecon recon' $ Var ans
  RunWriter (BaseMonoid e combine) lam -> do
    e' <- simplifyAtom e
    (combine', IdentityReconAbs) <- simplifyBinaryLam combine
    (lam', Abs b recon) <- simplifyBinaryLam lam
    let hof' = Hof $ RunWriter (BaseMonoid e' combine') lam'
    (ans, w) <- fromPair =<< liftM Var (emit hof')
    let recon' = ignoreHoistFailure $ hoist b recon
    ans' <- applyRecon recon' ans
    return $ PairVal ans' w
  RunState s lam -> do
    s' <- simplifyAtom s
    (lam', Abs b recon) <- simplifyBinaryLam lam
    resultPair <- emit $ Hof $ RunState s' lam'
    (ans, sOut) <- fromPair $ Var resultPair
    let recon' = ignoreHoistFailure $ hoist b recon
    ans' <- applyRecon recon' ans
    return $ PairVal ans' sOut
  RunIO lam -> do
    (lam', Abs b recon) <- simplifyLam lam
    ans <- emit $ Hof $ RunIO lam'
    let recon' = ignoreHoistFailure $ hoist b recon
    applyRecon recon' $ Var ans
  Linearize lam -> do
    (lam', IdentityReconAbs) <- simplifyLam lam
    linearize lam'
  Transpose lam -> do
    (lam', IdentityReconAbs) <- simplifyLam lam
    transpose lam'
  CatchException lam -> do
    (Lam (LamExpr b body), IdentityReconAbs) <- simplifyLam lam
    dropSubst $ extendSubst (b@>SubstVal UnitVal) $ exceptToMaybeBlock $ body
  _ -> error $ "not implemented: " ++ pprint hof

simplifyBlock :: Emits o => Block i -> SimplifyM i o (Atom o)
simplifyBlock (Block _ decls result) = simplifyDecls decls $ simplifyAtom result

exceptToMaybeBlock :: Emits o => Block i -> SimplifyM i o (Atom o)
exceptToMaybeBlock (Block (BlockAnn ty _) decls result) = do
  ty' <- substM ty
  exceptToMaybeDecls ty' decls $ Atom result
exceptToMaybeBlock (Block NoBlockAnn Empty result) = exceptToMaybeExpr $ Atom result
exceptToMaybeBlock _ = error "impossible"

exceptToMaybeDecls :: Emits o => Type o -> Nest Decl i i' -> Expr i' -> SimplifyM i o (Atom o)
exceptToMaybeDecls _ Empty result = exceptToMaybeExpr result
exceptToMaybeDecls resultTy (Nest (Let b (DeclBinding _ _ rhs)) decls) finalResult = do
  maybeResult <- exceptToMaybeExpr rhs
  case maybeResult of
    -- This case is just an optimization (but an important one!)
    JustAtom _ x  ->
      extendSubst (b@> SubstVal x) $ exceptToMaybeDecls resultTy decls finalResult
    _ -> emitMaybeCase maybeResult (MaybeTy resultTy)
          (return $ NothingAtom $ sink resultTy)
          (\v -> extendSubst (b@> Rename v) $
                   exceptToMaybeDecls (sink resultTy) decls finalResult)

exceptToMaybeExpr :: Emits o => Expr i -> SimplifyM i o (Atom o)
exceptToMaybeExpr expr = case expr of
  Case e alts resultTy _ -> do
    e' <- substM e
    resultTy' <- substM $ MaybeTy resultTy
    buildCase e' resultTy' \i vs -> do
      Abs bs body <- return $ alts !! i
      extendSubst (bs @@> map Rename vs) $ exceptToMaybeBlock body
  Atom x -> do
    x' <- substM x
    ty <- getType x'
    return $ JustAtom ty x'
  Op (ThrowException _) -> do
    ty <- substM expr >>= getType
    return $ NothingAtom ty
  Hof (For ann (Lam (LamExpr b body))) -> do
    ty <- substM $ binderType b
    maybes <- buildForAnn (getNameHint b) ann ty \i ->
      extendSubst (b@>Rename i) $ exceptToMaybeBlock body
    catMaybesE maybes
  Hof (RunState s lam) -> do
    s' <- substM s
    Lam (BinaryLamExpr h ref body) <- return lam
    result  <- emitRunState noHint s' \h' ref' ->
      extendSubst (h @> Rename h' <.> ref @> Rename ref') do
        exceptToMaybeBlock body
    (maybeAns, newState) <- fromPair result
    -- TODO: figure out the return type (or have `emitMaybeCase` do it) rather
    -- than do the whole subsitution here. Similarly in the RunWriter case.
    a <- getType =<< substM expr
    emitMaybeCase maybeAns (MaybeTy a)
       (return $ NothingAtom $ sink a)
       (\ans -> return $ JustAtom (sink a) $ PairVal (Var ans) (sink newState))
  Hof (RunWriter monoid (Lam (BinaryLamExpr h ref body))) -> do
    monoid' <- mapM substM monoid
    accumTy <- substM =<< (getReferentTy $ EmptyAbs $ PairB h ref)
    result <- emitRunWriter noHint accumTy monoid' \h' ref' ->
      extendSubst (h @> Rename h' <.> ref @> Rename ref') $
        exceptToMaybeBlock body
    (maybeAns, accumResult) <- fromPair result
    a <- getType =<< substM expr
    emitMaybeCase maybeAns (MaybeTy a)
      (return $ NothingAtom $ sink a)
      (\ans -> return $ JustAtom (sink a) $ PairVal (Var ans) (sink accumResult))
  Hof (While (Lam (LamExpr b body))) ->
    runMaybeWhile $ extendSubst (b@>SubstVal UnitVal) $ exceptToMaybeBlock body
  _ -> do
    expr' <- substM expr
    hasExceptions expr' >>= \case
      True -> error $ "Unexpected exception-throwing expression: " ++ pprint expr
      False -> do
        v <- emit expr'
        ty <- getType v
        return $ JustAtom ty (Var v)

hasExceptions :: (EnvReader m, MonadFail1 m) => Expr n -> m n Bool
hasExceptions expr = do
  (EffectRow effs t) <- exprEffects expr
  case t of
    Nothing -> return $ ExceptionEffect `S.member` effs
    Just _  -> error "Shouldn't have tail left"

-- === Ix simplification ===

data SimpleIxInstance (n::S) =
  SimpleIxInstance
    { simpleIxSize            :: (Abs (Nest Decl) LamExpr n)
    , simpleToOrdinal         :: (Abs (Nest Decl) LamExpr n)
    , simpleUnsafeFromOrdinal :: (Abs (Nest Decl) LamExpr n)
    }

instance GenericE SimpleIxInstance where
  type RepE SimpleIxInstance = (PairE (Abs (Nest Decl) LamExpr)
                                 (PairE (Abs (Nest Decl) LamExpr)
                                        (Abs (Nest Decl) LamExpr)))
  fromE (SimpleIxInstance a b c) = PairE a (PairE b c)
  {-# INLINE fromE #-}
  toE (PairE a (PairE b c)) = SimpleIxInstance a b c
  {-# INLINE toE #-}

instance SubstE Name SimpleIxInstance
instance SinkableE SimpleIxInstance
instance HoistableE SimpleIxInstance

data IxCache (n::S) = IxCache
  { ixCacheFreeVars :: NameSet n
  , ixCacheMap      :: HM.HashMap (EKey Type n) (SimpleIxInstance n)
  }
instance HoistableE IxCache where
  freeVarsE = ixCacheFreeVars
instance SinkableE IxCache where
  sinkingProofE _ _ = todoSinkableProof -- sinkingProofE fresh $ HashMapE $ ixCacheMap c
instance Semigroup (IxCache n) where
  (IxCache fv m) <> (IxCache fv' m') = IxCache (fv <> fv') (m <> m')
instance Monoid (IxCache n) where
  mempty = IxCache mempty mempty
instance SubstE Name IxCache where
  -- This is needed, because IxCache is sometimes below decls that are emitted in-place.
  -- But all those decls should hopefully already be fresh, since we try to be good about
  -- generating fresh names before emitting them, so the slow branch of refreshAbs should
  -- not be taken. If it is, don't implement this method, but better treat this as a
  -- performance bug instead!
  substE _ _ = error "needed for static constraints, hopefully dynamically unreachable!"

type MonadIxCache1 (m::MonadKind1) = forall n. MonadState (IxCache n) (m n)

instance Monad1 m => HoistableState IxCache m where
  -- TODO: I think we can do hoisting only based on the free vars in keys.
  -- Instances should only be added at the top-level so it's not like they
  -- can refer to any local vars that could prevent the values from being hoistable.
  hoistState s b s' = case hoist b s' of
    HoistSuccess s'' -> return s''
    HoistFailure _   -> return s

simplifiedIxInstance
  :: (EnvReader m, MonadIxCache1 m)
  => Type n -> m n (SimpleIxInstance n)
simplifiedIxInstance ty = do
  let key = EKey ty
  gets (HM.lookup key . ixCacheMap) >>= \case
    Just a  -> return a
    Nothing -> {-# SCC simplifyInstance #-} do
      a <- liftSimplifyM simplifyInstance
      modify (<> IxCache (freeVarsE key <> freeVarsE a) (HM.singleton key a))
      return a
  where
    simplifyInstance = liftSimplifyM do
      Abs decls inst <- liftBuilder $ buildScoped $ getIxImpl $ sink ty
      simpAbs <- buildScoped $ simplifyDecls decls do
        (s , IdentityReconAbs) <- simplifyLam $ ixSize inst
        (to, IdentityReconAbs) <- simplifyLam $ toOrdinal inst
        (fo, IdentityReconAbs) <- simplifyLam $ unsafeFromOrdinal inst
        return $! IxImpl{ ixSize = s, toOrdinal = to, unsafeFromOrdinal = fo }
      return $! case simpAbs of
        Abs simpDecls IxImpl{..} ->
          SimpleIxInstance
            (Abs simpDecls $ fromLam ixSize           )
            (Abs simpDecls $ fromLam toOrdinal        )
            (Abs simpDecls $ fromLam unsafeFromOrdinal)

    fromLam = \case Lam l -> l; _ -> error "Not a lambda!"
{-# SCC simplifiedIxInstance #-}

appSimplifiedIxMethod
  :: (Emits n, Builder m, MonadIxCache1 m)
  => Type n -> (SimpleIxInstance n -> Abs (Nest Decl) LamExpr n)
  -> Atom n -> m n (Atom n)
appSimplifiedIxMethod ty method x = do
  Abs decls f <- method <$> simplifiedIxInstance ty
  f' <- emitDecls decls f
  Distinct <- getDistinct
  case f' of
    LamExpr fx' fb' -> emitBlock =<< applySubst (fx' @> SubstVal x) fb'

-- === GHC performance hacks ===

{-# SPECIALIZE
  buildNaryAbs
    :: (SinkableE e, SubstE Name e, SubstE AtomSubstVal e, HoistableE e)
    => EmptyAbs (Nest Binder) n
    -> (forall l. DExt n l => [AtomName l] -> SimplifyM i l (e l))
    -> SimplifyM i n (Abs (Nest Binder) e n) #-}

-- Note [Confuse GHC]
-- I can't explain this, but for some reason using this function in strategic
-- places makes GHC produce significantly better code. If we define
--
-- simplifyAtom = \case
--   ...
--   Con con -> traverse simplifyAtom con
--   ...
--
-- then GHC is reluctant to generate a fast-path worker function for simplifyAtom
-- that would return unboxed tuples, because (at least that's my guess) it's afraid
-- that it will have to allocate a reader closure for the traverse, which does not
-- get inlined. For some reason writing the `confuseGHC >>= \_ -> case atom of ...`
-- makes GHC do the right thing, i.e. generate unboxed worker + a tiny wrapper that
-- allocates -- a closure to be passed into traverse.
--
-- What's so special about this, I don't know. `return ()` is insufficient and doesn't
-- make the optimization go through. I'll just take the win for now...
--
-- NB: We should revise this whenever we upgrade to a newer GHC version.
confuseGHC :: SimplifyM i o (DistinctEvidence o)
confuseGHC = getDistinct
{-# INLINE confuseGHC #-}
