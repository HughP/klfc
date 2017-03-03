{-# LANGUAGE UnicodeSyntax, NoImplicitPrelude #-}

module Xkb.XCompose where

import BasePrelude
import Prelude.Unicode
import Data.Monoid.Unicode ((⊕))
import Util (escape, privateChars)

import Control.Monad.State (evalState)
import Control.Monad.Writer (runWriter)
import Lens.Micro.Platform (view, over, _1)

import Layout.Key (setNullChar)
import Layout.Types
import Xkb.Symbols (printLetter)

printXCompose ∷ Layout → String
printXCompose =
    over _keys (flip evalState privateChars ∘ (traverse ∘ _letters ∘ traverse) setNullChar) >>>
    unlines ∘ (:) "include \"%L\"" ∘ ((⧺) <$> printLigatures <*> printCustomDeadKeys)

printLigatures ∷ Layout → [String]
printLigatures = concatMap (mapMaybe printLigature ∘ view _letters) ∘ view _keys

printLigature ∷ Letter → Maybe String
printLigature (Ligature (Just c) xs) = Just (printCombination [c] xs)
printLigature _ = Nothing

printCustomDeadKeys ∷ Layout → [String]
printCustomDeadKeys = concatMap (concatMap printCustomDeadKey ∘ view _letters) ∘ view _keys

printCustomDeadKey ∷ Letter → [String]
printCustomDeadKey (CustomDead _ (DeadKey name (Just c) lMap)) =
    [] : "# Dead key: " ⊕ name : printCombinations (map (over _1 (c :)) lMap)
printCustomDeadKey _ = []

printCombinations ∷ [([Char], String)] → [String]
printCombinations = map (uncurry printCombination)

printCombination ∷ [Char] → String → String
printCombination xs s = concatMap (\c → "<" ⊕ printKeysym c ⊕ "> ") xs ⊕ ": " ⊕ escape s
  where printKeysym = fst ∘ runWriter ∘ printLetter ∘ Char
