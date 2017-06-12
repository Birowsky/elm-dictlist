module AllDictList
    exposing
        ( AllDictList
          -- originally from `Dict`
        , empty
        , singleton
        , insert
        , update
        , isEmpty
        , get
        , remove
        , member
        , size
        , filter
        , partition
        , foldl
        , foldr
        , map
        , union
        , intersect
        , diff
        , merge
        , keys
        , values
        , toList
        , fromList
          -- core `List`
        , cons
        , head
        , tail
        , indexedMap
        , filterMap
        , length
        , reverse
        , all
        , any
        , append
        , concat
        , sum
        , product
        , maximum
        , minimum
        , take
        , drop
        , sort
        , sortBy
        , sortWith
          -- list-oriented
        , getAt
        , getKeyAt
        , indexOfKey
        , insertAfter
        , insertBefore
        , next
        , previous
        , RelativePosition(..)
        , relativePosition
        , insertRelativeTo
        , atRelativePosition
          -- JSON
        , decodeObject
        , decodeWithKeys
        , decodeKeysAndValues
        , decodeArray
        , decodeArray2
          -- Conversion
        , toDict
        , fromDict
          -- Dict.Extra
        , groupBy
        , fromListBy
        , removeWhen
        , removeMany
        , keepOnly
        , mapKeys
        )

{-| Have you ever wanted a `Dict`, but you need to maintain an arbitrary
ordering of keys? Or, a `List`, but you want to efficiently lookup values
by a key? With `AllDictList`, now you can!

`AllDictList` implements the full API for `Dict` (and should be a drop-in
replacement for it). However, instead of ordering things from lowest
key to highest key, it allows for an arbitrary ordering.

We also implement most of the API for `List`. However, the API is not
identical, since we need to account for both keys and values.

An alternative would be to maintain your own "association list" -- that is,
a `List (k, v)` instead of a `AllDictList k v`. You can move back and forth
between an association list and a `AllDictList` via `toList` and `fromList`.

# AllDictList

@docs AllDictList, RelativePosition

# Build

Functions which create or update a `AllDictList`.

@docs empty, singleton, insert, update, remove
@docs take, drop
@docs removeWhen, removeMany, keepOnly
@docs cons, insertAfter, insertBefore, insertRelativeTo

# Combine

Functions which combine two `AllDictLists`.

@docs append, concat
@docs union, intersect, diff, merge

# Query

Functions which get information about a `AllDictList`.

@docs isEmpty, size, length
@docs all, any
@docs sum, product, maximum, minimum

# Elements

Functions that pick out an element of a `AllDictList`,
or provide information about an element.

@docs member, get, getAt, getKeyAt
@docs indexOfKey, relativePosition, atRelativePosition
@docs head, tail
@docs next, previous

# Transform

Functions that transform a `AllDictList`

@docs map, mapKeys, foldl, foldr, filter, partition
@docs indexedMap, filterMap, reverse
@docs sort, sortBy, sortWith

# Convert

Functions that convert between a `AllDictList` and a related type.

@docs keys, values, toList, fromList, fromListBy, groupBy
@docs toDict, fromDict

# JSON

Functions that help to decode a `AllDictList`.

@docs decodeObject, decodeArray, decodeArray2, decodeWithKeys, decodeKeysAndValues

-}

import Dict exposing (Dict)
import Json.Decode exposing (Decoder, keyValuePairs, value, decodeValue)
import Json.Decode as Json18
import List.Extra
import Maybe as Maybe18
import Set exposing (Set)
import Tuple exposing (first, second)


