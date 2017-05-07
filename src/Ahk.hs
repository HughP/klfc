{-# LANGUAGE UnicodeSyntax, NoImplicitPrelude #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PatternGuards #-}

module Ahk
    ( printAhk
    , toAhk
    ) where

import BasePrelude
import Prelude.Unicode
import Data.Monoid.Unicode ((∅), (⊕))
import Util (show', toString, lookup', tellMaybeT, mapMaybeM, concatMapM, nubWithOnM, (>$>))

import Control.Monad.Trans.Maybe (MaybeT(..))
import Control.Monad.Writer (tell)
import qualified Data.ByteString.Lazy as BL (ByteString, pack)
import qualified Data.Text.Lazy as L (pack)
import qualified Data.Text.Lazy.Encoding as L (encodeUtf8)
import Lens.Micro.Platform (view, over, _2, _head)

import Layout.DeadKey (deadKeyToChainedDeadKey)
import Layout.Key (getLetter, toLettersAndShiftstates)
import Layout.Layout (getPosByLetterAndShiftstate)
import Layout.Modifier (ExtendId, toExtendId, fromExtendId, isExtend)
import qualified Layout.Modifier as M
import qualified Layout.Pos as P
import Layout.Types
import Lookup.Windows
import PresetDeadKey (presetDeadKeyToDeadKey)
import PresetLayout (defaultFullLayout)
import qualified WithPlus as WP

prepareLayout ∷ Layout → Layout
prepareLayout =
    over (_keys ∘ traverse ∘ _shiftlevels ∘ traverse ∘ traverse) altGrToLControlRAlt >>>
    over (_keys ∘ traverse ∘ _letters ∘ traverse) letterAltGrToLControlRAlt
  where
    letterAltGrToLControlRAlt (Modifiers pos modifiers)
      | M.AltGr ∈ modifiers = Modifiers pos (delete M.AltGr modifiers ⧺ [M.Control_L, M.Alt_R])
    letterAltGrToLControlRAlt (Redirect modifiers pos)
      | M.AltGr ∈ modifiers = Redirect (delete M.AltGr modifiers ⧺ [M.Control_L, M.Alt_R]) pos
    letterAltGrToLControlRAlt letter = letter

type AhkAction = [String]
type AhkBinding = (String, AhkAction)

printAhkBinding ∷ AhkBinding → [String]
printAhkBinding (pos, [])  = [pos ⊕ "::Return"]
printAhkBinding (pos, [x]) = [pos ⊕ "::" ⊕ x]
printAhkBinding (pos, xs)  = (pos ⊕ "::") : xs ⧺ ["Return"]

data AhkLayer = AhkLayer
    { __ahkExtends ∷ [(ExtendId, Bool)]
    , __ahkBindings ∷ [AhkBinding]
    }

printAhkLayer ∷ AhkLayer → [String]
printAhkLayer (AhkLayer extends bindings) =
    printExtends extends : concatMap printAhkBinding bindings

printExtends ∷ [(ExtendId, Bool)] → String
printExtends = ("#if" ⊕) ∘ intercalate " and" ∘ map printExtend
  where
    printExtend (eId, active) = bool " not " " " active ⊕ toString (fromExtendId eId)

data AhkKey = AhkKey
    { __ahkKeyComment ∷ [String]
    , __ahkLayers ∷ [AhkLayer]
    }

printAhkKey ∷ AhkKey → [String]
printAhkKey (AhkKey comments layers) =
    "" : map ("; " ⊕) comments ⧺ concatMap printAhkLayer layers

data Ahk = Ahk
    { __ahkSingletonKeys ∷ [AhkBinding]
    , __ahkKeys ∷ [AhkKey]
    }

printAhk ∷ Ahk → BL.ByteString
printAhk = (BL.pack [0xEF,0xBB,0xBF] ⊕) ∘ L.encodeUtf8 ∘ L.pack ∘ printAhk'

printAhk' ∷ Ahk → String
printAhk' (Ahk singletonKeys keys) = unlines $
    [ "#MaxHotkeysPerInterval 200"
    , ""
    , "SendUps(ByRef modifiers) {"
    , "  for index, modifier in modifiers {"
    , "    if (modifier == \"Caps\")"
    , "      SetCapsLockState, off"
    , "    else if (modifier == \"Num\")"
    , "      SetNumLockState, off"
    , "    else if InStr(modifier, \"Extend\")"
    , "      %modifier% := false"
    , "    else"
    , "      Send {%modifier% Up}"
    , "  }"
    , "  modifiers := Object()"
    , "}"
    , ""
    , "SendAsUnicode(string) {"
    , "  Result := \"\""
    , "  Loop, Parse, string"
    , "    Result .= Format(\"{{}U+{:04x}{}}\", Ord(A_LoopField))"
    , "  Send {Blind}%Result%"
    , "}"
    , ""
    , "DeadKeys := Object()"
    , ""
    , "DeadKey(baseChar, table) {"
    , "  Global ActiveDeadKey"
    , "  if (ActiveDeadKey != \"\") {"
    , "    NewActiveDeadKey := Object()"
    , "    for key, value in table {"
    , "      NewActiveDeadKey[key] := ActiveDeadKey[value]"
    , "    }"
    , "    ActiveDeadKey := NewActiveDeadKey"
    , "  } else {"
    , "    ActiveDeadKey := table"
    , "  }"
    , "  Input key, L1, {Esc}"
    , "  if (ErrorLevel != \"NewInput\") {"
    , "    value := ActiveDeadKey[key]"
    , "    ActiveDeadKey := \"\""
    , "    if (IsObject(value)) {"
    , "      DeadKey(baseChar, value)"
    , "    } else if (value != \"\") {"
    , "      SendAsUnicode(value)"
    , "    } else {"
    , "      SendAsUnicode(baseChar . key)"
    , "    }"
    , "  }"
    , "}"
    , ""
    ] ⧺ concatMap printAhkBinding singletonKeys
    ⧺ concatMap printAhkKey keys

toAhk ∷ Logger m ⇒ (Pos → Pos) → Layout → m Ahk
toAhk getOrigPos = prepareLayout >>> \layout →
    Ahk
      <$> liftA2 (⧺) (concatMapM printSingletonKey (view _singletonKeys layout)) (concat <$> mapMaybeM (printShortcutPos getOrigPos) (view _keys layout))
      <*> mapMaybeM printKey (view _keys layout)

printPos ∷ Logger m ⇒ Pos → MaybeT m String
printPos P.Alt_R = tellMaybeT ["remapping Alt_R is not supported in AHK"]
printPos pos = maybe e pure $ printf "SC%03x" <$> lookup pos posAndScancode
  where e = tellMaybeT [show' pos ⊕ " is not supported in AHK"]

printSend ∷ Blind → String → [String] → [String]
printSend _ _ [] = []
printSend blind suffix strings =
    [send ⊕ concatMap (\s → "{" ⊕ s ⊕ suffix' ⊕ "}") strings]
  where
    send = "Send " ⊕ blindToString blind
    suffix' = bool (" " ⊕ suffix) "" (null suffix)

printSingletonKey ∷ Logger m ⇒ SingletonKey → m [AhkBinding]
printSingletonKey key@(SingletonKey pos _) =
    over (_head ∘ _2 ∘ _head) (⊕ (" ; QWERTY " ⊕ toString pos)) <$>
    printSingletonKey' key

printSingletonKey' ∷ Logger m ⇒ SingletonKey → m [AhkBinding]
printSingletonKey' (SingletonKey pos l@(Modifiers effect modifiers)) = fmap (fromMaybe []) ∘ runMaybeT $ do
    p ← printPos pos
    (shiftStrings, lockStrings, extendStrings) ← printModifiers modifiers
    case (shiftStrings, lockStrings, extendStrings) of
      ([], [], []) → pure [(p, [])]
      ([s], [], []) | effect ≡ Shift → pure [(p, [s])]
      ([], [s], []) | effect ≡ Lock → pure [(p, [s ⊕ "Lock"])]
      _ | effect ≡ Shift → pure
            [ ("*" ⊕ p,
                printSend Blind "Down" shiftStrings ⧺
                map (printf "Set%sLockState, On") lockStrings ⧺
                map (printf "%s := true") extendStrings
              )
            , ("*" ⊕ p ⊕ " Up",
                printSend Blind "Up" shiftStrings ⧺
                map (printf "Set%sLockState, Off") lockStrings ⧺
                map (printf "%s := false") extendStrings
              )
            ]
      _ → (:[]) ∘ (,) ("*" ⊕ p) <$> printLetter Blind p l
printSingletonKey' (SingletonKey pos letter) = fmap maybeToList ∘ runMaybeT $ do
    p ← printPos pos
    (,) ("*" ⊕ p) <$> printLetter Blind p letter

printShortcutPos ∷ Logger m ⇒ (Pos → Pos) → Key → m (Maybe [AhkBinding])
printShortcutPos getOrigPos key = runMaybeT $
    over (_head ∘ _2 ∘ _head) (⊕ (" ; QWERTY " ⊕ toString pos ⊕ ": " ⊕ toString sPos)) <$>
    printShortcutPos' getOrigPos key
  where
    pos = view _pos key
    sPos = view _shortcutPos key

printShortcutPos' ∷ Logger m ⇒ (Pos → Pos) → Key → MaybeT m [AhkBinding]
printShortcutPos' getOrigPos key = do
    let pos = view _pos key
    let sPos = view _shortcutPos key
    fromPos ← printPos pos
    vk ← lookup' sPos posAndVkInt
    scancode ← printPos (getOrigPos pos)
    pure $ case any isShiftModifier (view _letters key) of
      False → [(fromPos, ["VK" ⊕ showHex vk scancode])]
      True  →
        [ ("*" ⊕ fromPos,
            [ "Send {Blind}{VK" ⊕ showHex vk scancode ⊕ " DownTemp}" ])
        , ("*" ⊕ fromPos ⊕ " up",
            [ "Send {Blind}{VK" ⊕ showHex vk scancode ⊕ " Up}"
            , "SendUps(Mods" ⊕ fromPos ⊕ ")"
            ])
        ]
  where
    isShiftModifier (Modifiers Shift modifiers) = not (null modifiers)
    isShiftModifier _ = False

modifiersToShortString ∷ Logger m ⇒ [Modifier] → MaybeT m String
modifiersToShortString = filter (not ∘ isExtend) >>> traverse toS >$> concat
  where
    toS modifier | Just s ← lookup modifier modifierAndString = pure s
    toS modifier = tellMaybeT [show' modifier ⊕ " is not supported in AHK"]

printKey ∷ Logger m ⇒ Key → m (Maybe AhkKey)
printKey key = runMaybeT $ do
    pos ← printPos (view _pos key)
    AhkKey ["QWERTY " ⊕ toString (view _pos key)] <$> printKey' pos key

printKey' ∷ Logger m ⇒ String → Key → m [AhkLayer]
printKey' pos key = nubWithOnM toAhkLayer toExtendIds lettersAndShiftstates
  where
    lettersAndShiftstates = toLettersAndShiftstates key
    toExtendIds = mapMaybe toExtendId ∘ toList ∘ snd
    extendIds = nub (concatMap toExtendIds lettersAndShiftstates)
    toAhkLayer x xs =
        AhkLayer extends ∘ catMaybes <$> traverse toAhkBinding (x:xs)
      where
        eIds = toExtendIds x
        extends = map (id &&& (∈ eIds)) extendIds
        toAhkBinding (letter, shiftstate) = runMaybeT $ do
            mods ← modifiersToShortString (toList shiftstate)
            let isBaseExtend = null mods ∧ any isExtend shiftstate
            let (star, blind) = (bool "" "*" &&& bool NoBlind Blind) isBaseExtend
            l ← printLetter blind pos letter
            let letter' = getLetter key (shiftstate ⊕ WP.singleton M.CapsLock)
            l' ← printLetter blind pos letter'
            pure ∘ (,) (star ⊕ mods ⊕ pos) $ case l ≡ l' of
              True  → l
              False →
                "if not GetKeyState(\"CapsLock\", \"T\") {" :
                map ("  " ⊕) l ⧺
                "} else {" :
                map ("  " ⊕) l' ⧺
                ["}"]

printAsSend ∷ Blind → Letter → Maybe String
printAsSend _ (Char c) = Just (printf "{Blind}{U+%04x}" c ⊕ " ; " ⊕ [c])
printAsSend _ (Ligature _ s) = Just ("{Blind}" ⊕ concatMap (printf "{U+%04x}") s ⊕ " ; " ⊕ s)
printAsSend blind (Action a)
  | Just (Simple s) ← lookup a actionAndPklAction
  = Just (blindToString blind ⊕ "{" ⊕ s ⊕ "}")
printAsSend _ _ = Nothing

printModifiers ∷ Logger m ⇒ [Modifier] → m ([String], [String], [String])
printModifiers = traverse toS >$> mconcat
  where
    toS modifier | isJust (toExtendId modifier) = pure ([], [], [toString modifier])
    toS M.CapsLock = pure ([], ["Caps"], [])
    toS M.NumLock = pure ([], ["Num"], [])
    toS modifier | Just (Simple s) ← lookup modifier modifierAndPklAction = pure ([s], [], [])
    toS modifier = (∅) <$ tell [show' modifier ⊕ " is not supported in AHK"]

data Blind = Blind | NoBlind
blindToString ∷ Blind → String
blindToString Blind = "{Blind}"
blindToString NoBlind = ""

printLetter ∷ Logger m ⇒ Blind → String → Letter → m AhkAction
printLetter blind _ letter
  | Just s ← printAsSend blind letter = pure ["Send " ⊕ s]
printLetter _ _ (Dead dead) = printDeadKey (presetDeadKeyToDeadKey dead)
printLetter _ _ (CustomDead _ dead) = printDeadKey dead
printLetter blind pos (Modifiers effect modifiers) = do
    (shiftStrings, lockStrings, extendStrings) ← printModifiers modifiers
    let allStrings = shiftStrings ⧺ lockStrings ⧺ extendStrings
    pure $ case effect of
      Shift →
        printSend blind "Down" shiftStrings ⧺
        map (printf "Set%sLockState, On") lockStrings ⧺
        map (printf "%s := true") extendStrings ⧺
        "if (Mods" ⊕ pos ⊕ " == \"\")" :
        "  Mods" ⊕ pos ⊕ " := Object()" :
        map (printf ("Mods" ⊕ pos ⊕ ".Insert(\"%s\")")) allStrings
      Latch →
        printSend blind "Down" shiftStrings ⧺
        map (printf "Set%sLockState, On") lockStrings ⧺
        map (printf "%s := true") extendStrings ⧺
        "Input c, V E L1 T2, {F1}{F2}{F3}{F4}{F5}{F6}{F7}{F8}{F9}{F10}{F11}{F12}{Left}{Right}{Up}{Down}{Home}{End}{PgUp}{PgDn}{Del}{Ins}{BS}{PrintScreen}{Pause}{AppsKey}" :
        printSend blind "Up" shiftStrings ⧺
        map (printf "Set%sLockState, Off") lockStrings ⧺
        map (printf "%s := false") extendStrings
      Lock →
        case null shiftStrings of
          True → []
          False →
            "if (Locked" ⊕ pos ⊕ ")" :
            map ("  " ⊕) (printSend blind "Up" shiftStrings) ⧺
            "else" :
            map ("  " ⊕) (printSend blind "Down" shiftStrings) ⧺
            ["Locked" ⊕ pos ⊕ " := not Locked" ⊕ pos]
        ⧺ printSend blind "" (map (⊕"Lock") lockStrings) ⧺
        map (printf "%s := not %s") extendStrings
printLetter blind pos (Action a)
  | Just (RedirectLetter letter modifiers) ← lookup a actionAndPklAction
  , redirectPos:_ ← getPosByLetterAndShiftstate letter (WP.fromList modifiers) defaultFullLayout
  = printLetter blind pos (Redirect modifiers redirectPos)
printLetter blind _ (Redirect modifiers pos) = fmap (fromMaybe []) ∘ runMaybeT $ do
    shortString ← modifiersToShortString modifiers
    let scancode = fromMaybe "" $ printf "SC%03x" <$> lookup pos posAndScancode
    case lookup pos posAndVkInt of
      Just vk → pure ["Send " ⊕ blindToString blind ⊕ shortString ⊕ "{VK" ⊕ showHex vk scancode ⊕ "}"]
      Nothing → tellMaybeT ["redirecting to " ⊕ show' pos ⊕ " is not supported in AHK"]
printLetter _ _ LNothing = pure []
printLetter _ _ letter = [] <$ tell [show' letter ⊕ " is not supported in AHK"]

printDeadKey ∷ Logger m ⇒ DeadKey → m AhkAction
printDeadKey dead@(DeadKey name baseChar _) = do
    chainedDead ← deadKeyToChainedDeadKey dead
    let (pre, name') = printChainedDeadKey chainedDead
    pure $ "; " ⊕ name :
        "if (" ⊕ name' ⊕ " == \"\") {" :
        map ("  " ⊕) pre ⧺
        [ "}"
        , "DeadKey(" ⊕ asString baseString ⊕ ", " ⊕ name' ⊕ ")"
        ]
  where
    baseString = maybe "" (:[]) baseChar

printChainedDeadKey ∷ ChainedDeadKey → ([String], String)
printChainedDeadKey (ChainedDeadKey name _ actionMap) =
    ( concatMap fst actions ⧺
      [name' ⊕ " := Object()"] ⧺
      map (name' ⊕) (map snd actions)
    , name'
    )
  where
    actions = map printAction actionMap
    name' = "DeadKeys[" ⊕ asString name ⊕ "]"

printAction ∷ (Char, ActionResult) → ([String], String)
printAction (c, OutString s) = ([], printf "[%s] := %s" (asString [c]) (asString s))
printAction (c, Next dead) = (fst printedDead, "[" ⊕ asString [c] ⊕ "] := " ⊕ snd printedDead)
  where printedDead = printChainedDeadKey dead

asString ∷ String → String
asString = printf "\"%s\"" ∘ concatMap escape
  where
    escape '"' = "\"\""
    escape '`' = "``"
    escape c = [c]
