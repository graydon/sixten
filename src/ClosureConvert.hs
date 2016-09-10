{-# LANGUAGE OverloadedStrings, RecursiveDo #-}
module ClosureConvert where

import qualified Bound.Scope.Simple as Simple
import Control.Applicative
import Control.Monad.Except
import Data.Monoid
import Data.Vector(Vector)
import qualified Data.Vector as Vector
import Data.Void

import qualified Builtin
import Meta
import Syntax
import qualified Syntax.Closed as Closed
import qualified Syntax.Converted as Converted
import TCM
import Util

type Meta = MetaVar Unit
type LExprM = Closed.Expr Meta
type LSExprM = Closed.SExpr Meta
type LBrsM = SimpleBranches QConstr Closed.Expr Meta

type CExprM = Converted.Expr Meta
type CSExprM = Converted.SExpr Meta
type CBrsM = SimpleBranches QConstr Converted.Expr Meta

createSignature
  :: LSExprM
  -> TCM (Converted.Signature Converted.Expr Closed.SExpr Meta)
createSignature expr = case expr of
  Closed.Sized _ (Closed.Lams tele lamScope) -> do
    (retDir, tele') <- createLambdaSignature tele lamScope
    return $ Converted.Function retDir tele' lamScope
  _ -> return $ Converted.Constant (Closed.sExprDir expr) expr

createLambdaSignature
  :: Telescope Simple.Scope () Closed.Expr Void
  -> Simple.Scope Tele Closed.SExpr Void
  -> TCM
    ( Direction
    , Telescope Simple.Scope Direction Converted.Expr Void
    )
createLambdaSignature tele (Simple.Scope lamExpr) = mdo
  tele' <- forMTele tele $ \h () s -> do
    let e = instantiateVar ((vs Vector.!) . unTele) $ vacuous s
    v <- forall_ h Unit
    e' <- convertExpr e
    return (v, e')
  let vs = fst <$> tele'
      abstr = teleAbstraction vs
      tele'' = error "convertLambda" <$> Telescope ((\(v, e) -> (metaHint v, Converted.sizeDir e, Simple.abstract abstr e)) <$> tele')
  return (Closed.sExprDir lamExpr, tele'')

convertSignature
  :: Converted.Signature Converted.Expr Closed.SExpr Void
  -> TCM CSExprM
convertSignature sig = case sig of
  Converted.Function retDir tele lamScope -> do
    vs <- forMTele tele $ \h _ _ -> forall_ h Unit
    let lamExpr = instantiateVar ((vs Vector.!) . unTele) $ vacuous lamScope
        abstr = teleAbstraction vs
    lamExpr' <- convertSExpr lamExpr
    let lamScope' = Simple.abstract abstr lamExpr'
    return
      $ Converted.sized 1
      $ Converted.Lams retDir tele
      $ error "convertBody" <$> lamScope'
  Converted.Constant _ e -> convertSExpr $ error "convertBody" <$> e

convertLambda
  :: Telescope Simple.Scope () Closed.Expr Void
  -> Simple.Scope Tele Closed.SExpr Void
  -> TCM
    ( Direction
    , Telescope Simple.Scope Direction Converted.Expr Void
    , Simple.Scope Tele Converted.SExpr Void
    )
convertLambda tele lamScope = mdo
  tele' <- forMTele tele $ \h () s -> do
    let e = instantiateVar ((vs Vector.!) . unTele) $ vacuous s
    v <- forall_ h Unit
    e' <- convertExpr e
    return (v, e')
  let vs = fst <$> tele'
      lamExpr = instantiateVar ((vs Vector.!) . unTele) $ vacuous lamScope
      abstr = teleAbstraction vs
      tele'' = error "convertLambda" <$> Telescope ((\(v, e) -> (metaHint v, Converted.sizeDir e, Simple.abstract abstr e)) <$> tele')
  lamExpr' <- convertSExpr lamExpr
  let lamScope' = Simple.abstract abstr lamExpr'
  return (Converted.sExprDir lamExpr', tele'', error "convertLambda" <$> lamScope')

convertExpr :: LExprM -> TCM CExprM
convertExpr expr = case expr of
  Closed.Var v -> return $ Converted.Var v
  Closed.Global g -> do
    sig <- convertedSignature g
    case sig of
      Converted.Function retDir tele _ -> knownCall (Converted.Global g) retDir tele mempty
      _ -> return $ Converted.Global g
  Closed.Lit l -> return $ Converted.Lit l
  Closed.Con qc es -> Converted.Con qc <$> mapM convertSExpr es
  Closed.Lams tele s -> do
    (retDir, tele', s') <- convertLambda tele s
    knownCall (Converted.Lams retDir tele' s') retDir tele' mempty
  Closed.Call (Closed.Global g) es -> do
    es' <- mapM convertSExpr es
    sig <- convertedSignature g
    case sig of
      Converted.Function retDir tele _ -> knownCall (Converted.Global g) retDir tele es'
      _ -> throwError $ "convertExpr call global " ++ show g
  Closed.Call (Closed.Lams tele s) es -> do
    (retDir, tele', s') <- convertLambda tele s
    es' <- mapM convertSExpr es
    knownCall (Converted.Lams retDir tele' s') retDir tele' es'
  Closed.Call e es -> do
    e' <- convertExpr e
    es' <- mapM convertSExpr es
    unknownCall e' es'
  Closed.Let h e bodyScope -> do
    e' <- convertSExpr e
    v <- forall_ h Unit
    let bodyExpr = instantiateVar (\() -> v) bodyScope
    bodyExpr' <- convertExpr bodyExpr
    let bodyScope' = Simple.abstract1 v bodyExpr'
    return $ Converted.Let h e' bodyScope'
  Closed.Case e brs -> Converted.Case <$> convertSExpr e <*> convertBranches brs
  Closed.Prim p -> Converted.Prim <$> mapM convertExpr p

unknownCall
  :: CExprM
  -> Vector CSExprM
  -> TCM CExprM
unknownCall e es = return
  $ Converted.Call Indirect (Converted.Global $ Builtin.applyName $ Vector.length es)
  $ Vector.cons (Converted.sized 1 e, Direct) $ (\sz -> (sz, Direct)) <$> Converted.sizedSizesOf es <|> (\arg -> (arg, Indirect)) <$> es

knownCall
  :: Converted.Expr Void
  -> Direction
  -> Telescope Simple.Scope Direction Converted.Expr Void
  -> Vector CSExprM
  -> TCM CExprM
knownCall f retDir tele args
  | numArgs < arity
    = return
    $ Converted.Con Builtin.Ref
    $ pure
    $ Converted.Sized (Builtin.addSizes $ Vector.cons (Converted.Lit 2) $ Converted.sizeOf <$> args)
    $ Converted.Con Builtin.Closure
    $ Vector.cons (Converted.sized 1 fNumArgs)
    $ Vector.cons (Converted.sized 1 $ Converted.Lit $ fromIntegral $ arity - numArgs) args
  | numArgs == arity
    = return
    $ Converted.Call retDir (vacuous f) $ Vector.zip args $ teleAnnotations tele
  | otherwise = do
    let (xs, ys) = Vector.splitAt arity args
    unknownCall (Converted.Call retDir (vacuous f) $ Vector.zip xs $ teleAnnotations tele) ys
  where
    numArgs = Vector.length args
    arity = teleLength tele
    fNumArgs
      = Converted.Lams Indirect tele'
      $ Simple.Scope
      $ fmap B
      -- $ Converted.Sized returnSize
      $ unknownSize
      $ Converted.Case (unknownSize $ Builtin.deref $ Converted.Var 0)
      $ SimpleConBranches
      $ pure
      ( Builtin.Closure
      , Telescope $ Vector.cons (mempty, (), Builtin.slit 1)
                  $ Vector.cons (mempty, (), Builtin.slit 1) clArgs'
      , Simple.Scope $ Converted.Call retDir (vacuous f) (Vector.zip (fArgs1 <> fArgs2) $ teleAnnotations tele)
      )
      where
        unknownSize = Converted.Sized $ Converted.Global "ClosureConvert.UnknownSize"
        clArgs = (\(h, d, s) -> (h, d, vacuous $ Simple.mapBound (+ 2) s)) <$> Vector.take numArgs (unTelescope tele)
        clArgs' = (\(h, _, s) -> (h, (), s)) <$> clArgs
        fArgs1 = Vector.zipWith
          Converted.Sized ((\(_, _, s) -> unvar F absurd <$> Simple.unscope s) <$> clArgs)
                          (Converted.Var . B <$> Vector.enumFromN 2 numArgs)
        fArgs2 = Vector.zipWith Converted.Sized
          (Converted.Var . F <$> Vector.enumFromN 1 numXs)
          (Converted.Var . F <$> Vector.enumFromN (fromIntegral $ 1 + numXs) numXs)
        xs = Vector.drop numArgs $ teleNames tele
        numXs = Vector.length xs
        tele'
          = Telescope
          $ Vector.cons ("x_this", Direct, Builtin.slit 1)
          $ (\h -> (h, Direct, Builtin.slit 1)) <$> xs
          <|> (\(n, h) -> (h, Indirect, Builtin.svarb $ 1 + Tele n)) <$> Vector.indexed xs

convertSExpr :: LSExprM -> TCM CSExprM
convertSExpr (Closed.Sized sz e) = Converted.Sized <$> convertExpr sz <*> convertExpr e

convertBranches :: LBrsM -> TCM CBrsM
convertBranches (SimpleConBranches cbrs) = fmap SimpleConBranches $
  forM cbrs $ \(qc, tele, brScope) -> mdo
    tele' <- forMTele tele $ \h () s -> do
      let e = instantiateVar ((vs Vector.!) . unTele) s
      v <- forall_ h Unit
      e' <- convertExpr e
      return (v, e')
    let vs = fst <$> tele'
        brExpr = instantiateVar ((vs Vector.!) . unTele) brScope
        abstr = teleAbstraction vs
        tele'' = Telescope $ (\(v, e) -> (metaHint v, (), Simple.abstract abstr e)) <$> tele'
    brExpr' <- convertExpr brExpr
    let brScope' = Simple.abstract abstr brExpr'
    return (qc, tele'', brScope')
convertBranches (SimpleLitBranches lbrs def) = SimpleLitBranches
  <$> mapM (\(l, e) -> (,) l <$> convertExpr e) lbrs <*> convertExpr def
