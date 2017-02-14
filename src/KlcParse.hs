{-# LANGUAGE UnicodeSyntax, NoImplicitPrelude #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}

module KlcParse
    ( parseKlcLayout
    ) where

import BasePrelude hiding (try)
import Prelude.Unicode
import Data.Monoid.Unicode ((∅), (⊕))
import Util (parseString, (>$>), lookupR, tellMaybeT)

import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Writer (runWriterT, writer, tell)
import qualified Data.Text.Lazy as L (Text)
import Lens.Micro.Platform (ASetter, view, set, over, makeLenses, ix, _1)
import Text.Megaparsec hiding (Pos)
import Text.Megaparsec.Prim (MonadParsec)

import Layout.Key (Key(..))
import Layout.Layout (Layout(..))
import Layout.Types
import Lookup.Linux (posAndScancode)
import Lookup.Windows (shiftstateFromWinShiftstate, posAndString)

data KlcParseLayout = KlcParseLayout
    { __parseInformation ∷ Information
    , __parseShiftstates ∷ [Shiftstate]
    , __parseKeys ∷ [Key]
    , __parseLigatures ∷ [(Pos, Int, String)]
    , __parseDeadKeys ∷ [(Char, StringMap)]
    }
makeLenses ''KlcParseLayout
instance Monoid KlcParseLayout where
    mempty = KlcParseLayout (∅) (∅) (∅) (∅) (∅)
    KlcParseLayout a1 a2 a3 a4 a5 `mappend` KlcParseLayout b1 b2 b3 b4 b5 =
        KlcParseLayout (a1 ⊕ b1) (a2 ⊕ b2) (a3 ⊕ b3) (a4 ⊕ b4) (a5 ⊕ b5)

layout ∷ (Logger m, MonadParsec Dec s m, Token s ~ Char) ⇒ m Layout
layout = do
    KlcParseLayout info states keys ligs deads ← klcLayout
    ($ keys) $
      map (set _shiftstates states) >>>
      Layout info (∅) (∅) >>>
      setDeads deads >$>
      setLigatures ligs

setDeads ∷ Logger m ⇒ [(Char, StringMap)] → Layout → m Layout
setDeads = _keys ∘ traverse ∘ _letters ∘ traverse ∘ setDeadKey

setDeadKey ∷ Logger m ⇒ [(Char, StringMap)] → Letter → m Letter
setDeadKey deads dead@(CustomDead i d) =
  case find ((≡) (__baseChar d) ∘ Just ∘ fst) deads of
    Just (_, m) → pure (CustomDead i d { __stringMap = m })
    Nothing → dead <$ tell ["dead key ‘" ⊕ c ⊕ "’ is not defined"]
  where
    c = maybe "unknown" (:[]) (__baseChar d)
setDeadKey _ l = pure l

setLigatures ∷ [(Pos, Int, String)] → Layout → Layout
setLigatures = over (_keys ∘ traverse) ∘ setLigatures'

setLigatures' ∷ [(Pos, Int, String)] → Key → Key
setLigatures' xs key = foldr setLigature key ligs
  where
    ligs = filter ((≡) (view _pos key) ∘ view _1) xs
    setLigature (_, i, s) = set (_letters ∘ ix i) (Ligature Nothing s)

klcLayout ∷ (Logger m, MonadParsec e s m, Token s ~ Char) ⇒ m KlcParseLayout
klcLayout = many >$> mconcat $
        set' _parseInformation <$> try kbdField
    <|> set' _parseShiftstates <$> try shiftstates
    <|> set' _parseKeys <$> klcKeys
    <|> set' _parseLigatures <$> try ligatures
    <|> set' _parseDeadKeys <$> try deadKey
    <|> (∅) <$ try keyName
    <|> (∅) <$ try endKbd
    <|> (try nameValue >>= (uncurry field >$> set' _parseInformation))
    <|> (readLine >>= \xs → (∅) <$ tell ["uknown line ‘" ⊕ show xs ⊕ "’"])
  where
    set' ∷ Monoid α ⇒ ASetter α α' β β' → β' → α'
    set' f = flip (set f) (∅)
    field ∷ Logger m ⇒ String → String → m Information
    field "COPYRIGHT" = pure ∘ set' _copyright ∘ Just
    field "COMPANY" = pure ∘ set' _company ∘ Just
    field "LOCALEID" = pure ∘ set' _localeId ∘ Just
    field "VERSION" = pure ∘ set' _version ∘ Just
    field f = const $ (∅) <$ tell ["unknown field ‘" ⊕ f ⊕ "’"]

kbdField ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m Information
kbdField = do
    ["KBD", l1, l2] ← readLine
    pure ∘ set _name l1 ∘ set _fullName l2 $ (∅)

shiftstates ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m [Shiftstate]
shiftstates = do
    ["SHIFTSTATE"] ← readLine
    map shiftstateFromWinShiftstate <$> many (try shiftstate)

shiftstate ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m Int
shiftstate = do
    [i] ← readLine
    maybe (fail $ "‘" ⊕ show i ⊕ "’ is not an integer") pure (readMaybe i)

klcKeys ∷ (Logger m, MonadParsec e s m, Token s ~ Char) ⇒ m [Key]
klcKeys = do
    try $ spacing *> string "LAYOUT" *> endLine *> pure ()
    catMaybes <$> many (isHex *> klcKey)

klcKey ∷ (Logger m, MonadParsec e s m, Token s ~ Char) ⇒ m (Maybe Key)
klcKey = runMaybeT $ do
    sc:vk:caps:letters ← lift readLine
    Key
      <$> parseScancode sc
      <*> (Just <$> parseShortcutPos vk)
      <*> pure []
      <*> traverse parseLetter letters
      <*> (Just <$> parseCapslock caps)

parseScancode ∷ Logger m ⇒ String → MaybeT m Pos
parseScancode xs = maybe e pure (readMaybe ('0':'x':xs) >>= (`lookupR` posAndScancode))
  where e = tellMaybeT ["unknown position ‘" ⊕ xs ⊕ "’"]

parseShortcutPos ∷ Logger m ⇒ String → MaybeT m Pos
parseShortcutPos xs = maybe e pure (lookupR xs posAndString <|> parseString xs)
  where e = tellMaybeT ["unknown position ‘" ⊕ xs ⊕ "’"]

parseCapslock ∷ Logger m ⇒ String → MaybeT m Bool
parseCapslock xs = maybe e (pure ∘ toEnum) (readMaybe xs)
  where e = tellMaybeT ["‘" ⊕ xs ⊕ "’ is not a boolean value"]

parseLetter ∷ Logger m ⇒ String → m Letter
parseLetter "" = pure LNothing
parseLetter "-1" = pure LNothing
parseLetter [x] = pure (Char x)
parseLetter "%%" = pure LNothing
parseLetter xs
    | last xs ≡ '@' =
        case chr <$> readMaybe ('0':'x':init xs) of
            Just c → pure (CustomDead Nothing (DeadKey [c] (Just c) (∅)))
            Nothing → LNothing <$ tell ["no number in dead key ‘" ⊕ xs ⊕ "’"]
    | otherwise =
        case chr <$> readMaybe ('0':'x':xs) of
          Just c → pure (Char c)
          Nothing → LNothing <$ tell ["unknown letter ‘" ⊕ xs ⊕ "’"]

ligatures ∷ (Logger m, MonadParsec e s m, Token s ~ Char) ⇒ m [(Pos, Int, String)]
ligatures = do
    ["LIGATURE"] ← readLine
    catMaybes <$> many (try ligature)

ligature ∷ (Logger m, MonadParsec e s m, Token s ~ Char) ⇒ m (Maybe (Pos, Int, String))
ligature = runMaybeT $ do
    sc:i:chars ← lift readLine
    guard (not (null chars))
    pos ← parseShortcutPos sc
    i' ← maybe (tellMaybeT ["unknown index ‘" ⊕ i ⊕ "’"]) pure $ readMaybe ('0':'x':i)
    s ← mapMaybe letterToChar <$> traverse parseLetter chars
    pure (pos, i', s)
  where
    letterToChar (Char c) = Just c
    letterToChar _ = Nothing

deadKey ∷ (Logger m, MonadParsec e s m, Token s ~ Char) ⇒ m [(Char, StringMap)]
deadKey = do
    ["DEADKEY", s] ← readLine
    let i = maybeToList (readMaybe ('0':'x':s))
    c ← chr <$> i <$ when (null i) (tell ["unknown dead key ‘" ⊕ s ⊕ "’"])
    m ← many (isHex *> deadPair)
    pure (zip c [m])

deadPair ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m (String, String)
deadPair = do
    [x, y] ← map (\s → maybe '\0' chr (readMaybe ('0':'x':s))) <$> readLine
    pure ([x], [y])

keyName ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m [(String, String)]
keyName = do
    ['K':'E':'Y':'N':'A':'M':'E':_] ← readLine
    many (try nameValue)

endKbd ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m ()
endKbd = do
    ["ENDKBD"] ← readLine
    pure ()

nameValue ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m (String, String)
nameValue = do
    [name, value] ← readLine
    pure (name, value)

readLine ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m [String]
readLine = takeWhile (not ∘ isComment) <$> some (klcValue <* spacing) <* emptyOrCommentLines
  where
    isComment (';':_) = True
    isComment ('/':'/':_) = True
    isComment _ = False

klcValue ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m String
klcValue = try (char '"' *> manyTill anyChar (char '"')) <|> try (some (noneOf " \t\r\n")) <?> "klc value"

isHex ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m Char
isHex = (lookAhead ∘ try) (spacing *> satisfy ((∧) <$> isHexDigit <*> not ∘ isUpper))

spacing ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m String
spacing = many (oneOf " \t")

comment ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m String
comment = spacing *> (string ";" <|> string "//") *> manyTill anyChar (try eol)

endLine ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m String
endLine = manyTill anyChar (try eol) <* emptyOrCommentLines

emptyLine ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m String
emptyLine = spacing <* eol

emptyOrCommentLines ∷ (MonadParsec e s m, Token s ~ Char) ⇒ m [String]
emptyOrCommentLines = many (try emptyLine <|> try comment)

parseKlcLayout ∷ Logger m ⇒ String → L.Text → Either String (m Layout)
parseKlcLayout fname =
    parse (runWriterT (emptyOrCommentLines *> layout <* eof)) fname >>>
    bimap parseErrorPretty writer
