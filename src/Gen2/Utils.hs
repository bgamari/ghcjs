{-# LANGUAGE GeneralizedNewtypeDeriving,
             TemplateHaskell,
             QuasiQuotes,
             OverloadedStrings #-}

module Gen2.Utils where

import           Control.Applicative
import           Control.Lens
import           Control.Monad.State.Strict

import           Data.Char        (isSpace)
import           Data.List        (isPrefixOf)
import           Data.Map         (Map, singleton)
import           Data.Monoid
import           Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL

import           Language.Haskell.TH.Quote
import           Language.Javascript.JMacro

import           DynFlags
import           SrcLoc
import           Outputable (defaultUserStyle, text)
import           ErrUtils (Severity(..))
import           FastString

makeLenses ''JStat
makePrisms ''JStat
makeLenses ''JExpr
makePrisms ''JExpr
makeLenses ''JVal
makePrisms ''JVal
makeLenses ''Ident
makePrisms ''Ident

-- shorter names for jmacro
j  = jmacro
je = jmacroE

insertAt :: Int -> a -> [a] -> [a]
insertAt 0 y xs             = y:xs
insertAt n y (x:xs) | n > 0 = x : insertAt (n-1) y xs
insertAt _ _ _ = error "insertAt"

-- hack for missing unary negation in jmacro
jneg :: JExpr -> JExpr
jneg e = PPostExpr True "-" e

jnull :: JExpr
jnull = ValExpr (JVar $ TxtI "null")

jvar :: Text -> JExpr
jvar xs = ValExpr (JVar $ TxtI xs)

jstr :: Text -> JExpr
jstr xs = toJExpr xs

jint :: Integer -> JExpr
jint n = ValExpr (JInt n)

jzero = jint 0

decl :: Ident -> JStat
decl i = DeclStat i Nothing

-- until supported in jmacro
decl' :: Ident -> JExpr -> JStat
decl' i e = decl i `mappend` AssignStat (ValExpr (JVar i)) e

decls :: Text -> JStat
decls s = DeclStat (TxtI s) Nothing

-- generate an identifier, use it in both statements
identBoth :: (Ident -> JStat) -> (Ident -> JStat) -> JStat
identBoth s1 s2 = UnsatBlock . IS $ do
  i <- newIdent
  return $ s1 i <> s2 i

withIdent :: (Ident -> JStat) -> JStat
withIdent s = UnsatBlock . IS $ newIdent >>= return . s

-- declare a new var and use it in statement
withVar :: (JExpr -> JStat) -> JStat
withVar s = withIdent (\i -> decl i <> s (ValExpr . JVar $ i))

newIdent :: State [Ident] Ident
newIdent = do
  (x:xs) <- get
  put xs
  return x

iex :: Ident -> JExpr
iex i = (ValExpr . JVar) i

itxt :: Ident -> T.Text
itxt (TxtI s) = s

ji :: Int -> JExpr
ji = toJExpr

showIndent x = unlines . runIndent 0 . map trim . lines . replaceParens . show $ x
    where
      replaceParens ('(':xs) = "\n( " ++ replaceParens xs
      replaceParens (')':xs) = "\n)\n" ++ replaceParens xs
      replaceParens (x:xs)   = x : replaceParens xs
      replaceParens []        = []
      indent n xs = replicate n ' ' ++ xs
      runIndent n (x:xs) | "(" `isPrefixOf` x  = indent n     x : runIndent (n+2) xs
                         | ")" `isPrefixOf` x  = indent (n-2) x : runIndent (n-2) xs
                         | all isSpace x    = runIndent n xs
                         | otherwise = indent n x : runIndent n xs
      runIndent n [] = []

trim :: String -> String
trim = let f = dropWhile isSpace . reverse in f . f

ve :: Text -> JExpr
ve = ValExpr . JVar . TxtI

concatMapM :: (Monad m, Monoid b) => (a -> m b) -> [a] -> m b
concatMapM f xs = mapM f xs >>= return . mconcat

-- fixme these should be proper keywords in jmacro
jTrue :: JExpr
jTrue = ve "true"

jFalse :: JExpr
jFalse = ve "false"

jBool :: Bool -> JExpr
jBool True = jTrue
jBool False = jFalse

-- use instead of ErrUtils variant to prevent being suppressed
compilationProgressMsg :: DynFlags -> String -> IO ()
compilationProgressMsg dflags msg
  = ifVerbose dflags 1 (log_action dflags dflags SevOutput ghcjsSrcSpan defaultUserStyle (text msg))

ifVerbose :: DynFlags -> Int -> IO () -> IO ()
ifVerbose dflags val act
  | verbosity dflags >= val = act
  | otherwise               = return ()

ghcjsSrcSpan :: SrcSpan
ghcjsSrcSpan = UnhelpfulSpan (mkFastString "<GHCJS>")
