{-# language DeriveTraversable #-}
{-# language GeneralizedNewtypeDeriving #-}

module Unison.Util.EnumContainers
  ( EnumMap
  , EnumSet
  , EnumKey(..)
  , mapFromList
  , setFromList
  , mapSingleton
  , setSingleton
  , mapInsert
  , unionWith
  , keys
  , restrictKeys
  , withoutKeys
  , member
  , lookup
  , lookupWithDefault
  , foldMapWithKey
  , mapToList
  , (!)
  , findMin
  ) where

import Prelude hiding (lookup)

import Data.Bifunctor
import Data.Word (Word64,Word16)

import qualified Data.IntSet as IS
import qualified Data.IntMap.Strict as IM

class EnumKey k where
  keyToInt :: k -> Int
  intToKey :: Int -> k

instance EnumKey Word64 where
  keyToInt e = fromIntegral e
  intToKey i = fromIntegral i

instance EnumKey Word16 where
  keyToInt e = fromIntegral e
  intToKey i = fromIntegral i

newtype EnumMap k a = EM (IM.IntMap a)
  deriving
    ( Monoid
    , Semigroup
    , Functor
    , Foldable
    , Traversable
    , Show
    , Eq
    , Ord
    )

newtype EnumSet k = ES IS.IntSet
  deriving
    ( Monoid
    , Semigroup
    , Show
    , Eq
    , Ord
    )

mapFromList :: EnumKey k => [(k, a)] -> EnumMap k a
mapFromList = EM . IM.fromList . fmap (first keyToInt)

setFromList :: EnumKey k => [k] -> EnumSet k
setFromList = ES . IS.fromList . fmap keyToInt

mapSingleton :: EnumKey k => k -> a -> EnumMap k a
mapSingleton e a = EM $ IM.singleton (keyToInt e) a

setSingleton :: EnumKey k => k -> EnumSet k
setSingleton e = ES . IS.singleton $ keyToInt e

mapInsert :: EnumKey k => k -> a -> EnumMap k a -> EnumMap k a
mapInsert e x (EM m) = EM $ IM.insert (keyToInt e) x m

unionWith
  :: EnumKey k => EnumKey k
  => (a -> a -> a) -> EnumMap k a -> EnumMap k a -> EnumMap k a
unionWith f (EM l) (EM r) = EM $ IM.unionWith f l r

keys :: EnumKey k => EnumMap k a -> [k]
keys (EM m) = fmap intToKey . IM.keys $ m

restrictKeys :: EnumKey k => EnumMap k a -> EnumSet k -> EnumMap k a
restrictKeys (EM m) (ES s) = EM $ IM.restrictKeys m s

withoutKeys :: EnumKey k => EnumMap k a -> EnumSet k -> EnumMap k a
withoutKeys (EM m) (ES s) = EM $ IM.withoutKeys m s

member :: EnumKey k => k -> EnumSet k -> Bool
member e (ES s) = IS.member (keyToInt e) s

lookup :: EnumKey k => k -> EnumMap k a -> Maybe a
lookup e (EM m) = IM.lookup (keyToInt e) m

lookupWithDefault :: EnumKey k => a -> k -> EnumMap k a -> a
lookupWithDefault d e (EM m) = IM.findWithDefault d (keyToInt e) m

foldMapWithKey :: EnumKey k => Monoid m => (k -> a -> m) -> EnumMap k a -> m
foldMapWithKey f (EM m) = IM.foldMapWithKey (f . intToKey) m

mapToList :: EnumKey k => EnumMap k a -> [(k, a)]
mapToList (EM m) = first intToKey <$> IM.toList m

(!) :: EnumKey k => EnumMap k a -> k -> a
EM m ! e = m IM.! keyToInt e

findMin :: EnumKey k => EnumSet k -> k
findMin (ES s) = intToKey $ IS.findMin s
