-- |
-- Module      :  Text.Mustache.Parser
-- Copyright   :  © 2016–present Stack Builders
-- License     :  BSD 3 clause
--
-- Maintainer  :  Mark Karpov <markkarpov92@gmail.com>
-- Stability   :  experimental
-- Portability :  portable
--
-- Megaparsec parser for Mustache templates. You don't usually need to
-- import the module, because "Text.Mustache" re-exports everything you may
-- need, import that module instead.

{-# LANGUAGE CPP               #-}
{-# LANGUAGE OverloadedStrings #-}

module Text.Mustache.Parser
  ( parseMustache )
where

import Control.Monad
import Control.Monad.State.Strict
import Data.Char (isSpace, isAlphaNum)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Void
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Mustache.Type
import qualified Data.Text                  as T
import qualified Text.Megaparsec.Char.Lexer as L

#if !MIN_VERSION_base(4,13,0)
import Data.Semigroup ((<>))
#endif

----------------------------------------------------------------------------
-- Parser

-- | Parse a given Mustache template.

parseMustache
  :: FilePath
     -- ^ Location of the file to parse
  -> Text
     -- ^ File contents (Mustache template)
  -> Either (ParseErrorBundle Text Void) [Node]
     -- ^ Parsed nodes or parse error
parseMustache = parse $
  evalStateT (pMustache eof) (St "{{" "}}" 0)

pMustache :: Parser () -> Parser [Node]
pMustache = fmap catMaybes . manyTill (choice alts)
  where
    alts =
      [ Nothing <$  withStandalone pComment
      , Just    <$> pSection "#" Section
      , Just    <$> pSection "^" InvertedSection
      , Just    <$> pStandalone (pPartial Just)
      , Just    <$> pPartial (const Nothing)
      , Nothing <$  withStandalone pSetDelimiters
      , Just    <$> pUnescapedVariable
      , Just    <$> pUnescapedSpecial
      , Just    <$> pEscapedVariable
      , Just    <$> pTextBlock ]
{-# INLINE pMustache #-}

pTextBlock :: Parser Node
pTextBlock = do
  start <- gets openingDel
  txt <- fmap T.concat . many $ do
    (void . notFollowedBy . string) start
    let textChar x = x /= T.head start && x /= '\n'
    string (T.take 1 start) <|> takeWhile1P (Just "text char") textChar
  meol <- optional eol'
  return $ case meol of
    Nothing -> TextBlock txt
    Just txt' -> TextBlock (txt <> txt')
{-# INLINE pTextBlock #-}

pUnescapedVariable :: Parser Node
pUnescapedVariable = UnescapedVar <$> pTag "&"
{-# INLINE pUnescapedVariable #-}

pUnescapedSpecial :: Parser Node
pUnescapedSpecial = do
  start <- gets openingDel
  end   <- gets closingDel
  between (symbol $ start <> "{") (string $ "}" <> end) $
    UnescapedVar <$> pKey
{-# INLINE pUnescapedSpecial #-}

pSection :: Text -> (Key -> [Node] -> Node) -> Parser Node
pSection suffix f = do
  key   <- withStandalone (pTag suffix)
  nodes <- (pMustache . withStandalone . pClosingTag) key
  return (f key nodes)
{-# INLINE pSection #-}

pPartial :: (Pos -> Maybe Pos) -> Parser Node
pPartial f = do
  pos <- f <$> L.indentLevel
  key <- pTag ">"
  let pname = PName $ T.intercalate (T.pack ".") (unKey key)
  return (Partial pname pos)
{-# INLINE pPartial #-}

pComment :: Parser ()
pComment = void $ do
  start <- gets openingDel
  end   <- gets closingDel
  (void . symbol) (start <> "!")
  manyTill (anySingle <?> "character") (string end)
{-# INLINE pComment #-}

pSetDelimiters :: Parser ()
pSetDelimiters = void $ do
  start <- gets openingDel
  end   <- gets closingDel
  (void . symbol) (start <> "=")
  start' <- pDelimiter <* scn
  end'   <- pDelimiter <* scn
  (void . string) ("=" <> end)
  modify' $ \st -> st { openingDel = start'
                      , closingDel = end'
                      }
{-# INLINE pSetDelimiters #-}

pEscapedVariable :: Parser Node
pEscapedVariable = EscapedVar <$> pTag ""
{-# INLINE pEscapedVariable #-}

withStandalone :: Parser a -> Parser a
withStandalone p = pStandalone p <|> p
{-# INLINE withStandalone #-}

pStandalone :: Parser a -> Parser a
pStandalone p = pBol *> try (between sc (sc <* (void eol' <|> eof)) p)
{-# INLINE pStandalone #-}

pTag :: Text -> Parser Key
pTag suffix = do
  start <- gets openingDel
  end   <- gets closingDel
  between (symbol $ start <> suffix) (string end) pKey
{-# INLINE pTag #-}

pClosingTag :: Key -> Parser ()
pClosingTag key = do
  start <- gets openingDel
  end   <- gets closingDel
  let str = keyToText key
  void $ between (symbol $ start <> "/") (string end) (symbol str)
{-# INLINE pClosingTag #-}

pKey :: Parser Key
pKey = (fmap Key . lexeme . label "key") (implicit <|> other)
  where
    implicit = [] <$ char '.'
    other    = sepBy1 (takeWhile1P (Just lbl) f) (char '.')
    lbl      = "alphanumeric char or '-' or '_'"
    f x      = isAlphaNum x || x == '-' || x == '_'
{-# INLINE pKey #-}

pDelimiter :: Parser Text
pDelimiter = takeWhile1P (Just "delimiter char") delChar <?> "delimiter"
  where delChar x = not (isSpace x) && x /= '='
{-# INLINE pDelimiter #-}

pBol :: Parser ()
pBol = do
  o  <- getOffset
  o' <- gets newlineOffset
  unless (o == o') empty
{-# INLINE pBol #-}

----------------------------------------------------------------------------
-- Auxiliary types

-- | Type of Mustache parser monad stack.

type Parser = StateT St (Parsec Void Text)

-- | State used in the parser.

data St = St
  { openingDel :: Text
    -- ^ Opening delimiter
  , closingDel :: Text
    -- ^ Closing delimiter
  , newlineOffset :: !Int
    -- ^ The offset at which last newline character was parsed
  }

----------------------------------------------------------------------------
-- Lexer helpers and other

scn :: Parser ()
scn = L.space space1 empty empty
{-# INLINE scn #-}

sc :: Parser ()
sc = L.space (void $ takeWhile1P Nothing f) empty empty
  where
    f x = x == ' ' || x == '\t'
{-# INLINE sc #-}

lexeme :: Parser a -> Parser a
lexeme = L.lexeme scn
{-# INLINE lexeme #-}

symbol :: Text -> Parser Text
symbol = L.symbol scn
{-# INLINE symbol #-}

keyToText :: Key -> Text
keyToText (Key []) = "."
keyToText (Key ks) = T.intercalate "." ks
{-# INLINE keyToText #-}

eol' :: Parser Text
eol' = do
  x <- eol
  o <- getOffset
  modify' (\st -> st { newlineOffset = o } )
  return x
{-# INLINE eol' #-}
