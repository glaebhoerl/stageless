{-# LANGUAGE AllowAmbiguousTypes #-} -- for `idIsEven`

module IR (
    Type (..), ID (..), Name (..), Literal (..), Value (..), Expression (..), Statement (..), Block (..), Transfer (..), Target (..), paramTypes, returnToCaller, typeOf, translate,
    ValidationError (..), validate, eliminateTrivialBlocks
) where

import MyPrelude

import qualified Data.Map as Map

import qualified Pretty
import qualified AST  as AST
import qualified Name as AST
import qualified Type as AST


---------------------------------------------------------------------------------------------------- TYPE DEFINITIONS

data Type node where
    Int        :: Type Expression
    Bool       :: Type Expression
    Text       :: Type Expression
    Parameters :: ![Type Expression] -> Type Block

paramTypes :: Type Block -> [Type Expression]
paramTypes (Parameters types) = types

deriving instance Eq   (Type node)
deriving instance Show (Type node)

data ID node where
    LetID   :: !Int      -> ID Expression
    ASTName :: !AST.Name -> ID Expression
    BlockID :: !Int      -> ID Block
    Return  ::              ID Block

deriving instance Eq   (ID node)
deriving instance Ord  (ID node)
deriving instance Show (ID node)

data Name node = Name {
    ident       :: (ID   node), -- FIXME this needs to be lazy or we get a <<loop>>
    nameType    :: !(Type node),
    description :: !Text
} deriving (Generic, Show)

instance Eq (Name node) where
    (==) = (==) `on` ident

instance Ord (Name node) where
    compare = compare `on` ident

returnToCaller :: Name Block
returnToCaller = Name Return (Parameters [Int]) ""

data Literal
    = Number !Int64
    | String !Text
    deriving (Generic, Eq, Show)

data Value
    = Literal !Literal
    | Named   !(Name Expression)
    deriving (Generic, Eq, Show)

data Expression
    = Value          !Value
    | UnaryOperator  !UnaryOperator !Value
    | BinaryOperator !Value !BinaryOperator !Value
    | Ask            !Value
    deriving (Generic, Eq, Show)

data Statement
    = BlockDecl !(Name Block)      !Block
    | Let       !(Name Expression) !Expression
    | Assign    !(Name Expression) !Value
    | Say       !Value
    | Write     !Value
    deriving (Generic, Eq, Show)

data Block = Block {
    arguments :: ![Name Expression],
    body      :: ![Statement],
    transfer  :: !Transfer
} deriving (Generic, Eq, Show)

data Transfer
    = Jump   !Target
    | Branch !Value ![Target] -- targets are in "ascending order": false, then true
    deriving (Generic, Eq, Show)

data Target = Target {
    targetBlock :: !(Name Block),
    targetArgs  :: ![Value]
} deriving (Generic, Eq, Show)

class TypeOf a where
    typeOf :: a -> Type a

instance TypeOf Expression where
    typeOf = \case
        Value (Literal literal)  -> case literal of
            Number _             -> Int
            String _             -> Text
        Value (Named name)       -> nameType name
        UnaryOperator Not      _ -> Bool
        UnaryOperator Negate   _ -> Int
        BinaryOperator _ op    _ -> case op of
            ArithmeticOperator _ -> Int
            ComparisonOperator _ -> Bool
            LogicalOperator    _ -> Bool
        Ask                    _ -> Int

instance TypeOf Block where
    typeOf = Parameters . map nameType . arguments




---------------------------------------------------------------------------------------------------- TRANSLATION FRONTEND

class Monad m => TranslateM m where
    translateName       :: AST.TypedName       -> m (Name Expression)
    emitStatement       :: Statement           -> m ()
    emitLet             :: Maybe AST.TypedName -> Expression -> m (Name Expression)
    emitBlock           :: Text -> Type Block  -> m Transfer -> m (Name Block)
    emitTransfer        :: Transfer            -> m ()
    currentBlock        :: m (Name Block)
    currentArguments    :: m [Name Expression]
    currentContinuation :: Text -> Type Block -> m (Name Block) -- TODO add `Maybe AST.TypedName` or something

translateTemporary :: TranslateM m => AST.Expression AST.TypedName -> m Value
translateTemporary = translateExpression Nothing

translateBinding :: TranslateM m => AST.TypedName -> AST.Expression AST.TypedName -> m Value
translateBinding = translateExpression . Just

translateExpression :: TranslateM m => Maybe AST.TypedName -> AST.Expression AST.TypedName -> m Value
translateExpression providedName = let emitNamedLet = emitLet providedName in \case
    AST.Named name -> do
        translatedName <- translateName name
        return (Named translatedName)
    AST.NumberLiteral num -> do
        let value = Literal (Number (fromIntegral num))
        if isJust providedName
            then do
                name <- emitNamedLet (Value value)
                return (Named name)
            else do
                return value
    AST.TextLiteral text -> do -- TODO refactor
        let value = Literal (String text)
        if isJust providedName
            then do
                name <- emitNamedLet (Value value)
                return (Named name)
            else do
                return value
    AST.UnaryOperator op expr -> do
        value <- translateTemporary expr
        name  <- emitNamedLet (UnaryOperator op value)
        return (Named name)
    -- Logical operators are short-circuiting, so we can't just emit them as simple statements, except when the RHS is already a Value.
    AST.BinaryOperator expr1 (LogicalOperator op) expr2 | (expr2 `isn't` constructor @"NumberLiteral" && expr2 `isn't` constructor @"Named") -> do
        value1 <- translateTemporary expr1
        let opName = toLower (showText op)
        joinPoint <- currentContinuation ("join_" ++ opName) (Parameters [Bool]) -- TODO use the provided name for the arg!
        rhsBlock <- emitBlock opName (Parameters []) $ do
            value2 <- translateTemporary expr2
            return (Jump (Target joinPoint [value2]))
        let branches = case op of
                And -> [Target joinPoint [value1], Target rhsBlock  []]
                Or  -> [Target rhsBlock  [],       Target joinPoint [value1]]
        emitTransfer (Branch value1 branches)
        args <- currentArguments
        return (Named (assert (head args)))
    AST.BinaryOperator expr1 op expr2 -> do
        value1 <- translateTemporary expr1
        value2 <- translateTemporary expr2
        name   <- emitNamedLet (BinaryOperator value1 op value2)
        return (Named name)
    AST.Ask expr -> do
        value <- translateTemporary expr
        name  <- emitNamedLet (Ask value)
        return (Named name)

translateStatement :: TranslateM m => AST.Statement AST.TypedName -> m ()
translateStatement = \case
    AST.Binding _ name expr -> do
        _ <- translateBinding name expr
        return ()
    AST.Assign name expr -> do
        translatedName <- translateName name
        value <- translateTemporary expr
        emitStatement (Assign translatedName value)
    AST.IfThen expr block -> do
        value <- translateTemporary expr
        joinPoint <- currentContinuation "join_if" (Parameters [])
        thenBlock <- emitBlock "if" (Parameters []) $ do
            translateBlock block
            return (Jump (Target joinPoint []))
        emitTransfer (Branch value [Target joinPoint [], Target thenBlock []])
    AST.IfThenElse expr block1 block2 -> do
        value <- translateTemporary expr
        joinPoint <- currentContinuation "join_if_else" (Parameters [])
        thenBlock <- emitBlock "if" (Parameters []) $ do
            translateBlock block1
            return (Jump (Target joinPoint []))
        elseBlock <- emitBlock "else" (Parameters []) $ do
            translateBlock block2
            return (Jump (Target joinPoint []))
        emitTransfer (Branch value [Target elseBlock [], Target thenBlock []])
    AST.Forever block -> do
        foreverBlock <- emitBlock "forever" (Parameters []) $ do
            blockBody <- currentBlock
            translateBlock block
            return (Jump (Target blockBody []))
        emitTransfer (Jump (Target foreverBlock []))
    AST.While expr block -> do
        joinPoint <- currentContinuation "join_while" (Parameters [])
        whileBlock <- emitBlock "while" (Parameters []) $ do
            conditionTest <- currentBlock
            blockBody <- emitBlock "while_body" (Parameters []) $ do
                translateBlock block
                return (Jump (Target conditionTest []))
            value <- translateTemporary expr
            return (Branch value [Target joinPoint [], Target blockBody []])
        emitTransfer (Jump (Target whileBlock []))
    AST.Return maybeExpr -> do
        maybeValue <- mapM translateTemporary maybeExpr
        emitTransfer (Jump (Target returnToCaller [fromMaybe (Literal (Number 0)) maybeValue]))
    AST.Break -> do
        todo -- TODO
    AST.Say expr -> do
        value <- translateTemporary expr
        emitStatement (Say value)
    AST.Write expr -> do
        value <- translateTemporary expr
        emitStatement (Write value)

translateBlock :: TranslateM m => AST.Block AST.TypedName -> m ()
translateBlock (AST.Block statements) = mapM_ translateStatement statements




---------------------------------------------------------------------------------------------------- TRANSLATION BACKEND

translate :: AST.Block AST.TypedName -> Block
translate = evalTardis (backwardsState, forwardsState) . runTranslate . translateRootBlock
    where
        backwardsState = BackwardsState Nothing Nothing Nothing
        forwardsState  = ForwardsState  { lastID = 0, innermostBlock = BlockState (BlockID 0) "root" [] [] Nothing Nothing }
        translateRootBlock rootBlock = do
            (blockID, _, finishedBlock) <- liftM assert (backGetM (field @"thisBlock"))
            translateBlock rootBlock
            emitTransfer (Jump (Target returnToCaller [Literal (Number 0)]))
            --assertM (blockID == ID 0) -- this results in a <<loop>>
            return finishedBlock

newtype Translate a = Translate {
    runTranslate :: Tardis BackwardsState ForwardsState a
} deriving (Functor, Applicative, Monad, MonadFix, MonadState ForwardsState, MonadTardis BackwardsState ForwardsState)

data ForwardsState = ForwardsState {
    lastID         :: !Int,
    innermostBlock :: !BlockState
} deriving Generic

data BlockState = BlockState {
    blockID             :: !(ID Block),
    blockDescription    :: !Text,
    blockArguments      :: ![Name Expression],
    statements          :: ![Statement],
    emittedContinuation :: !(Maybe (Name Block)),
    enclosingBlock      :: !(Maybe BlockState)
} deriving Generic

data BackwardsState = BackwardsState {
    nextBlock              :: !(Maybe (ID Block, Text, Block)),
    thisBlock              :: !(Maybe (ID Block, Text, Block)),
    enclosingContinuations :: !(Maybe BackwardsState)
} deriving Generic

class NewID node where
    idIsEven :: Bool
    makeID :: Int -> ID node

instance NewID Expression where
    idIsEven = True
    makeID = LetID

instance NewID Block where
    idIsEven = False
    makeID = BlockID

newID :: forall node. NewID node => Translate (ID node)
newID = do
    -- NOTE incrementing first is significant, ID 0 is the root block!
    modifyM (field @"lastID") $ \lastID ->
        lastID + (if idIsEven @node == (lastID % 2 == 0) then 2 else 1)
    new <- getM (field @"lastID")
    return (makeID new)

newArgumentIDs :: Type Block -> Translate [Name Expression]
newArgumentIDs (Parameters argTypes) = do
    forM argTypes $ \argType -> do
        argID <- newID
        return (Name argID argType "")

pushBlock :: Text -> Type Block -> Translate ()
pushBlock description params = do
    blockID <- newID
    args    <- newArgumentIDs params
    modifyM         (field @"innermostBlock") (\previouslyInnermost -> BlockState blockID description args [] Nothing (Just previouslyInnermost))
    backModifyState (assert . enclosingContinuations)

popBlock :: Translate ()
popBlock = do
    modifyM         (field @"innermostBlock") (assert . enclosingBlock)
    backModifyState (\previousState -> BackwardsState Nothing Nothing (Just previousState))


instance TranslateM Translate where
    translateName :: AST.TypedName -> Translate (Name Expression)
    translateName (AST.NameWith name ty) = do
        return (Name (ASTName name) (translatedType ty) (AST.givenName name))
        where translatedType = \case
                AST.Bool -> Bool
                AST.Int  -> Int
                AST.Text -> Text

    emitStatement :: Statement -> Translate ()
    emitStatement statement = do
        modifyM (field @"innermostBlock" . field @"statements") (++ [statement])

    emitLet :: Maybe AST.TypedName -> Expression -> Translate (Name Expression)
    emitLet providedName expr = do
        name <- case providedName of
            Just astName -> do
                translatedName <- translateName astName
                assertM (nameType translatedName == typeOf expr)
                return translatedName
            Nothing -> do
                letID <- newID
                return (Name letID (typeOf expr) "")
        emitStatement (Let name expr)
        return name

    emitBlock :: Text -> Type Block -> Translate Transfer -> Translate (Name Block)
    emitBlock description argTypes translateBody = do
        pushBlock description argTypes
        blockName                <- currentBlock
        ~(blockID, _, finishedBlock) <- liftM assert (backGetM (field @"thisBlock")) -- FIXME need a lazy match here to avoid a <<loop>>
        transferAtEnd            <- translateBody
        --assertM (blockID == ident blockName) -- this results in a <<loop>>
        emitTransfer transferAtEnd
        popBlock
        emitStatement (BlockDecl blockName finishedBlock)
        return blockName

    emitTransfer :: Transfer -> Translate ()
    emitTransfer transfer = do
        BlockState { blockID, blockDescription, blockArguments, statements, emittedContinuation, enclosingBlock } <- getM (field @"innermostBlock")
        let (nextBlockParams, nextDescription) = case emittedContinuation of
                Just blockName -> (nameType blockName, description blockName)
                Nothing        -> (Parameters [],      "") -- TODO this means we're in dead code; should we do anything about it??
        nextBlockID   <- newID -- FIXME we should skip allocating a block if we're at the end of a parent block!
        nextBlockArgs <- newArgumentIDs nextBlockParams
        setM (field @"innermostBlock") (BlockState nextBlockID nextDescription nextBlockArgs [] Nothing enclosingBlock)
        backModifyState $ \BackwardsState { nextBlock = _, thisBlock = prevThisBlock, enclosingContinuations } ->
            BackwardsState { nextBlock = prevThisBlock, thisBlock = Just (blockID, blockDescription, Block blockArguments statements transfer), enclosingContinuations }

    currentBlock :: Translate (Name Block)
    currentBlock = do
        blockID     <- getM (field @"innermostBlock" . field @"blockID")
        description <- getM (field @"innermostBlock" . field @"blockDescription")
        arguments   <- currentArguments
        return (Name blockID (Parameters (map nameType arguments)) description)

    currentArguments :: Translate [Name Expression]
    currentArguments = do
        getM (field @"innermostBlock" . field @"blockArguments")

    currentContinuation :: Text -> Type Block -> Translate (Name Block)
    currentContinuation description params = do
        alreadyEmitted <- getM (field @"innermostBlock" . field @"emittedContinuation")
        case alreadyEmitted of
            Nothing -> do
                ~(nextBlockID, _, nextBlock) <- liftM assert (backGetM (field @"nextBlock")) -- FIXME need a lazy match here to avoid a <<loop>>
                let nextBlockName = Name nextBlockID params description
                emitStatement (BlockDecl nextBlockName nextBlock)
                setM (field @"innermostBlock" . field @"emittedContinuation") (Just nextBlockName)
                return nextBlockName
            Just nextBlockName -> do
                assertM (params == nameType nextBlockName)
                return nextBlockName

{- EXAMPLE INPUT
main1
if (foo) {
    body1
}
main2
if (foo2) {
    body2
}
main3
-}

{- EXAMPLE OUTPUT
block main() {
    main1
    block join1() {
        main2
        block join2() {
            main3
            return
        }
        block if2() {
            body2
            jump join2()
        }
        branch foo2 [if2, join2]
    }
    block if1() {
        body1
        jump join1()
    }
    branch foo [if1, join1]
}
-}




---------------------------------------------------------------------------------------------------- VALIDATION

data ValidationError where
    NotInScope     :: !(ID node)                         -> ValidationError
    Redefined      :: !(ID node)                         -> ValidationError
    Inconsistent   :: !(Name node) -> !(Name node)       -> ValidationError
    TypeMismatch   :: Show node => !(Type node) -> !node -> ValidationError -- Technically we don't need the `Show` here, but `deriving` doesn't know that.
    BadTargetCount :: ![Target]                          -> ValidationError
    BadArgsCount   :: !Target                            -> ValidationError

deriving instance Show ValidationError

data Scope = Scope {
    lets   :: !(Map (ID Expression) (Type Expression)),
    blocks :: !(Map (ID Block)      (Type Block)),
    parent :: !(Maybe Scope)
} deriving Generic

-- this is basically the use case for `dependent-map`, but this seems simpler for now
insertID :: ID node -> Type node -> Scope -> Scope
insertID ident nameType = case ident of
    Return    -> bug "Tried to insert the special builtin `return` block into the context!"
    BlockID _ -> modify (field @"blocks") (Map.insert ident nameType)
    LetID   _ -> modify (field @"lets")   (Map.insert ident nameType)
    ASTName _ -> modify (field @"lets")   (Map.insert ident nameType)

lookupID :: ID node -> Scope -> Maybe (Type node)
lookupID ident Scope { lets, blocks, parent } = case ident of
    Return    -> Just (nameType returnToCaller)
    BlockID _ -> orLookupInParent (Map.lookup ident blocks)
    LetID   _ -> orLookupInParent (Map.lookup ident lets)
    ASTName _ -> orLookupInParent (Map.lookup ident lets)
    where orLookupInParent = maybe (join (fmap (lookupID ident) parent)) Just

memberID :: ID node -> Scope -> Bool
memberID ident = isJust . lookupID ident

validate :: Block -> Either ValidationError ()
validate = runExcept . evalStateT (Scope Map.empty Map.empty Nothing) . checkBlock (Parameters []) where
    checkBlock expectedType block = do
        checkType expectedType block
        modifyState (\parent -> Scope Map.empty Map.empty (Just parent))
        mapM_ recordID       (arguments block)
        mapM_ checkStatement (body      block)
        checkTransfer        (transfer  block)
        modifyState (assert . parent)
    checkStatement = \case
        BlockDecl name block -> do
            recordID name -- block name is in scope for body
            checkBlock (nameType name) block
        Let name expr -> do
            checkExpression (nameType name) expr
            recordID name -- let name is not in scope for rhs
        Assign name value -> do
            checkID name
            checkValue (nameType name) value
        Say value -> do
            checkValue Text value
        Write value -> do
            checkValue Int value
    checkExpression expectedType expr = do
        checkType expectedType expr
        case expr of
            Value value -> do
                -- we already checked the type, we just want to check if it's in scope
                checkValue (typeOf expr) value
            UnaryOperator _ value -> do
                -- we abuse the fact that the unary ops have matching input and output types
                checkValue (typeOf expr) value
            BinaryOperator value1 op value2 -> do
                mapM_ (checkValue opInputType) [value1, value2] where
                    opInputType = case op of
                        ArithmeticOperator _ -> Int
                        ComparisonOperator _ -> Int
                        LogicalOperator    _ -> Bool
            Ask value -> do
                checkValue Text value
    checkValue expectedType value = do
        checkType expectedType (Value value)
        case value of
            Named   name -> checkID name
            Literal _    -> return ()
    checkTransfer = \case
        Jump target -> do
            checkTarget target
        Branch value targets -> do
            checkValue Bool value
            when (length targets != 2) $ do
                throwError (BadTargetCount targets)
            mapM_ checkTarget targets
    checkTarget target@Target { targetBlock, targetArgs } = do
        checkID targetBlock
        let expectedTypes = paramTypes (nameType targetBlock)
        when (length expectedTypes != length targetArgs) $ do
            throwError (BadArgsCount target)
        zipWithM_ checkValue expectedTypes targetArgs
    checkType expectedType node = do
        when (typeOf node != expectedType) $ do
            throwError (TypeMismatch expectedType node)
    recordID Name { ident, nameType } = do
        doModifyState $ \scope -> do
            when (memberID ident scope) $ do -- FIXME this should be a shallow check?
                throwError (Redefined ident)
            return (insertID ident nameType scope)
    checkID Name { ident, nameType, description } = do
        inContext <- liftM (lookupID ident) getState
        case inContext of
            Nothing -> do
                throwError (NotInScope ident)
            Just recordedType -> do
                when (nameType != recordedType) $ do
                    throwError (Inconsistent (Name ident nameType description) (Name ident recordedType ""))




---------------------------------------------------------------------------------------------------- TRANSFORMS

eliminateTrivialBlocks :: Block -> Block
eliminateTrivialBlocks = evalState Map.empty . visitBlock where
    visitBlock Block { arguments, body, transfer } = do
        newBody     <- liftM catMaybes (mapM visitStatement body)
        newTransfer <- visitTransfer transfer
        return (Block arguments newBody newTransfer)
    visitStatement = \case
        BlockDecl name (Block [] [] (Jump target)) | targetBlock target != name -> do
            modifyState (Map.insert name target)
            return Nothing
        BlockDecl name nonTrivialBlock -> do
            newBlock <- visitBlock nonTrivialBlock
            return (Just (BlockDecl name newBlock))
        otherStatement -> do
            return (Just otherStatement)
    visitTransfer = \case
        Jump target -> do
            newTarget <- getAdjustedTarget target
            return (Jump newTarget)
        Branch value targets -> do
            newTargets <- mapM getAdjustedTarget targets
            return (Branch value newTargets)
    getAdjustedTarget oldTarget = do
        maybeNewTarget <- liftM (Map.lookup (targetBlock oldTarget)) getState
        case maybeNewTarget of
            Nothing -> do
                return oldTarget
            Just adjustedTarget -> do
                assertM (targetArgs oldTarget == []) -- if the block we're eliminating had arguments, it's not trivial!
                getAdjustedTarget adjustedTarget -- check if this block was _also_ trivial




---------------------------------------------------------------------------------------------------- PRETTY PRINTING

instance Pretty.DefaultStyle (Type Expression) where
    applyStyle base = const base

data IdentName
    = LetName    !(Name Expression)
    | BlockName  !(Name Block)
    | TypeName   !(Type Expression)
    | GlobalName !Text
    deriving (Generic, Eq, Show)

instance Pretty.DefaultStyle IdentName where
    applyStyle base = \case
        LetName    _ -> base { Pretty.color = Just Pretty.Magenta }
        BlockName  _ -> base { Pretty.color = Just Pretty.Green   }
        TypeName   _ -> base { Pretty.color = Just Pretty.Cyan    }
        GlobalName _ -> base { Pretty.color = Just Pretty.Yellow  }

instance Pretty.Render Block where
    type InfoFor Block = Pretty.Info (Type Expression) IdentName
    render rootBlock = renderBody (body rootBlock) (transfer rootBlock) where
        note         = Pretty.annotate
        keyword      = note Pretty.Keyword
        operator     = note Pretty.UserOperator
        colon        = note Pretty.Colon ":"
        defineEquals = note Pretty.DefineEquals "="
        assignEquals = note Pretty.AssignEquals "="
        string       = note (Pretty.Literal' Text) . Pretty.dquotes . Pretty.pretty
        number       = note (Pretty.Literal' Int) . Pretty.pretty
        builtin      = renderName . Pretty.IdentInfo False . GlobalName
        type'        = renderName . Pretty.IdentInfo False . TypeName
        blockID def  = renderName . Pretty.IdentInfo def   . BlockName
        letID   def  = renderName . Pretty.IdentInfo def   . LetName
        braces  doc  = note Pretty.Brace "{" ++ doc ++ note Pretty.Brace "}"
        parens  doc  = note Pretty.Paren "(" ++ doc ++ note Pretty.Paren ")"

        renderBody statements transfer = mconcat (map (Pretty.hardline ++) (map renderStatement statements ++ [renderTransfer transfer]))

        renderStatement = \case
            BlockDecl name block -> keyword "block"  ++ " " ++ blockID True name ++ argumentList (arguments block) ++ " " ++ braces (Pretty.nest 4 (renderBody (body block) (transfer block)) ++ Pretty.hardline)
            Let       name expr  -> keyword "let"    ++ " " ++ typedName name ++ " " ++ defineEquals ++ " " ++ renderExpr expr
            Assign    name value -> letID False name ++ " " ++ assignEquals ++ " " ++ renderValue value
            Say       value      -> builtin "say"    ++ parens (renderValue value)
            Write     value      -> builtin "write"  ++ parens (renderValue value)

        renderTransfer = \case
            Jump         target  -> keyword "jump"   ++ " " ++ renderTarget target
            Branch value targets -> keyword "branch" ++ " " ++ renderValue value ++ " " ++ Pretty.hsep (map renderTarget targets)

        renderTarget target = blockID False (targetBlock target) ++ parens (Pretty.hsep (Pretty.punctuate "," (map renderValue (targetArgs target))))

        renderExpr = \case
            Value          value            -> renderValue value
            UnaryOperator  op value         -> unaryOperator op ++ renderValue value
            BinaryOperator value1 op value2 -> renderValue value1 ++ " " ++ binaryOperator op ++ " " ++ renderValue value2
            Ask            value            -> builtin "ask" ++ parens (renderValue value)

        renderValue = \case
            Named   name    -> letID False name
            Literal literal -> renderLiteral literal

        renderLiteral = \case
            Number  num  -> number num
            String  text -> string text

        renderName :: (Pretty.IdentInfo IdentName) -> Doc (Pretty.InfoFor Block)
        renderName info = note (Pretty.Sigil info) sigil ++ note (Pretty.Identifier info) name where
            (sigil, name) = case Pretty.identName info of
                LetName    n -> ("$", renderIdent (ident n))
                BlockName  n -> ("%", renderIdent (ident n) ++ (if description n == "" then "" else "_" ++ Pretty.pretty (description n)))
                TypeName   t -> ("",  Pretty.pretty (show t))
                GlobalName n -> ("",  Pretty.pretty n)

        renderIdent :: ID node -> Doc (Pretty.InfoFor Block)
        renderIdent = \case
            ASTName n -> Pretty.pretty (AST.givenName n)
            LetID   i -> Pretty.pretty i
            BlockID i -> Pretty.pretty i
            Return    -> keyword "return" -- FIXME this gets tagged as both a Keyword and an Identifier, but it seems to work out OK

        argumentList args = parens (Pretty.hsep (Pretty.punctuate "," (map typedName args)))

        typedName name = letID True name ++ colon ++ " " ++ type' (nameType name)

        -- FIXME: Deduplicate these with `module Token` maybe?? Put them in MyPrelude?
        unaryOperator  = operator . \case
            Not                   -> "!"
            Negate                -> "-"
        binaryOperator = operator . \case
            ArithmeticOperator op -> case op of
                Add               -> "+"
                Sub               -> "-"
                Mul               -> "*"
                Div               -> "/"
                Mod               -> "%"
            ComparisonOperator op -> case op of
                Equal             -> "=="
                NotEqual          -> "!="
                Less              -> "<"
                LessEqual         -> "<="
                Greater           -> ">"
                GreaterEqual      -> ">="
            LogicalOperator    op -> case op of
                And               -> "&&"
                Or                -> "||"

instance Pretty.Output Block