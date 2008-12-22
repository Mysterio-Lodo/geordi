{-# LANGUAGE DeriveDataTypeable, MultiParamTypeClasses, FunctionalDependencies, FlexibleInstances, FlexibleContexts, UndecidableInstances, PatternGuards, Rank2Types, OverlappingInstances #-}

module Cxx.Operations (apply, mapply, apply_makedecl, squared, parenthesized, is_primary_TypeSpecifier, split_all_decls, map_plain, shortcut_syntaxes, blob, resume, expand, line_breaks, specT) where

import qualified Cxx.Show
import qualified Data.List as List
import qualified Data.Char as Char
import qualified Data.Maybe as Maybe
import Util (NElist(..), unne, (.), Convert(..), total_tail, filter_ne, isIdChar, TriBool(..), maybe_ne)
import Cxx.Basics
import Control.Monad (foldM)
import Control.Arrow (second)
import Data.Generics (cast, gmapT, everywhere, everywhereM, Data, Typeable, Typeable1, gfoldl)

import Prelude hiding ((.))

-- Operations on Chunks/Code

map_plain :: (String -> String) -> Chunk -> Chunk
map_plain f (Plain s) = Plain $ f s
map_plain f (Curlies c) = Curlies $ map (map_plain f) c
map_plain f (Parens c) = Parens $ map (map_plain f) c
map_plain f (Squares c) = Squares $ map (map_plain f) c
map_plain _ x = x

expand :: ShortCode -> Code
expand (LongForm c) = c
expand (Block c c') = c' ++ [Plain "\nint main(int argc, char * argv[])", Curlies c]
expand (Print c c') = expand $ Block ([Plain "::std::cout << "] ++ c ++ [Plain "\n;"]) c'
  -- The newline before the semicolon makes //-style comments work.

cstyle_comments :: Code -> Code
cstyle_comments = map f where f (SingleComment s) = MultiComment s; f c = c

expand_without_main :: ShortCode -> Code
expand_without_main (LongForm d) = erase_main d
  where
    erase_main (Plain s : Parens _ : Curlies _ : c) | "main" `List.isInfixOf` s = c
    erase_main (Plain s : Parens _ : Plain t : Curlies _ : c)
      | "main" `List.isInfixOf` s && all Char.isSpace t = c
    erase_main (x : y) = (x :) $ erase_main y
    erase_main c = c
expand_without_main (Print _ c) = c
expand_without_main (Block _ c) = c

blob :: ShortCode -> Code
blob (LongForm c) = c
blob (Print c c') = [Plain "<<"] ++ c ++ [Plain ";"] ++ c'
blob (Block c c') = Curlies c : c'

resume :: ShortCode -> ShortCode -> ShortCode
resume old new = case new of
    LongForm c -> LongForm $ old' ++ c
    Print c c' -> Print c $ old' ++ c'
    Block c c' -> Block c $ old' ++ c'
  where old' = cstyle_comments $ expand_without_main old

shortcut_syntaxes :: Code -> ShortCode
shortcut_syntaxes (Curlies c : b) = Block c b
shortcut_syntaxes (Plain ('<':'<':x) : y) = uncurry Print $ second total_tail $ break (== Plain ";") $ Plain x : y
shortcut_syntaxes c = LongForm c

line_breaks ::Code -> Code
line_breaks = map $ map_plain $ map $ \c -> if c == '\\' then '\n' else c

-- Convenience constructors

squared :: a -> Squared a
squared x = Squared (OpenSquare_, White "") (Enclosed x) (CloseSquare_, White "")

parenthesized :: a -> Parenthesized a
parenthesized x = Parenthesized (OpenParen_, White "") (Enclosed x) (CloseParen_, White "")

specT :: TypeSpecifier
specT = TypeSpecifier_SimpleTypeSpecifier $ SimpleTypeSpecifier_TypeName (OptQualified Nothing Nothing) $ TypeName_ClassName $ ClassName_Identifier $ Identifier "T" $ White " "

-- Applying make-specifications.

apply_makedecl :: MakeDeclaration -> DeclaratorId -> GeordiRequest -> Either String GeordiRequest
apply_makedecl d s = apply_makedecl_to s d . split_all_decls
  -- Todo: Only split when necessary.

apply_makedecl_to :: (Typeable1 m, Monad m, Data d) => DeclaratorId -> MakeDeclaration -> d -> m d
apply_makedecl_to s makedecl = everywhereM $ maybe return id $ Maybe.listToMaybe . Maybe.catMaybes $
  [ cast $ ((\d -> case d of
    SimpleDeclaration specs (Just (Commad (InitDeclarator x mi) [])) w | convert x == s ->
      case makedecl of
        MakeDeclaration _ _ Definitely -> fail "Cannot purify simple-declaration."
        MakeDeclaration specs' mpad _ -> return $ let (specs'', x') = apply (specs', mpad) (specs, x) in
          SimpleDeclaration specs'' (Just (Commad (InitDeclarator x' mi) [])) w
    _ -> return d) :: SimpleDeclaration -> Either String SimpleDeclaration)
  , cast $ ((\d -> case d of
    ParameterDeclaration specs (Left x) m | convert x == s ->
      case makedecl of
        MakeDeclaration _ _ Definitely -> fail "Cannot purify parameter-declaration."
        MakeDeclaration specs' mpad _ -> return $ let (specs'', x') = apply (specs', mpad) (specs, x) in
          ParameterDeclaration specs'' (Left x') m
    _ -> return d) :: ParameterDeclaration -> Either String ParameterDeclaration)
  , cast $ ((\d -> case d of
    ExceptionDeclaration u (Just (Left e)) | convert e == s ->
      case makedecl of
        MakeDeclaration _ _ Definitely -> fail "Cannot purify exception-declaration."
        MakeDeclaration specs mpad _ ->
          (\(u', e') -> ExceptionDeclaration u' $ Just $ Left e') . mapply (specs, mpad) (u, e)
    _ -> return d) :: ExceptionDeclaration -> Either String ExceptionDeclaration)
  , cast $ ((\d -> case d of
    MemberDeclaration specs (Commad (MemberDeclarator decl ps) []) semicolon | convert decl == s ->
      return $ let (specs', decl', ps') = apply makedecl (specs, decl, ps) in
        MemberDeclaration specs' (Commad (MemberDeclarator decl' ps') []) semicolon
    _ -> return d) :: MemberDeclaration -> Either String MemberDeclaration)
  , cast $ ((\d -> case d of
    FunctionDefinition specs decl body | convert decl == s ->
      case makedecl of
        MakeDeclaration _ _ Definitely -> fail "Cannot purify function-definition."
        MakeDeclaration specs' mpad _ -> return $ let (specs'', decl') = apply (specs', mpad) (specs, decl) in
          FunctionDefinition specs'' decl' body
    _ -> return d) :: FunctionDefinition -> Either String FunctionDefinition)
  ]

-- Specifier/qualifier compatibility.

class Compatible a b where compatible :: a -> b -> Bool
  -- For instances where a=b, compatible should be symmetric.

instance Compatible CvQualifier CvQualifier where compatible = (/=)

instance Compatible CvQualifier TypeSpecifier where
  compatible cv (TypeSpecifier_CvQualifier (cv', _)) = compatible cv cv'
  compatible _ _ = True

instance Compatible CvQualifier DeclSpecifier where
  compatible cv (DeclSpecifier_TypeSpecifier t) = compatible cv t
  compatible _ _ = True

instance Compatible SimpleTypeSpecifier SimpleTypeSpecifier where
  compatible (SignSpec _) (LengthSpec _) = True
  compatible (LengthSpec _) (SignSpec _) = True
  compatible (LengthSpec (LongSpec, _)) (LengthSpec (LongSpec, _)) = True
  compatible (LengthSpec (LongSpec, _)) (SimpleTypeSpecifier_BasicType (Int', _)) = True
  compatible (LengthSpec (LongSpec, _)) (SimpleTypeSpecifier_BasicType (Double', _)) = True
  compatible x@(SimpleTypeSpecifier_BasicType _) y@(LengthSpec _) = compatible y x
  compatible (SignSpec _) (SimpleTypeSpecifier_BasicType (Int', _)) = True
  compatible (SimpleTypeSpecifier_BasicType (Int', _)) (SignSpec _) = True
  compatible _ _ = False

instance Compatible TypeSpecifier TypeSpecifier where
  compatible (TypeSpecifier_CvQualifier (cv, _)) (TypeSpecifier_CvQualifier (cv', _)) = compatible cv cv'
  compatible (TypeSpecifier_CvQualifier _) _ = True
  compatible _ (TypeSpecifier_CvQualifier _) = True
  compatible (TypeSpecifier_SimpleTypeSpecifier x) (TypeSpecifier_SimpleTypeSpecifier y) = compatible x y
  compatible _ _ = False

instance Compatible MakeSpecifier MakeSpecifier where
  compatible (MakeSpecifier_DeclSpecifier d) (MakeSpecifier_DeclSpecifier d') = compatible d d'
  compatible x@(MakeSpecifier_DeclSpecifier _) y = compatible y x
  compatible (NonStorageClassSpecifier scs) (MakeSpecifier_DeclSpecifier (DeclSpecifier_StorageClassSpecifier (scs', _))) = scs /= scs'
  compatible _ _ = True

instance Compatible DeclSpecifier DeclSpecifier where
  compatible (DeclSpecifier_TypeSpecifier x) (DeclSpecifier_TypeSpecifier y) = compatible x y
  compatible (DeclSpecifier_StorageClassSpecifier _) (DeclSpecifier_StorageClassSpecifier _) = False
  compatible (DeclSpecifier_FunctionSpecifier (s, _)) (DeclSpecifier_FunctionSpecifier (s', _)) | s == s' = False
  compatible (DeclSpecifier_Typedef _) (DeclSpecifier_Typedef _) = False
  compatible (DeclSpecifier_ConstExpr _) (DeclSpecifier_ConstExpr _) = False
  compatible (DeclSpecifier_AlignmentSpecifier _) (DeclSpecifier_AlignmentSpecifier _) = False
  compatible (DeclSpecifier_FunctionSpecifier (Virtual, _)) (DeclSpecifier_StorageClassSpecifier (Static, _)) = False
  compatible (DeclSpecifier_StorageClassSpecifier (Static, _)) (DeclSpecifier_FunctionSpecifier (Virtual, _)) = False
  compatible _ _ = True

-- Getting declarator-ids out of declarators.

instance Convert Declarator DeclaratorId where convert (Declarator_PtrDeclarator p) = convert p

instance Convert PtrDeclarator DeclaratorId where
  convert (PtrDeclarator_NoptrDeclarator d) = convert d
  convert (PtrDeclarator _ d) = convert d

instance Convert NoptrDeclarator DeclaratorId where
  convert (NoptrDeclarator_Id did) = did
  convert (NoptrDeclarator_WithParams d _) = convert d
  convert (NoptrDeclarator_Squared d _) = convert d
  convert (NoptrDeclarator_Parenthesized (Parenthesized _ (Enclosed d) _)) = convert d

-- Making sure things end with whitespace.

data WithAlternate a = WithoutAlternate a | WithAlternate { wa_primary :: a, wa_alternate :: a } deriving Typeable

instance Functor WithAlternate where
  fmap f (WithoutAlternate x) = WithoutAlternate $ f x
  fmap f (WithAlternate x y) = WithAlternate (f x) (f y)

with_trailing_white :: Data d => d -> d
with_trailing_white = \x -> case f x of WithoutAlternate y -> y; WithAlternate _ y -> y
  where
    f :: Data d => d -> WithAlternate d
    f | Just h <- cast (\w@(White s) -> WithAlternate w (White $ if null s then " " else s)) = h
      | otherwise = flip gfoldl WithoutAlternate $ \e d -> case e of
        (WithAlternate h i) -> case f d of
          WithoutAlternate x -> WithAlternate (h x) (i x)
          WithAlternate x y -> WithAlternate (h x) (h y)
        (WithoutAlternate h) -> h . f d

-- Specifier/qualifier conversion

instance Convert (BasicType, White) TypeSpecifier where convert = TypeSpecifier_SimpleTypeSpecifier . SimpleTypeSpecifier_BasicType
instance Convert (BasicType, White) DeclSpecifier where convert = (convert :: TypeSpecifier -> DeclSpecifier) . convert
instance Convert CvQualifier TypeSpecifier where convert cvq = TypeSpecifier_CvQualifier (cvq, White " ")
instance Convert CvQualifier DeclSpecifier where convert = convert . (convert :: CvQualifier -> TypeSpecifier)
instance Convert CvQualifier MakeSpecifier where convert = convert . (convert :: TypeSpecifier -> DeclSpecifier) . convert
instance Convert SimpleTypeSpecifier (Maybe Sign) where convert (SignSpec (s, _)) = Just s; convert _ = Nothing
instance Convert SimpleTypeSpecifier (Maybe LengthSpec) where convert (LengthSpec (s, _)) = Just s; convert _ = Nothing
instance Convert TypeSpecifier DeclSpecifier where convert = DeclSpecifier_TypeSpecifier
instance Convert TypeSpecifier (Maybe Sign) where convert x = convert x >>= (convert :: SimpleTypeSpecifier -> Maybe Sign)
instance Convert TypeSpecifier (Maybe SimpleTypeSpecifier) where convert (TypeSpecifier_SimpleTypeSpecifier s) = Just s; convert _ = Nothing
instance Convert TypeSpecifier (Maybe LengthSpec) where convert x = convert x >>= (convert :: SimpleTypeSpecifier -> Maybe LengthSpec)
instance Convert TypeSpecifier (Maybe (CvQualifier, White)) where convert (TypeSpecifier_CvQualifier cvq) = Just cvq; convert _ = Nothing
instance Convert TypeSpecifier (Maybe CvQualifier) where convert x = fst . (convert x :: Maybe (CvQualifier, White))
instance Convert DeclSpecifier (Maybe TypeSpecifier) where convert (DeclSpecifier_TypeSpecifier s) = Just s; convert _ = Nothing
instance Convert DeclSpecifier (Maybe StorageClassSpecifier) where convert (DeclSpecifier_StorageClassSpecifier (s, _)) = Just s; convert _ = Nothing
instance Convert DeclSpecifier (Maybe FunctionSpecifier) where convert (DeclSpecifier_FunctionSpecifier (s, _)) = Just s; convert _ = Nothing
instance Convert DeclSpecifier MakeSpecifier where convert = MakeSpecifier_DeclSpecifier
instance Convert DeclSpecifier (Maybe Sign) where convert x = convert x >>= (convert :: TypeSpecifier -> Maybe Sign)
instance Convert DeclSpecifier (Maybe LengthSpec) where convert x = convert x >>= (convert :: TypeSpecifier -> Maybe LengthSpec)
instance Convert DeclSpecifier (Maybe (CvQualifier, White)) where convert (DeclSpecifier_TypeSpecifier t) = convert t; convert _ = Nothing
instance Convert DeclSpecifier (Maybe CvQualifier) where convert x = fst . (convert x :: Maybe (CvQualifier, White))
instance Convert MakeSpecifier (Maybe (CvQualifier, White)) where convert (MakeSpecifier_DeclSpecifier t) = convert t; convert _ = Nothing

-- Declaration splitting

class SplitDecls a where split_decls :: a -> [a]

instance SplitDecls Declaration where
  split_decls (Declaration_BlockDeclaration bd) = map Declaration_BlockDeclaration $ split_decls bd
  split_decls d = [d]

instance SplitDecls BlockDeclaration where
  split_decls (BlockDeclaration_SimpleDeclaration sd) = map BlockDeclaration_SimpleDeclaration $ split_decls sd
  split_decls d = [d]

instance SplitDecls SimpleDeclaration where
  split_decls d@(SimpleDeclaration _ Nothing _) = [d]
  split_decls (SimpleDeclaration specs (Just (Commad x l)) w) =
    (\y -> SimpleDeclaration specs (Just (Commad y [])) w) . (x : snd . l)

instance SplitDecls Statement where
  split_decls (Statement_DeclarationStatement (DeclarationStatement d)) =
    Statement_DeclarationStatement . DeclarationStatement . split_decls d
  split_decls (Statement_CompoundStatement (CompoundStatement (Curlied x (Enclosed l) y))) =
    [Statement_CompoundStatement $ CompoundStatement $ Curlied x (Enclosed $ concatMap split_decls l) y]
  split_decls (Statement_SelectionStatement (IfStatement k c s Nothing)) =
    [Statement_SelectionStatement $ IfStatement k c (compound_split_decls s) Nothing] -- todo: do else part as well
    -- todo: do while and do-loops as well.
  split_decls s = [gmapT split_all_decls s]

instance SplitDecls MemberDeclaration where
  split_decls (MemberDeclaration specs (Commad d ds) s) =
    (\d' -> MemberDeclaration specs (Commad d' []) s) . (d : snd . ds)
  split_decls d = [gmapT split_all_decls d]

compound_split_decls :: Statement -> Statement
compound_split_decls s = case split_decls s of
  [x] -> x
  l -> Statement_CompoundStatement $ CompoundStatement $ Curlied (OpenCurly_, White "") (Enclosed l) (CloseCurly_, White "")

split_all_decls :: Data a => a -> a
split_all_decls = everywhere $ maybe id id $ Maybe.listToMaybe . Maybe.catMaybes $
  [ cast $ (concatMap split_decls :: [Declaration] -> [Declaration])
  , cast $ (concatMap split_decls :: [Statement] -> [Statement])
  , cast $ (concatMap (either (map Left . split_decls) ((:[]) . Right)) :: [Either MemberDeclaration MemberAccessSpecifier] -> [Either MemberDeclaration MemberAccessSpecifier])
  ]

-- Qualifier/specifier classification

is_primary_TypeSpecifier :: TypeSpecifier -> Bool
is_primary_TypeSpecifier (TypeSpecifier_CvQualifier _) = False
is_primary_TypeSpecifier _ = True

is_primary_DeclSpecifier :: DeclSpecifier -> Bool
is_primary_DeclSpecifier (DeclSpecifier_TypeSpecifier t) = is_primary_TypeSpecifier t
is_primary_DeclSpecifier _ = False

is_primary_MakeSpecifier :: MakeSpecifier -> Bool
is_primary_MakeSpecifier (MakeSpecifier_DeclSpecifier t) = is_primary_DeclSpecifier t
is_primary_MakeSpecifier _ = False

-- Natural applications

class Apply a b c | a b -> c where apply :: a -> b -> c
class MaybeApply a b where mapply :: (Functor m, Monad m) => a -> b -> m b

instance Apply a b b => Apply (Maybe a) b b where apply m x = maybe x (flip apply x) m
instance Apply a b b => Apply [a] b b where apply = flip $ foldl $ flip apply
instance Apply a b c => Apply a (Enclosed b) (Enclosed c) where apply x (Enclosed y) = Enclosed $ apply x y
instance MaybeApply a b => MaybeApply a (Enclosed b) where mapply x (Enclosed y) = Enclosed . mapply x y

-- Id application

instance Apply DeclaratorId PtrAbstractDeclarator PtrDeclarator where
  apply i (PtrAbstractDeclarator_NoptrAbstractDeclarator npad) = PtrDeclarator_NoptrDeclarator $ apply i npad
  apply i (PtrAbstractDeclarator o Nothing) = PtrDeclarator (with_trailing_white o) $ PtrDeclarator_NoptrDeclarator $ NoptrDeclarator_Id i
  apply i (PtrAbstractDeclarator o (Just pad)) = let pd = apply i pad in PtrDeclarator (case Cxx.Show.show_simple pd of
    (h:_) | not (isIdChar h) -> o; _ -> with_trailing_white o) pd

instance Apply DeclaratorId NoptrAbstractDeclarator NoptrDeclarator where
  apply i (NoptrAbstractDeclarator Nothing (Right s)) = NoptrDeclarator_Squared (NoptrDeclarator_Id i) s
  apply i (NoptrAbstractDeclarator (Just npad) (Right s)) = NoptrDeclarator_Squared (apply i npad) s
  apply i (NoptrAbstractDeclarator Nothing (Left params)) = NoptrDeclarator_WithParams (NoptrDeclarator_Id i) params
  apply i (NoptrAbstractDeclarator (Just npad) (Left params)) = NoptrDeclarator_WithParams (apply i npad) params
  apply i (NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w (Enclosed pad) w')) =
    NoptrDeclarator_Parenthesized $ Parenthesized w (Enclosed $ apply i pad) w'

-- TypeSpecifier application

-- Here and elsewhere, we always keep specifiers in the order they appeared in the source text as much as possible.

instance Apply TypeSpecifier (NElist TypeSpecifier) (NElist TypeSpecifier) where
  apply d (NElist x y) = NElist (with_trailing_white d) $ filter (compatible d) (x:y)

-- DeclSpecifier application

instance Apply DeclSpecifier [DeclSpecifier] [DeclSpecifier] where
  apply d l = with_trailing_white d : filter (compatible d) l

instance Apply DeclSpecifier (NElist DeclSpecifier) (NElist DeclSpecifier) where
  apply d (NElist x y) = NElist (with_trailing_white d) $ filter (compatible d) (x:y)

instance Apply [DeclSpecifier] (NElist DeclSpecifier) (NElist DeclSpecifier) where
  apply [] l = l
  apply l@(h:t) (NElist x y) = NElist h $ with_trailing_white t ++ filter (\s -> all (compatible s) l) (x:y)

instance MaybeApply DeclSpecifier (NElist TypeSpecifier) where
  mapply (DeclSpecifier_TypeSpecifier x) typespecs = return $ apply x typespecs
  mapply x _ = fail $ "Invalid decl-specifier for type-specifier-seq: " ++ Cxx.Show.show_simple x

instance MaybeApply [DeclSpecifier] (NElist TypeSpecifier) where
  mapply = flip $ foldM $ flip mapply

-- MakeSpecifier application

instance MaybeApply ([MakeSpecifier], Maybe PtrAbstractDeclarator) (NElist TypeSpecifier, Declarator) where
  mapply x (l, Declarator_PtrDeclarator d) = second Declarator_PtrDeclarator . mapply x (l, d)

instance Apply ([MakeSpecifier], Maybe PtrAbstractDeclarator) ([DeclSpecifier], Declarator) ([DeclSpecifier], Declarator) where
  apply x (y, Declarator_PtrDeclarator d) = second Declarator_PtrDeclarator $ apply x (y, d)

instance Apply ([MakeSpecifier], Maybe PtrAbstractDeclarator) (NElist DeclSpecifier, Declarator) (NElist DeclSpecifier, Declarator) where
  apply x (l, Declarator_PtrDeclarator d) = second Declarator_PtrDeclarator $ apply x (l, d)

instance (Apply [MakeSpecifier] (l DeclSpecifier) (l DeclSpecifier), Apply MakeSpecifier (l DeclSpecifier, PtrDeclarator) (l DeclSpecifier, PtrDeclarator)) => Apply ([MakeSpecifier], Maybe PtrAbstractDeclarator) (l DeclSpecifier, PtrDeclarator) (l DeclSpecifier, PtrDeclarator) where
  apply (l, Nothing) (l', x) =
    if any is_primary_MakeSpecifier l
      then (apply l l', PtrDeclarator_NoptrDeclarator $ NoptrDeclarator_Id $ convert x)
      else foldl (flip apply) (l', x) l
  apply (l, Just pad) (l', x) = (apply l l', apply (convert x :: DeclaratorId) pad)

instance MaybeApply ([MakeSpecifier], Maybe PtrAbstractDeclarator) (NElist TypeSpecifier, PtrDeclarator)  where
  mapply (l, Nothing) (l', x) =
    if any is_primary_MakeSpecifier l
      then flip (,) (PtrDeclarator_NoptrDeclarator $ NoptrDeclarator_Id $ convert x) . mapply l l'
      else foldM (flip mapply) (l', x) l
  mapply (l, Just pad) (l', x) = flip (,) (apply (convert x :: DeclaratorId) pad) . mapply l l'

instance MaybeApply [MakeSpecifier] (NElist TypeSpecifier) where
  mapply l l' = foldM (flip mapply) l' l

instance Apply MakeSpecifier ([DeclSpecifier], PtrDeclarator) ([DeclSpecifier], PtrDeclarator) where
  apply s (x, y) = maybe (apply s x, y) ((,) x) (mapply s y)

instance MaybeApply MakeSpecifier (NElist TypeSpecifier, PtrDeclarator) where
  mapply s (x, y) = maybe (flip (,) y . mapply s x) (return . (,) x) (mapply s y)

instance MaybeApply MakeSpecifier PtrDeclarator where
  mapply s (PtrDeclarator_NoptrDeclarator d) = PtrDeclarator_NoptrDeclarator . mapply s d
  mapply s (PtrDeclarator o d) = maybe (flip PtrDeclarator d . mapply s o) (return . PtrDeclarator o) (mapply s d)

instance MaybeApply MakeSpecifier PtrOperator where
  mapply s (PtrOperator_Ptr o cvs) = PtrOperator_Ptr o . mapply s cvs
  mapply s (PtrOperator_Nested x y z cvs) = PtrOperator_Nested x y z . mapply s cvs
  mapply _ (PtrOperator_Ref _) = fail "Cannot apply make-specifier to reference ptr-operator."

instance MaybeApply MakeSpecifier [(CvQualifier, White)] where
  mapply (MakeSpecifier_DeclSpecifier (DeclSpecifier_TypeSpecifier (TypeSpecifier_CvQualifier (cvq, _)))) =
    return . apply cvq
  mapply (NonCv cvq) = return . filter ((/= cvq) . fst)
  mapply _ = const $ fail "Cannot apply non-cv make-specifier to cv-qualifier-seq."

instance MaybeApply MakeSpecifier NoptrDeclarator where
  mapply _ (NoptrDeclarator_Id _) = fail "Cannot apply make-specifier to declarator-id."
  mapply s (NoptrDeclarator_Parenthesized (Parenthesized w (Enclosed d) w')) = do
    d' <- mapply s d
    return (NoptrDeclarator_Parenthesized (Parenthesized w (Enclosed d') w'))
  mapply s (NoptrDeclarator_Squared d ce) = do
    d' <- mapply s d
    return $ NoptrDeclarator_Squared d' ce
  mapply s (NoptrDeclarator_WithParams d p) =
    case mapply s d of
      Just d' -> return $ NoptrDeclarator_WithParams d' p
      Nothing -> NoptrDeclarator_WithParams d . mapply s p

instance MaybeApply MakeSpecifier ParametersAndQualifiers where
  mapply (MakeSpecifier_DeclSpecifier (DeclSpecifier_TypeSpecifier (TypeSpecifier_CvQualifier (cvq, _)))) (ParametersAndQualifiers c cvqs m e) =
    return $ ParametersAndQualifiers c (apply cvq cvqs) m e
  mapply (NonCv cvq) (ParametersAndQualifiers c cvqs m e) =
    return $ ParametersAndQualifiers c (filter ((/= cvq) . fst) cvqs) m e
  mapply _ _ = fail "Cannot apply non-cv make-specifier to parameters-and-qualifiers (yet)."

instance Apply MakeSpecifier (NElist DeclSpecifier, PtrDeclarator) (NElist DeclSpecifier, PtrDeclarator) where
  apply s (x, y) = maybe (apply s x, y) ((,) x) (mapply s y)

nonIntSpec :: (Eq s, Eq t, Convert t (Maybe s), Convert (BasicType, White) t) => s -> NElist t -> NElist t
nonIntSpec s l = case filter ((/= Just s) . convert) (unne l) of
    l'@(h:t) | (convert (Int', White "") `elem` l') || (convert (Double', White "") `elem` l') -> NElist h t
    l' -> NElist (convert (Int', White " ")) l'

instance MaybeApply MakeSpecifier (NElist TypeSpecifier) where
  mapply (MakeSpecifier_DeclSpecifier s) = mapply s
  mapply (NonStorageClassSpecifier _) = return
  mapply (NonFunctionSpecifier _) = return
  mapply (NonCv cvq) = return . filter_ne ((/= Just cvq) . convert)
  mapply (NonSign s) = return . nonIntSpec s
  mapply (NonLength s) = return . nonIntSpec s

instance Apply MakeSpecifier (NElist DeclSpecifier) (NElist DeclSpecifier) where
  apply (MakeSpecifier_DeclSpecifier s) = apply s
  apply (NonStorageClassSpecifier scs) = filter_ne $ (/= Just scs) . convert
  apply (NonFunctionSpecifier fs) = filter_ne $ (/= Just fs) . convert
  apply (NonCv cvq) = filter_ne $ (/= Just cvq) . convert
  apply (NonSign s) = nonIntSpec s
  apply (NonLength s) = nonIntSpec s

instance Apply MakeSpecifier [DeclSpecifier] [DeclSpecifier] where
  apply (MakeSpecifier_DeclSpecifier d) = apply d
  apply (NonStorageClassSpecifier scs) = filter $ (/= Just scs) . convert
  apply (NonFunctionSpecifier fs) = filter $ (/= Just fs) . convert
  apply (NonCv cvq) = filter $ (/= Just cvq) . convert
  apply (NonSign s) = maybe [] (unne . nonIntSpec s) . maybe_ne
  apply (NonLength s) = maybe [] (unne . nonIntSpec s) . maybe_ne

-- PtrOperator application

instance MaybeApply PtrOperator (Maybe AbstractDeclarator) where
  mapply o Nothing = return $ Just $ AbstractDeclarator_PtrAbstractDeclarator $ PtrAbstractDeclarator o Nothing
  mapply o (Just (AbstractDeclarator_PtrAbstractDeclarator pad)) =
    return $ Just $ AbstractDeclarator_PtrAbstractDeclarator $ apply o pad
  mapply _ (Just (AbstractDeclarator_Ellipsis _)) = fail "Cannot apply ptr-operator to ellipsis."

instance Apply PtrOperator PtrAbstractDeclarator PtrAbstractDeclarator where
  apply o (PtrAbstractDeclarator_NoptrAbstractDeclarator npad) =
    PtrAbstractDeclarator_NoptrAbstractDeclarator (apply o npad)
  apply o (PtrAbstractDeclarator o' Nothing) =
    PtrAbstractDeclarator o' $ Just $ PtrAbstractDeclarator o Nothing
  apply o (PtrAbstractDeclarator o' (Just pad)) = PtrAbstractDeclarator o' $ Just $ apply o pad

instance Apply PtrOperator NoptrAbstractDeclarator NoptrAbstractDeclarator where
  apply o (NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w pad w')) =
      NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w (apply o pad) w')
  apply o (NoptrAbstractDeclarator (Just npad) e) = NoptrAbstractDeclarator (Just $ apply o npad) e
  apply o (NoptrAbstractDeclarator Nothing e) =
    NoptrAbstractDeclarator (Just $ NoptrAbstractDeclarator_PtrAbstractDeclarator $ parenthesized (PtrAbstractDeclarator o Nothing)) e

instance Apply PtrOperator ([TypeSpecifier], Either TypeSpecifier PtrAbstractDeclarator)
    ([TypeSpecifier], PtrAbstractDeclarator) where
  apply o (specs, Left spec) = (specs ++ [spec], PtrAbstractDeclarator o Nothing)
  apply o (specs, Right ad) = (specs, apply o ad)

-- Declarator application

instance Apply (Maybe PtrAbstractDeclarator) ([TypeSpecifier], Either TypeSpecifier PtrAbstractDeclarator)
    ([TypeSpecifier], Either TypeSpecifier PtrAbstractDeclarator) where
  apply Nothing = id
  apply (Just ad) = second Right . apply ad

instance Apply PtrAbstractDeclarator ([TypeSpecifier], Either TypeSpecifier PtrAbstractDeclarator)
    ([TypeSpecifier], PtrAbstractDeclarator) where
  apply pad (specs, Left spec) = (specs ++ [spec], pad)
  apply pad (specs, Right pad') = (specs, apply pad pad')

instance Apply PtrAbstractDeclarator PtrAbstractDeclarator PtrAbstractDeclarator where
  apply pad (PtrAbstractDeclarator o Nothing) = PtrAbstractDeclarator o $ Just pad
  apply pad (PtrAbstractDeclarator o (Just pad')) = PtrAbstractDeclarator o $ Just $ apply pad pad'
  apply pad (PtrAbstractDeclarator_NoptrAbstractDeclarator npad') = PtrAbstractDeclarator_NoptrAbstractDeclarator (apply pad npad')

instance Apply PtrAbstractDeclarator NoptrAbstractDeclarator NoptrAbstractDeclarator where
  apply pad (NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w pad' w')) =
    NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w (apply pad pad') w')
  apply (PtrAbstractDeclarator_NoptrAbstractDeclarator npad) npad' = apply npad npad'
  apply pad (NoptrAbstractDeclarator Nothing e) = NoptrAbstractDeclarator (Just $ NoptrAbstractDeclarator_PtrAbstractDeclarator $ parenthesized pad) e
  apply pad (NoptrAbstractDeclarator (Just npad) e) = NoptrAbstractDeclarator (Just $ apply pad npad) e

instance Apply NoptrAbstractDeclarator (Maybe NoptrAbstractDeclarator) NoptrAbstractDeclarator where
  apply x = maybe x (apply x)

instance Apply NoptrAbstractDeclarator NoptrAbstractDeclarator NoptrAbstractDeclarator where
  apply npad (NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w pad w')) =
    NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w (apply (PtrAbstractDeclarator_NoptrAbstractDeclarator npad) pad) w')
  apply npad (NoptrAbstractDeclarator m e) = NoptrAbstractDeclarator (Just $ apply npad m) e

-- MakeDeclaration application

instance Apply MakeDeclaration ([DeclSpecifier], Declarator, Maybe PureSpecifier) ([DeclSpecifier], Declarator, Maybe PureSpecifier) where
  apply (MakeDeclaration specs m b) (specs', d, p) = (specs'', d', pure)
    where
      (specs'', d') = apply (specs, m) (specs', d)
      pure = if any (\ms -> case ms of NonFunctionSpecifier Virtual -> True; MakeSpecifier_DeclSpecifier (DeclSpecifier_StorageClassSpecifier (Static, _)) -> True; _ -> False) specs then Nothing else case b of Definitely -> Just $ PureSpecifier (IsOperator, White " ") (KwdZero, White " "); Indeterminate -> p; DefinitelyNot -> Nothing

-- cv-qualifier application

instance Apply CvQualifier [(CvQualifier, White)] [(CvQualifier, White)] where
  apply cvq l = if any ((== cvq) . fst) l then l else (cvq, White " ") : l

instance MaybeApply CvQualifier a => MaybeApply [CvQualifier] a where
  mapply l x = foldM (flip mapply) x l

instance MaybeApply CvQualifier PtrOperator where
  mapply cvq (PtrOperator_Nested mw n w cvq') = return $ PtrOperator_Nested mw n w $ apply cvq cvq'
  mapply cvq (PtrOperator_Ptr w cvq') = return $ PtrOperator_Ptr w $ apply cvq cvq'
  mapply _ (PtrOperator_Ref _) = fail "Cannot cv-qualify reference."

instance (Convert CvQualifier t, Compatible t t) => Apply CvQualifier [t] [t] where
  apply cvq l = let x = convert cvq in if any (not . compatible x) l then l else x : l

instance (Convert CvQualifier t, Compatible t t) => Apply CvQualifier (NElist t) (NElist t) where
  apply cvq l = let x = convert cvq in if any (not . compatible x) (unne l) then l else NElist x (unne l)
  -- todo: merge last two using ListLike

instance Apply CvQualifier x x => Apply CvQualifier (x, Maybe PtrAbstractDeclarator) (x, Maybe PtrAbstractDeclarator) where
  apply cvq (l, Just ad) | Just ad' <- mapply cvq ad = (l, Just ad')
  apply cvq (l, mad) = (apply cvq l, mad)

instance MaybeApply CvQualifier InitDeclarator where
  mapply cvq (InitDeclarator d mi) = flip InitDeclarator mi . mapply cvq d

instance MaybeApply CvQualifier Declarator where
  mapply cvq (Declarator_PtrDeclarator d) = Declarator_PtrDeclarator . mapply cvq d

instance MaybeApply CvQualifier PtrDeclarator where
  mapply cvq (PtrDeclarator_NoptrDeclarator d) = PtrDeclarator_NoptrDeclarator . mapply cvq d
  mapply cvq (PtrDeclarator o d) = case mapply cvq d of
    Just d' -> return $ PtrDeclarator o d'
    Nothing -> flip PtrDeclarator d . mapply cvq o

instance MaybeApply CvQualifier NoptrDeclarator where
  mapply cvq (NoptrDeclarator_WithParams d p) = return $ case mapply cvq d of
      Just d' -> NoptrDeclarator_WithParams d' p
      Nothing -> NoptrDeclarator_WithParams d $ apply cvq p
  mapply cvq (NoptrDeclarator_Parenthesized (Parenthesized w d w'))
    = NoptrDeclarator_Parenthesized . (\x -> Parenthesized w x w') . mapply cvq d
  mapply cvq (NoptrDeclarator_Squared d s) = flip NoptrDeclarator_Squared s . mapply cvq d
  mapply _ (NoptrDeclarator_Id _) = fail "Cannot cv-qualify declarator-id."

instance Apply CvQualifier ParametersAndQualifiers ParametersAndQualifiers where
  apply cvq (ParametersAndQualifiers d cvq' m e) = ParametersAndQualifiers d (apply cvq cvq') m e

instance Apply CvQualifier ([TypeSpecifier], Either TypeSpecifier PtrAbstractDeclarator)
    ([TypeSpecifier], Either TypeSpecifier PtrAbstractDeclarator) where
  apply cvq (l, Right ad)
    | Just ad' <- mapply cvq ad = (l, Right ad')
    | otherwise = (apply cvq l, Right ad)
  apply cvq (l, Left s) = let (NElist s' l') = apply cvq (NElist s l) in (l', Left s')

instance MaybeApply CvQualifier PtrAbstractDeclarator where
  mapply cvq (PtrAbstractDeclarator_NoptrAbstractDeclarator d) =
    PtrAbstractDeclarator_NoptrAbstractDeclarator . mapply cvq d
  mapply cvq (PtrAbstractDeclarator o Nothing) = flip PtrAbstractDeclarator Nothing . mapply cvq o
  mapply cvq (PtrAbstractDeclarator o (Just a)) = do
    case mapply cvq a of
      Just a' -> return $ PtrAbstractDeclarator o (Just a')
      Nothing -> flip PtrAbstractDeclarator (Just a) . mapply cvq o

instance MaybeApply CvQualifier NoptrAbstractDeclarator where
  mapply cvq (NoptrAbstractDeclarator (Just d) (Right t)) = flip NoptrAbstractDeclarator (Right t) . Just . mapply cvq d
  mapply _ (NoptrAbstractDeclarator Nothing (Right _)) = fail "Cannot cv-qualify leaf array noptr-abstract-declarator."
  mapply cvq (NoptrAbstractDeclarator m (Left p)) = return $ NoptrAbstractDeclarator m $ Left $ apply cvq p
  mapply cvq (NoptrAbstractDeclarator_PtrAbstractDeclarator (Parenthesized w d w')) =
    NoptrAbstractDeclarator_PtrAbstractDeclarator . (\x -> Parenthesized w x w') . mapply cvq d