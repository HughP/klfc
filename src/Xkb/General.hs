{-# LANGUAGE UnicodeSyntax, NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Xkb.General where

import BasePrelude
import Prelude.Unicode
import Data.Monoid.Unicode ((∅), (⊕))
import Util (show')
import qualified WithPlus as WP (singleton)

import Control.Monad.Reader (MonadReader, asks)
import Control.Monad.Writer (tell)
import Lens.Micro.Platform (view, over)

import Layout.Layout (getLetterByPosAndShiftstate, addDefaultKeys, setNullChars)
import Lookup.Linux (modifierAndTypeModifier, modifierAndPressedModifier)
import qualified Layout.Modifier as M
import Layout.Types
import PresetLayout (defaultKeys, defaultFullLayout)

data XkbConfig = XkbConfig
    { __addShortcuts ∷ Bool
    , __redirectAllXkb ∷ Bool
    , __redirectClearsExtend ∷ Bool
    }

prepareLayout ∷ MonadReader XkbConfig m ⇒ Layout → m Layout
prepareLayout layout =
    (\addShortcuts →
    over _keys
        ( bool id (map addShortcutLetters) addShortcuts >>>
          setNullChars
        ) (addDefaultKeys defaultKeys layout)
    ) <$> asks __addShortcuts

supportedShiftstate ∷ Logger m ⇒ Shiftstate → m Bool
supportedShiftstate = fmap and ∘ traverse supportedTypeModifier ∘ toList

supportedTypeModifier ∷ Logger m ⇒ Modifier → m Bool
supportedTypeModifier modifier
    | modifier ∈ map fst modifierAndTypeModifier = pure True
    | otherwise = False <$ tell [show' modifier ⊕ " is not supported in XKB"]

supportedPressedModifier ∷ Logger m ⇒ Modifier → m Bool
supportedPressedModifier modifier
    | modifier ∈ map fst modifierAndPressedModifier = pure True
    | otherwise = False <$ tell [show' modifier ⊕ " is not supported in XKB"]

addShortcutLetters ∷ Key → Key
addShortcutLetters key | WP.singleton M.Control ∈ view _shiftstates key = key
addShortcutLetters key = fromMaybe key $
    over _shiftstates (WP.singleton M.Control :) <$>
    _letters (liftA2 (:) (getLetterByPosAndShiftstate shortcutPos (∅) defaultFullLayout) ∘ pure) key
  where
    shortcutPos = view _shortcutPos key
