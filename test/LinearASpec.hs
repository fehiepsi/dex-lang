{-# OPTIONS_GHC -Wno-orphans #-}
module LinearASpec where

import qualified Data.Map.Strict as M
import Test.Hspec
import LinearA

-- Define some orhpan instances as sugar over non-linear expressions
instance Num Expr where
  (+) = BinOp Add
  (*) = BinOp Mul
  abs = undefined
  signum = undefined
  fromInteger = Lit . fromInteger
  negate = undefined

instance Fractional Expr where
  fromRational = Lit . fromRational
  (/) = undefined

shouldTypeCheck :: Program -> Expectation
shouldTypeCheck prog = isProgramTypeCorrect prog `shouldBe` True

shouldNotTypeCheck :: Program -> Expectation
shouldNotTypeCheck prog = isProgramTypeCorrect prog `shouldBe` False

spec :: Spec
spec = do
  describe "evaluation" $ do
    it "evaluates a simple function" $ do
      let prog = Program $ M.fromList
            [ ("f", FuncDef [("x", FloatType)] [] (MixedType [FloatType] []) $
                LetMixed ["y"] [] 2.0 $
                LetMixed ["z"] [] ((Var "y") * ((Var "x") + 2.0)) $
                Ret ["z"] []
              )
            ]
      let expr = LetMixed ["x"] [] 2.0 $
                   App "f" ["x"] []
      eval prog mempty expr `shouldBe` (Result [FloatVal 8.0] [])

  describe "non-linear type checker" $ do
    it "accepts an implicit dup" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("id", FuncDef [("x", FloatType)] [] (MixedType [FloatType, FloatType] []) $
            LetMixed ["y"] [] (Ret ["x"][] ) $
            Ret ["x", "y"] [])
        ]

    it "rejects an implicit drop" $ do
      shouldNotTypeCheck $ Program $ M.fromList
        [ ("drop", FuncDef [("x", FloatType)] [] (MixedType [] []) $
            Ret [] [])
        ]

  describe "linear type checker" $ do
    it "type checks a linear identity" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("id", FuncDef [] [("x", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] ["y"] (Ret [] ["x"]) $
            Ret [] ["y"])
        ]

    it "rejects an implicit linear dup" $ do
      shouldNotTypeCheck $ Program $ M.fromList
        [ ("dup", FuncDef [] [("x", FloatType)] (MixedType [] [FloatType, FloatType]) $
            LetMixed [] ["y"] (Ret [] ["x"]) $
            Ret [] ["x", "y"])
        ]

    it "accepts llam x. x + 0" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [] [("x", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] ["y"] (LAdd (LVar "x") LZero) $
            Ret [] ["y"])
        ]

    it "accepts llam x. x0 + x1" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [] [("x", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] ["x0", "x1"] (Dup (LVar "x")) $
            LetMixed [] ["y"] (LAdd (LVar "x0") (LVar "x1")) $
            Ret [] ["y"])
        ]

    it "accepts llam x. x0 + (x1 + x2)" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [] [("x", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] ["x0", "x"] (Dup (LVar "x")) $
            LetMixed [] ["x1", "x2"] (Dup (LVar "x")) $
            LetMixed [] ["y"] (LAdd (LVar "x0") (LAdd (LVar "x1") (LVar "x2"))) $
            Ret [] ["y"])
        ]

    it "accepts llam x y. x + y" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [] [("x", FloatType), ("y", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] ["z"] (LAdd (LVar "x") (LVar "y")) $
            Ret [] ["z"])
        ]

    it "accepts llam x y. 0" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [] [("x", FloatType), ("y", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] [] (Drop (LTuple [LVar "x", LVar "y"])) $
            LetMixed [] ["z"] LZero $
            Ret [] ["z"])
        ]

  describe "general type checker" $ do
    it "type checks an application" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [("x", FloatType)] [("y", FloatType)]
                        (MixedType [FloatType, FloatType] [FloatType]) $
            Ret ["x", "x"] ["y"])
        , ("g", FuncDef [("x", FloatType)] [("y", FloatType)]
                        (MixedType [FloatType, FloatType] [FloatType]) $
            App "f" ["x"] ["y"])
        ]

    it "rejects a dup in an application" $ do
      shouldNotTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [] [("x", FloatType), ("y", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] ["z"] (LAdd (LVar "x") (LVar "y")) $
            Ret [] ["z"])
        , ("g", FuncDef [] [("x", FloatType)] (MixedType [] [FloatType]) $
            App "f" [] ["x", "x"])
        ]

    it "accepts a non-linear scaling" $ do
      shouldTypeCheck $ Program $ M.fromList
        [ ("f", FuncDef [("x", FloatType)] [("y", FloatType)] (MixedType [] [FloatType]) $
            LetMixed [] ["z"] (LScale (Var "x") (LVar "y")) $
            Ret [] ["z"])
        ]
