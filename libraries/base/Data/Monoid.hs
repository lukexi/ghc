{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE AutoDeriveTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE PolyKinds #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Monoid
-- Copyright   :  (c) Andy Gill 2001,
--                (c) Oregon Graduate Institute of Science and Technology, 2001
-- License     :  BSD-style (see the file libraries/base/LICENSE)
--
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- A class for monoids (types with an associative binary operation that
-- has an identity) with various general-purpose instances.
--
-----------------------------------------------------------------------------

module Data.Monoid (
        -- * Monoid typeclass
        Monoid(..),
        (<>),
        Dual(..),
        Endo(..),
        -- * Bool wrappers
        All(..),
        Any(..),
        -- * Num wrappers
        Sum(..),
        Product(..),
        -- * Maybe wrappers
        -- $MaybeExamples
        First(..),
        Last(..)
  ) where

-- Push down the module in the dependency hierarchy.
import GHC.Base hiding (Any)
import GHC.Enum
import GHC.Num
import GHC.Read
import GHC.Show
import GHC.Generics
import Data.Maybe
import Data.Proxy

{-
-- just for testing
import Data.Maybe
import Test.QuickCheck
-- -}

-- ---------------------------------------------------------------------------
-- | The class of monoids (types with an associative binary operation that
-- has an identity).  Instances should satisfy the following laws:
--
--  * @mappend mempty x = x@
--
--  * @mappend x mempty = x@
--
--  * @mappend x (mappend y z) = mappend (mappend x y) z@
--
--  * @mconcat = 'foldr' mappend mempty@
--
-- The method names refer to the monoid of lists under concatenation,
-- but there are many other instances.
--
-- Minimal complete definition: 'mempty' and 'mappend'.
--
-- Some types can be viewed as a monoid in more than one way,
-- e.g. both addition and multiplication on numbers.
-- In such cases we often define @newtype@s and make those instances
-- of 'Monoid', e.g. 'Sum' and 'Product'.

class Monoid a where
        mempty  :: a
        -- ^ Identity of 'mappend'
        mappend :: a -> a -> a
        -- ^ An associative operation
        mconcat :: [a] -> a

        -- ^ Fold a list using the monoid.
        -- For most types, the default definition for 'mconcat' will be
        -- used, but the function is included in the class definition so
        -- that an optimized version can be provided for specific types.

        mconcat = foldr mappend mempty

infixr 6 <>

-- | An infix synonym for 'mappend'.
--
-- /Since: 4.5.0.0/
(<>) :: Monoid m => m -> m -> m
(<>) = mappend
{-# INLINE (<>) #-}

-- Monoid instances.

instance Monoid [a] where
        mempty  = []
        mappend = (++)

instance Monoid b => Monoid (a -> b) where
        mempty _ = mempty
        mappend f g x = f x `mappend` g x

instance Monoid () where
        -- Should it be strict?
        mempty        = ()
        _ `mappend` _ = ()
        mconcat _     = ()

instance (Monoid a, Monoid b) => Monoid (a,b) where
        mempty = (mempty, mempty)
        (a1,b1) `mappend` (a2,b2) =
                (a1 `mappend` a2, b1 `mappend` b2)

instance (Monoid a, Monoid b, Monoid c) => Monoid (a,b,c) where
        mempty = (mempty, mempty, mempty)
        (a1,b1,c1) `mappend` (a2,b2,c2) =
                (a1 `mappend` a2, b1 `mappend` b2, c1 `mappend` c2)

instance (Monoid a, Monoid b, Monoid c, Monoid d) => Monoid (a,b,c,d) where
        mempty = (mempty, mempty, mempty, mempty)
        (a1,b1,c1,d1) `mappend` (a2,b2,c2,d2) =
                (a1 `mappend` a2, b1 `mappend` b2,
                 c1 `mappend` c2, d1 `mappend` d2)

instance (Monoid a, Monoid b, Monoid c, Monoid d, Monoid e) =>
                Monoid (a,b,c,d,e) where
        mempty = (mempty, mempty, mempty, mempty, mempty)
        (a1,b1,c1,d1,e1) `mappend` (a2,b2,c2,d2,e2) =
                (a1 `mappend` a2, b1 `mappend` b2, c1 `mappend` c2,
                 d1 `mappend` d2, e1 `mappend` e2)

-- lexicographical ordering
instance Monoid Ordering where
        mempty         = EQ
        LT `mappend` _ = LT
        EQ `mappend` y = y
        GT `mappend` _ = GT

instance Monoid (Proxy s) where
    mempty = Proxy
    mappend _ _ = Proxy
    mconcat _ = Proxy

-- | The dual of a monoid, obtained by swapping the arguments of 'mappend'.
newtype Dual a = Dual { getDual :: a }
        deriving (Eq, Ord, Read, Show, Bounded, Generic, Generic1)

instance Monoid a => Monoid (Dual a) where
        mempty = Dual mempty
        Dual x `mappend` Dual y = Dual (y `mappend` x)

-- | The monoid of endomorphisms under composition.
newtype Endo a = Endo { appEndo :: a -> a }
               deriving (Generic)

instance Monoid (Endo a) where
        mempty = Endo id
        Endo f `mappend` Endo g = Endo (f . g)

-- | Boolean monoid under conjunction.
newtype All = All { getAll :: Bool }
        deriving (Eq, Ord, Read, Show, Bounded, Generic)

instance Monoid All where
        mempty = All True
        All x `mappend` All y = All (x && y)

-- | Boolean monoid under disjunction.
newtype Any = Any { getAny :: Bool }
        deriving (Eq, Ord, Read, Show, Bounded, Generic)

instance Monoid Any where
        mempty = Any False
        Any x `mappend` Any y = Any (x || y)

-- | Monoid under addition.
newtype Sum a = Sum { getSum :: a }
        deriving (Eq, Ord, Read, Show, Bounded, Generic, Generic1, Num)

instance Num a => Monoid (Sum a) where
        mempty = Sum 0
        Sum x `mappend` Sum y = Sum (x + y)

-- | Monoid under multiplication.
newtype Product a = Product { getProduct :: a }
        deriving (Eq, Ord, Read, Show, Bounded, Generic, Generic1, Num)

instance Num a => Monoid (Product a) where
        mempty = Product 1
        Product x `mappend` Product y = Product (x * y)

-- $MaybeExamples
-- To implement @find@ or @findLast@ on any 'Foldable':
--
-- @
-- findLast :: Foldable t => (a -> Bool) -> t a -> Maybe a
-- findLast pred = getLast . foldMap (\x -> if pred x
--                                            then Last (Just x)
--                                            else Last Nothing)
-- @
--
-- Much of Data.Map's interface can be implemented with
-- Data.Map.alter. Some of the rest can be implemented with a new
-- @alterA@ function and either 'First' or 'Last':
--
-- > alterA :: (Applicative f, Ord k) =>
-- >           (Maybe a -> f (Maybe a)) -> k -> Map k a -> f (Map k a)
-- >
-- > instance Monoid a => Applicative ((,) a)  -- from Control.Applicative
--
-- @
-- insertLookupWithKey :: Ord k => (k -> v -> v -> v) -> k -> v
--                     -> Map k v -> (Maybe v, Map k v)
-- insertLookupWithKey combine key value =
--   Arrow.first getFirst . alterA doChange key
--   where
--   doChange Nothing = (First Nothing, Just value)
--   doChange (Just oldValue) =
--     (First (Just oldValue),
--      Just (combine key value oldValue))
-- @

-- | Lift a semigroup into 'Maybe' forming a 'Monoid' according to
-- <http://en.wikipedia.org/wiki/Monoid>: \"Any semigroup @S@ may be
-- turned into a monoid simply by adjoining an element @e@ not in @S@
-- and defining @e*e = e@ and @e*s = s = s*e@ for all @s ∈ S@.\" Since
-- there is no \"Semigroup\" typeclass providing just 'mappend', we
-- use 'Monoid' instead.
instance Monoid a => Monoid (Maybe a) where
  mempty = Nothing
  Nothing `mappend` m = m
  m `mappend` Nothing = m
  Just m1 `mappend` Just m2 = Just (m1 `mappend` m2)


-- | Maybe monoid returning the leftmost non-Nothing value.
newtype First a = First { getFirst :: Maybe a }
        deriving (Eq, Ord, Read, Show, Generic, Generic1)

instance Monoid (First a) where
        mempty = First Nothing
        r@(First (Just _)) `mappend` _ = r
        First Nothing `mappend` r = r

instance Functor First where
        fmap f (First x) = First (fmap f x)

instance Monad First where
        return x = First (Just x)
        First x >>= m = First (x >>= getFirst . m)

-- | Maybe monoid returning the rightmost non-Nothing value.
newtype Last a = Last { getLast :: Maybe a }
        deriving (Eq, Ord, Read, Show, Generic, Generic1)

instance Monoid (Last a) where
        mempty = Last Nothing
        _ `mappend` r@(Last (Just _)) = r
        r `mappend` Last Nothing = r

instance Functor Last where
        fmap f (Last x) = Last (fmap f x)

instance Monad Last where
        return x = Last (Just x)
        Last x >>= m = Last (x >>= getLast . m)

{-
{--------------------------------------------------------------------
  Testing
--------------------------------------------------------------------}
instance Arbitrary a => Arbitrary (Maybe a) where
  arbitrary = oneof [return Nothing, Just `fmap` arbitrary]

prop_mconcatMaybe :: [Maybe [Int]] -> Bool
prop_mconcatMaybe x =
  fromMaybe [] (mconcat x) == mconcat (catMaybes x)

prop_mconcatFirst :: [Maybe Int] -> Bool
prop_mconcatFirst x =
  getFirst (mconcat (map First x)) == listToMaybe (catMaybes x)
prop_mconcatLast :: [Maybe Int] -> Bool
prop_mconcatLast x =
  getLast (mconcat (map Last x)) == listLastToMaybe (catMaybes x)
        where listLastToMaybe [] = Nothing
              listLastToMaybe lst = Just (last lst)
-- -}