{-| A `Dict` that maintains an arbitrary ordering of keys (rather than sorting
them, as a normal `Dict` does. Or, a `List` that permits efficient lookup of
values by a key. You can look at it either way.
-}
type AllDictList k v
    = AllDictList (Dict k v) (List k)



{- I considered something like this instead:

       type AllDictList k v = AllDictList (Dict k v) (List (k, v))

   This would speed up some things, because our `List` would have the values
   as well -- we wouldn't have to look them up in the `Dict` when doing
   list-oriented things. However, it would slow down other things, because
   we'd have to modify the list in cases where only the value was changing,
   not the key. So, it's something we could reconsider depending on
   desired performance characteristics.

   Another performance issue down the road would be whether to use `Array`
   for the internal implementation rather than `List`.
-}


{-| Describes the position of a key in relation to another key (before or after
it), rather than using an index.
-}
type RelativePosition k
    = BeforeKey k
    | AfterKey k



-------
-- JSON
-------


{-| Turn any object into a dictionary of key-value pairs, including inherited
enumerable properties. Fails if _any_ value can't be decoded with the given
decoder.

Unfortunately, it is not possible to preserve the apparent order of the keys in
the JSON, because the keys in Javascript objects are fundamentally un-ordered.
Thus, you will typically need to use `decodeWithKeys` or `decodeArray` instead.
-}
decodeObject : Decoder a -> Decoder (AllDictList String a)
decodeObject decoder =
    Json.Decode.map fromList (keyValuePairs decoder)


{-| This function produces a decoder you can use if you can decode a list of your keys,
and given a key, you can produce a decoder for the corresponding value. The
order within the `AllDictList` will be the order of your list of keys.
-}
decodeWithKeys : List comparable -> (comparable -> Decoder value) -> Decoder (AllDictList comparable value)
decodeWithKeys keys func =
    let
        go jsonValue key accum =
            case ( accum, decodeValue (func key) jsonValue ) of
                ( Ok goodSoFar, Ok thisTime ) ->
                    -- If we've been successful so far, and OK this time, then accumulate
                    Ok <| insert key thisTime goodSoFar

                ( Ok goodSoFar, Err err ) ->
                    -- If we were OK until now, but this one erred, then the whole thing fails
                    Err err

                ( Err err, Ok _ ) ->
                    -- If we've already had an error, but this one is good, just keep the error
                    accum

                ( Err err1, Err err2 ) ->
                    -- If we had an error, and we have another one, combine them
                    Err <| err1 ++ "\n" ++ err2
    in
        value
            |> Json18.andThen
                (\jsonValue ->
                    case List.foldl (go jsonValue) (Ok empty) keys of
                        Ok result ->
                            Json.Decode.succeed result

                        Err err ->
                            Json.Decode.fail err
                )


{-| Like `decodeWithKeys`, but you supply a decoder for the keys, rather than the keys themselves.

Note that the starting point for all decoders will be the same place, so you need to construct your
decoders in a way that makes that work.
-}
decodeKeysAndValues : Decoder (List comparable) -> (comparable -> Decoder value) -> Decoder (AllDictList comparable value)
decodeKeysAndValues keyDecoder func =
    keyDecoder
        |> Json18.andThen (\keys -> decodeWithKeys keys func)


{-| Given a decoder for the value, and a way of turning the value into a key,
decode an array of values into a `AllDictList`. The order within the `AllDictList`
will be the order of the JSON array.
-}
decodeArray : (value -> comparable) -> Decoder value -> Decoder (AllDictList comparable value)
decodeArray keyMapper valueDecoder =
    Json.Decode.map
        (List.map (\value -> ( keyMapper value, value )) >> fromList)
        (Json.Decode.list valueDecoder)


{-| Decodes a JSON array into the AllDictList. You supply two decoders. Given an element
of your JSON array, the first decoder should decode the key, and the second decoder
should decode the value.
-}
decodeArray2 : Decoder comparable -> Decoder value -> Decoder (AllDictList comparable value)
decodeArray2 keyDecoder valueDecoder =
    Json18.map2 (,) keyDecoder valueDecoder
        |> Json.Decode.list
        |> Json.Decode.map fromList



----------------------
-- From `List` in core
----------------------


{-| Insert a key-value pair at the front. Moves the key to the front if
    it already exists.
-}
cons : comparable -> value -> AllDictList comparable value -> AllDictList comparable value
cons key value (AllDictList dict list) =
    let
        restOfList =
            if Dict.member key dict then
                List.Extra.remove key list
            else
                list
    in
        AllDictList
            (Dict.insert key value dict)
            (key :: restOfList)


{-| Gets the first key with its value.
-}
head : AllDictList comparable value -> Maybe ( comparable, value )
head (AllDictList dict list) =
    List.head list
        |> Maybe18.andThen (\key -> Dict.get key dict |> Maybe.map (\value -> ( key, value )))


{-| Extract the rest of the `AllDictList`, without the first key/value pair.
-}
tail : AllDictList comparable value -> Maybe (AllDictList comparable value)
tail (AllDictList dict list) =
    case list of
        first :: rest ->
            Just <|
                AllDictList (Dict.remove first dict) rest

        _ ->
            Nothing


{-| Like `map` but the function is also given the index of each
element (starting at zero).
-}
indexedMap : (Int -> comparable -> a -> b) -> AllDictList comparable a -> AllDictList comparable b
indexedMap func =
    let
        go key value ( index, AllDictList dict list ) =
            ( index + 1
            , AllDictList
                (Dict.insert key (func index key value) dict)
                (key :: list)
            )
    in
        -- We need to foldl, because the first element should get the 0 index.
        -- But we build up the resulting list with `::`, for efficiency, so
        -- we reverse once at the end.
        foldl go ( 0, empty ) >> second >> reverse


{-| Apply a function that may succeed to all key-value pairs, but only keep
the successes.
-}
filterMap : (comparable -> a -> Maybe b) -> AllDictList comparable a -> AllDictList comparable b
filterMap func =
    let
        go key value acc =
            func key value
                |> Maybe.map (\result -> cons key result acc)
                |> Maybe.withDefault acc
    in
        foldr go empty


{-| The number of key-value pairs in the `AllDictList`.
-}
length : AllDictList key value -> Int
length =
    size


{-| Reverse the order of the key-value pairs.
-}
reverse : AllDictList key value -> AllDictList key value
reverse (AllDictList dict list) =
    AllDictList dict (List.reverse list)


{-| Determine if all elements satisfy the predicate.
-}
all : (comparable -> value -> Bool) -> AllDictList comparable value -> Bool
all func dictlist =
    not (any (\key value -> not (func key value)) dictlist)


{-| Determine if any elements satisfy the predicate.
-}
any : (comparable -> value -> Bool) -> AllDictList comparable value -> Bool
any func (AllDictList dict list) =
    let
        go innerList =
            case innerList of
                [] ->
                    False

                first :: rest ->
                    if func first (unsafeGet first dict) then
                        True
                    else
                        go rest
    in
        go list


{-| Put two dictionaries together.

If keys collide, preference is given to the value from the second `AllDictList`.
Also, the order of the keys in the second `AllDictList` will be preserved at the
end of the result.

So, you could think of `append` as biased towards the second argument. The end
of the result should be equal to the second argument, both in value and key-order.
The front of the result will then be whatever is left from the first argument --
that is, those keys (and their values) that were not in the second argument.

For a similar function that is biased towards the first argument, see `union`.
-}
append : AllDictList comparable value -> AllDictList comparable value -> AllDictList comparable value
append t1 t2 =
    let
        go key value acc =
            -- We're right-favouring, so only act if the key is not already present
            if member key acc then
                acc
            else
                cons key value acc
    in
        foldr go t2 t1


{-| Concatenate a bunch of dictionaries into a single dictionary.

Works from left to right, applying `append` as it goes.
-}
concat : List (AllDictList comparable value) -> AllDictList comparable value
concat lists =
    List.foldr append empty lists


{-| Get the sum of the values.
-}
sum : AllDictList comparable number -> number
sum (AllDictList dict list) =
    Dict.foldl (always (+)) 0 dict


{-| Get the product of the values.
-}
product : AllDictList comparable number -> number
product (AllDictList dict list) =
    Dict.foldl (always (*)) 1 dict


{-| Find the maximum value. Returns `Nothing` if empty.
-}
maximum : AllDictList comparable1 comparable2 -> Maybe comparable2
maximum (AllDictList dict list) =
    -- I considered having `maximum` and `minimum` return the key
    -- as well, but there is a bit of a puzzle there. What would
    -- one do when there are ties for the maximum value?
    let
        go _ value acc =
            case acc of
                Nothing ->
                    Just value

                Just bestSoFar ->
                    Just <| max bestSoFar value
    in
        Dict.foldl go Nothing dict


{-| Find the minimum value. Returns `Nothing` if empty.
-}
minimum : AllDictList comparable1 comparable2 -> Maybe comparable2
minimum (AllDictList dict list) =
    let
        go _ value acc =
            case acc of
                Nothing ->
                    Just value

                Just bestSoFar ->
                    Just <| min bestSoFar value
    in
        Dict.foldl go Nothing dict


{-| Take the first *n* values.
-}
take : Int -> AllDictList comparable value -> AllDictList comparable value
take n (AllDictList dict list) =
    let
        newList =
            List.take n list

        newDict =
            List.foldl go Dict.empty newList

        go key =
            Dict.insert key (unsafeGet key dict)
    in
        AllDictList newDict newList


{-| Drop the first *n* values.
-}
drop : Int -> AllDictList comparable value -> AllDictList comparable value
drop n (AllDictList dict list) =
    let
        newList =
            List.drop n list

        newDict =
            List.foldl go Dict.empty newList

        go key =
            Dict.insert key (unsafeGet key dict)
    in
        AllDictList newDict newList


{-| Sort values from lowest to highest
-}
sort : AllDictList comparable1 comparable2 -> AllDictList comparable1 comparable2
sort dictList =
    case dictList of
        AllDictList dict list ->
            toList dictList
                |> List.sortBy second
                |> List.map first
                |> AllDictList dict


{-| Sort values by a derived property.
-}
sortBy : (value -> comparable) -> AllDictList comparable2 value -> AllDictList comparable2 value
sortBy func dictList =
    case dictList of
        AllDictList dict list ->
            toList dictList
                |> List.sortBy (func << second)
                |> List.map first
                |> AllDictList dict


{-| Sort values with a custom comparison function.
-}
sortWith : (value -> value -> Order) -> AllDictList comparable value -> AllDictList comparable value
sortWith func dictList =
    case dictList of
        AllDictList dict list ->
            toList dictList
                |> List.sortWith (\v1 v2 -> func (second v1) (second v2))
                |> List.map first
                |> AllDictList dict



----------------
-- List-oriented
----------------


{-| Given a key, what index does that key occupy (0-based) in the
order maintained by the `AllDictList`?
-}
indexOfKey : comparable -> AllDictList comparable value -> Maybe Int
indexOfKey key (AllDictList dict list) =
    List.Extra.elemIndex key list


{-| Given a key, get the key and value at the next position.
-}
next : comparable -> AllDictList comparable value -> Maybe ( comparable, value )
next key dictlist =
    indexOfKey key dictlist
        |> Maybe18.andThen (\index -> getAt (index + 1) dictlist)


{-| Given a key, get the key and value at the previous position.
-}
previous : comparable -> AllDictList comparable value -> Maybe ( comparable, value )
previous key dictlist =
    indexOfKey key dictlist
        |> Maybe18.andThen (\index -> getAt (index - 1) dictlist)


{-| Gets the key at the specified index (0-based).
-}
getKeyAt : Int -> AllDictList key value -> Maybe key
getKeyAt index (AllDictList dict list) =
    List.Extra.getAt index list


{-| Gets the key and value at the specified index (0-based).
-}
getAt : Int -> AllDictList comparable value -> Maybe ( comparable, value )
getAt index (AllDictList dict list) =
    List.Extra.getAt index list
        |> Maybe18.andThen
            (\key ->
                Dict.get key dict
                    |> Maybe.map (\value -> ( key, value ))
            )


{-| Insert a key-value pair into a `AllDictList`, replacing an existing value if
the keys collide. The first parameter represents an existing key, while the
second parameter is the new key. The new key and value will be inserted after
the existing key (even if the new key already exists). If the existing key
cannot be found, the new key/value pair will be inserted at the end.
-}
insertAfter : comparable -> comparable -> v -> AllDictList comparable v -> AllDictList comparable v
insertAfter afterKey key value (AllDictList dict list) =
    let
        newDict =
            Dict.insert key value dict

        newList =
            if afterKey == key then
                -- If we want to insert it after itself, we can short-circuit
                list
            else
                let
                    listWithoutKey =
                        if Dict.member key dict then
                            List.Extra.remove key list
                        else
                            -- If the key wasn't present, we can skip the removal
                            list
                in
                    case List.Extra.elemIndex afterKey listWithoutKey of
                        Just index ->
                            -- We found the existing element, so take apart the list
                            -- and put it back together
                            List.take (index + 1) listWithoutKey
                                ++ (key :: List.drop (index + 1) listWithoutKey)

                        Nothing ->
                            -- The afterKey wasn't found, so we insert the key at the end
                            listWithoutKey ++ [ key ]
    in
        AllDictList newDict newList


{-| Insert a key-value pair into a `AllDictList`, replacing an existing value if
the keys collide. The first parameter represents an existing key, while the
second parameter is the new key. The new key and value will be inserted before
the existing key (even if the new key already exists). If the existing key
cannot be found, the new key/value pair will be inserted at the beginning.
-}
insertBefore : comparable -> comparable -> v -> AllDictList comparable v -> AllDictList comparable v
insertBefore beforeKey key value (AllDictList dict list) =
    let
        newDict =
            Dict.insert key value dict

        newList =
            if beforeKey == key then
                -- If we want to insert it before itself, we can short-circuit
                list
            else
                let
                    listWithoutKey =
                        if Dict.member key dict then
                            List.Extra.remove key list
                        else
                            -- If the key wasn't present, we can skip the removal
                            list
                in
                    case List.Extra.elemIndex beforeKey listWithoutKey of
                        Just index ->
                            -- We found the existing element, so take apart the list
                            -- and put it back together
                            List.take index listWithoutKey
                                ++ (key :: List.drop index listWithoutKey)

                        Nothing ->
                            -- The beforeKey wasn't found, so we insert the key at the beginning
                            key :: listWithoutKey
    in
        AllDictList newDict newList


{-| Get the position of a key relative to the previous key (or next, if the
first key). Returns `Nothing` if the key was not found.
-}
relativePosition : comparable -> AllDictList comparable v -> Maybe (RelativePosition comparable)
relativePosition key dictlist =
    case previous key dictlist of
        Just ( previousKey, _ ) ->
            Just (AfterKey previousKey)

        Nothing ->
            case next key dictlist of
                Just ( nextKey, _ ) ->
                    Just (BeforeKey nextKey)

                Nothing ->
                    Nothing


{-| Gets the key-value pair currently at the indicated relative position.
-}
atRelativePosition : RelativePosition comparable -> AllDictList comparable value -> Maybe ( comparable, value )
atRelativePosition position dictlist =
    case position of
        BeforeKey beforeKey ->
            previous beforeKey dictlist

        AfterKey afterKey ->
            next afterKey dictlist


{-| Insert a key-value pair into a `AllDictList`, replacing an existing value if
the keys collide. The first parameter represents an existing key, while the
second parameter is the new key. The new key and value will be inserted
relative to the existing key (even if the new key already exists). If the
existing key cannot be found, the new key/value pair will be inserted at the
beginning (if the new key was to be before the existing key) or the end (if the
new key was to be after).
-}
insertRelativeTo : RelativePosition comparable -> comparable -> v -> AllDictList comparable v -> AllDictList comparable v
insertRelativeTo position =
    case position of
        BeforeKey beforeKey ->
            insertBefore beforeKey

        AfterKey afterKey ->
            insertAfter afterKey



--------------
-- From `Dict`
--------------


{-| Create an empty `AllDictList`.
-}
empty : AllDictList k v
empty =
    AllDictList Dict.empty []


{-| Get the value associated with a key. If the key is not found, return
`Nothing`.
-}
get : comparable -> AllDictList comparable v -> Maybe v
get key (AllDictList dict list) =
    -- So, this is basically the key thing that is optimized, compared
    -- to an association list.
    Dict.get key dict


{-| Determine whether a key is in the `AllDictList`.
-}
member : comparable -> AllDictList comparable v -> Bool
member key (AllDictList dict list) =
    Dict.member key dict


{-| Determine the number of key-value pairs in the `AllDictList`.
-}
size : AllDictList k v -> Int
size (AllDictList dict list) =
    Dict.size dict


{-| Determine whether a `AllDictList` is empty.
-}
isEmpty : AllDictList k v -> Bool
isEmpty (AllDictList dict list) =
    List.isEmpty list


{-| Insert a key-value pair into a `AllDictList`. Replaces the value when the
keys collide, leaving the keys in the same order as they had been in.
If the key did not previously exist, it is added to the end of
the list.
-}
insert : comparable -> v -> AllDictList comparable v -> AllDictList comparable v
insert key value (AllDictList dict list) =
    let
        newDict =
            Dict.insert key value dict

        newList =
            if Dict.member key dict then
                -- We know this key, so leave it where it was
                list
            else
                -- We don't know this key, so also insert it at the end of the list.
                list ++ [ key ]
    in
        AllDictList newDict newList


{-| Remove a key-value pair from a `AllDictList`. If the key is not found,
no changes are made.
-}
remove : comparable -> AllDictList comparable v -> AllDictList comparable v
remove key dictList =
    case dictList of
        AllDictList dict list ->
            if Dict.member key dict then
                -- Lists are not particularly optimized for removals ...
                -- if that becomes a practical issue, we could perhaps
                -- use an `Array` instead.
                AllDictList
                    (Dict.remove key dict)
                    (List.Extra.remove key list)
            else
                -- We avoid the list removal efficiently in this branch.
                dictList


{-| Update the value for a specific key with a given function. Maintains
the order of the key, or inserts it at the end if it is new.
-}
update : comparable -> (Maybe v -> Maybe v) -> AllDictList comparable v -> AllDictList comparable v
update key alter dictList =
    case alter (get key dictList) of
        Nothing ->
            remove key dictList

        Just value ->
            insert key value dictList


{-| Create a `AllDictList` with one key-value pair.
-}
singleton : comparable -> v -> AllDictList comparable v
singleton key value =
    AllDictList (Dict.singleton key value) [ key ]



-- COMBINE


{-| Combine two dictionaries. If keys collide, preference is given
to the value from the first `AllDictList`.

Keys already in the first `AllDictList` will remain in their original order.

Keys newly added from the second `AllDictList` will be added at the end.

So, you might think of `union` as being biased towards the first argument,
since it preserves both key-order and values from the first argument, only
adding things on the right (from the second argument) for keys that were not
present in the first. This seems to correspond best to the logic of `Dict.union`.

For a similar function that is biased towards the second argument, see `append`.
-}
union : AllDictList comparable v -> AllDictList comparable v -> AllDictList comparable v
union t1 t2 =
    foldr cons t2 t1


{-| Keep a key-value pair when its key appears in the second `AllDictList`.
Preference is given to values in the first `AllDictList`. The resulting
order of keys will be as it was in the first `AllDictList`.
-}
intersect : AllDictList comparable v -> AllDictList comparable v -> AllDictList comparable v
intersect t1 t2 =
    filter (\k _ -> member k t2) t1


{-| Keep a key-value pair when its key does not appear in the second `AllDictList`.
-}
diff : AllDictList comparable v -> AllDictList comparable v -> AllDictList comparable v
diff t1 t2 =
    foldl (\k v t -> remove k t) t1 t2


{-| The most general way of combining two dictionaries. You provide three
accumulators for when a given key appears:

  1. Only in the left `AllDictList`.
  2. In both dictionaries.
  3. Only in the right `AllDictList`.

You then traverse all the keys and values, building up whatever
you want.

The keys and values from the first `AllDictList` will be provided first,
in the order maintained by the first `AllDictList`. Then, any keys which are
only in the second `AllDictList` will be provided, in the order maintained
by the second `AllDictList`.
-}
merge :
    (comparable -> a -> result -> result)
    -> (comparable -> a -> b -> result -> result)
    -> (comparable -> b -> result -> result)
    -> AllDictList comparable a
    -> AllDictList comparable b
    -> result
    -> result
merge leftFunc bothFunc rightFunc leftDict (AllDictList rightDict rightList) initialResult =
    let
        goLeft leftKey leftValue ( remainingRight, accumLeft ) =
            case Dict.get leftKey rightDict of
                Just rightValue ->
                    -- The left key is also in the right dict. So, we remove it
                    -- from the right (since we'll deal with it here) and we
                    -- apply the `bothFunc`
                    ( Dict.remove leftKey remainingRight
                    , bothFunc leftKey leftValue rightValue accumLeft
                    )

                Nothing ->
                    -- The left key is not in the right dict. So, we leave the
                    -- right dict alone, and apply the leftFunc
                    ( remainingRight
                    , leftFunc leftKey leftValue accumLeft
                    )

        goRight remainingRight rightKey accumRight =
            case Dict.get rightKey remainingRight of
                Just rightValue ->
                    -- If we still have one, it means it was only on the right
                    rightFunc rightKey rightValue accumRight

                Nothing ->
                    -- If we don't have it anymore, it was dealt with on the left
                    accumRight
    in
        -- We start on the left, because we have said that the order we'll follow
        -- is left-favouring.
        foldl goLeft ( rightDict, initialResult ) leftDict
            |> (\( remainingRight, accumLeft ) ->
                    -- Now, we go through the right hand side, for those things that
                    -- weren't also on the left.
                    List.foldl (goRight remainingRight) accumLeft rightList
               )



-- TRANSFORM


{-| Apply a function to all values in a `AllDictList`.
-}
map : (comparable -> a -> b) -> AllDictList comparable a -> AllDictList comparable b
map func (AllDictList dict list) =
    AllDictList (Dict.map func dict) list


{-| Fold over the key-value pairs in a `AllDictList`, in order from the first
key to the last key (given the arbitrary order maintained by the `AllDictList`).
-}
foldl : (comparable -> v -> b -> b) -> b -> AllDictList comparable v -> b
foldl func accum (AllDictList dict list) =
    let
        go key acc =
            func key (unsafeGet key dict) acc
    in
        List.foldl go accum list


{-| Fold over the key-value pairs in a `AllDictList`, in order from the last
key to the first key (given the arbitrary order maintained by the `AllDictList`.
-}
foldr : (comparable -> v -> b -> b) -> b -> AllDictList comparable v -> b
foldr func accum (AllDictList dict list) =
    let
        go key acc =
            case Dict.get key dict of
                Just value ->
                    func key value acc

                Nothing ->
                    Debug.crash "Internal error: AllDictList list not in sync with dict"
    in
        List.foldr go accum list


{-| Keep a key-value pair when it satisfies a predicate.
-}
filter : (comparable -> v -> Bool) -> AllDictList comparable v -> AllDictList comparable v
filter predicate dictList =
    let
        add key value dict =
            if predicate key value then
                insert key value dict
            else
                dict
    in
        foldl add empty dictList


{-| Partition a `AllDictList` according to a predicate. The first `AllDictList`
contains all key-value pairs which satisfy the predicate, and the second
contains the rest.
-}
partition : (comparable -> v -> Bool) -> AllDictList comparable v -> ( AllDictList comparable v, AllDictList comparable v )
partition predicate dict =
    let
        add key value ( t1, t2 ) =
            if predicate key value then
                ( insert key value t1, t2 )
            else
                ( t1, insert key value t2 )
    in
        foldl add ( empty, empty ) dict



-- LISTS


{-| Get all of the keys in a `AllDictList`, in the order maintained by the `AllDictList`.
-}
keys : AllDictList comparable v -> List comparable
keys (AllDictList dict list) =
    list


{-| Get all of the values in a `AllDictList`, in the order maintained by the `AllDictList`.
-}
values : AllDictList comparable v -> List v
values dictList =
    foldr (\key value valueList -> value :: valueList) [] dictList


{-| Convert a `AllDictList` into an association list of key-value pairs, in the order maintained by the `AllDictList`.
-}
toList : AllDictList comparable v -> List ( comparable, v )
toList dict =
    foldr (\key value list -> ( key, value ) :: list) [] dict


{-| Convert an association list into a `AllDictList`, maintaining the order of the list.
-}
fromList : List ( comparable, v ) -> AllDictList comparable v
fromList assocs =
    List.foldl (\( key, value ) dict -> insert key value dict) empty assocs


{-| Extract a `Dict` from a `AllDictList`
-}
toDict : AllDictList comparable v -> Dict comparable v
toDict (AllDictList dict list) =
    dict


{-| Given a `Dict`, create a `AllDictList`. The keys will initially be in the
order that the `Dict` provides.
-}
fromDict : Dict comparable v -> AllDictList comparable v
fromDict dict =
    AllDictList dict (Dict.keys dict)



-------------
-- Dict.Extra
-------------


{-| Takes a key-fn and a list.

Creates a `AllDictList` which maps the key to a list of matching elements.

    mary = {id=1, name="Mary"}
    jack = {id=2, name="Jack"}
    jill = {id=1, name="Jill"}

    groupBy .id [mary, jack, jill] == AllDictList.fromList [(1, [mary, jill]), (2, [jack])]
-}
groupBy : (a -> comparable) -> List a -> AllDictList comparable (List a)
groupBy keyfn list =
    List.foldr
        (\x acc ->
            update (keyfn x) (Maybe.map ((::) x) >> Maybe.withDefault [ x ] >> Just) acc
        )
        empty
        list


{-| Create a `AllDictList` from a list of values, by passing a function that can
get a key from any such value. If the function does not return unique keys,
earlier values are discarded.

This can, for instance, be useful when constructing a `AllDictList` from a List of
records with `id` fields:

    mary = {id=1, name="Mary"}
    jack = {id=2, name="Jack"}
    jill = {id=1, name="Jill"}

    fromListBy .id [mary, jack, jill] == AllDictList.fromList [(1, jack), (2, jill)]
-}
fromListBy : (a -> comparable) -> List a -> AllDictList comparable a
fromListBy keyfn xs =
    List.foldl
        (\x acc -> insert (keyfn x) x acc)
        empty
        xs


{-| Remove elements which satisfies the predicate.

    removeWhen (\_ v -> v == 1) (AllDictList.fromList [("Mary", 1), ("Jack", 2), ("Jill", 1)]) == AllDictList.fromList [("Jack", 2)]
-}
removeWhen : (comparable -> v -> Bool) -> AllDictList comparable v -> AllDictList comparable v
removeWhen pred dict =
    filter (\k v -> not (pred k v)) dict


{-| Remove a key-value pair if its key appears in the set.
-}
removeMany : Set comparable -> AllDictList comparable v -> AllDictList comparable v
removeMany set dict =
    Set.foldl (\k acc -> remove k acc) dict set


{-| Keep a key-value pair if its key appears in the set.
-}
keepOnly : Set comparable -> AllDictList comparable v -> AllDictList comparable v
keepOnly set dict =
    Set.foldl
        (\k acc ->
            Maybe.withDefault acc <| Maybe.map (\v -> insert k v acc) (get k dict)
        )
        empty
        set


{-| Apply a function to all keys in a dictionary.
-}
mapKeys : (comparable1 -> comparable2) -> AllDictList comparable1 v -> AllDictList comparable2 v
mapKeys keyMapper dict =
    let
        addKey key value d =
            insert (keyMapper key) value d
    in
        foldl addKey empty dict



-----------
-- Internal
-----------


{-| For cases where we know the key must be in the `Dict`.
-}
unsafeGet : comparable -> Dict comparable value -> value
unsafeGet key dict =
    case Dict.get key dict of
        Just value ->
            value

        Nothing ->
            Debug.crash "Internal error: AllDictList list not in sync with dict"